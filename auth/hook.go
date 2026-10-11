package auth

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"strings"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

// MethodHookAuth is used to identify hook auth.
const MethodHookAuth settings.AuthMethod = "hook"

type hookCred struct {
	Password string `json:"password"`
	Username string `json:"username"`
}

// HookAuth is a hook implementation of an Auther.
type HookAuth struct {
	Users    users.Store        `json:"-"`
	Settings *settings.Settings `json:"-"`
	Server   *settings.Server   `json:"-"`
	Cred     hookCred           `json:"-"`
	Fields   hookFields         `json:"-"`
	Command  string             `json:"command"`
}

// Auth authenticates the user via a json in content body.
func (a *HookAuth) Auth(r *http.Request, usr users.Store, stg *settings.Settings, srv *settings.Server) (*users.User, error) {
	var cred hookCred

	if r.Body == nil {
		return nil, os.ErrPermission
	}

	err := json.NewDecoder(r.Body).Decode(&cred)
	if err != nil {
		return nil, os.ErrPermission
	}

	a.Users = usr
	a.Settings = stg
	a.Server = srv
	a.Cred = cred

	action, err := a.RunCommand()
	if err != nil {
		return nil, err
	}

	switch action {
	case "auth":
		u, err := a.SaveUser()
		if err != nil {
			return nil, err
		}
		return u, nil
	case "block":
		return nil, os.ErrPermission
	case "pass":
		u, err := a.Users.Get(a.Server.Root, a.Server.FollowExternalSymlinks, a.Cred.Username)
		if err != nil || !users.CheckPwd(a.Cred.Password, u.Password) {
			return nil, os.ErrPermission
		}
		return u, nil
	default:
		return nil, fmt.Errorf("invalid hook action: %s", action)
	}
}

// LoginPage tells that hook auth requires a login page.
func (a *HookAuth) LoginPage() bool {
	return true
}

// RunCommand starts the hook command and returns the action
func (a *HookAuth) RunCommand() (string, error) {
	command := strings.Split(a.Command, " ")

	cmd := exec.Command(command[0], command[1:]...)
	cmd.Env = append(os.Environ(), fmt.Sprintf("USERNAME=%s", a.Cred.Username))
	cmd.Env = append(cmd.Env, fmt.Sprintf("PASSWORD=%s", a.Cred.Password))
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}

	a.GetValues(string(out))

	return a.Fields.Values["hook.action"], nil
}

// GetValues creates a map with values from the key-value format string
func (a *HookAuth) GetValues(s string) {
	m := map[string]string{}

	// make line breaks consistent on Windows platform
	s = strings.ReplaceAll(s, "\r\n", "\n")

	// iterate input lines
	for val := range strings.Lines(s) {
		v := strings.SplitN(val, "=", 2)

		// skips non key and value format
		if len(v) != 2 {
			continue
		}

		fieldKey := strings.TrimSpace(v[0])
		fieldValue := strings.TrimSpace(v[1])

		if a.Fields.IsValid(fieldKey) {
			m[fieldKey] = fieldValue
		}
	}

	a.Fields.Values = m
}

// SaveUser updates the existing user or creates a new one when not found
func (a *HookAuth) SaveUser() (*users.User, error) {
	u, err := a.Users.Get(a.Server.Root, a.Server.FollowExternalSymlinks, a.Cred.Username)
	if err != nil && !errors.Is(err, fberrors.ErrNotExist) {
		return nil, err
	}

	if u == nil {
		d, err := a.Settings.NewUser(a.Cred.Username, a.Cred.Password, settings.ProvisionHook)
		if err != nil {
			return nil, err
		}
		u = a.GetUser(d)
		_, explicitScope := a.Fields.Values["user.scope"]
		if err := a.Settings.ProvisionUser(a.Users, u, a.Server.Root, settings.ProvisionHook, explicitScope); err != nil {
			return nil, err
		}
		log.Printf("user: %s, home dir: [%s].", u.Username, u.Scope)
	} else if p := !users.CheckPwd(a.Cred.Password, u.Password); len(a.Fields.Values) > 1 || p {
		u = a.GetUser(u)

		// update the password when it doesn't match the current
		if p {
			pass, err := users.ValidateAndHashPwd(a.Cred.Password, a.Settings.MinimumPasswordLength)
			if err != nil {
				return nil, err
			}
			u.Password = pass
		}

		// update user with provided fields
		err := a.Users.Update(u)
		if err != nil {
			return nil, err
		}
	}

	return u, nil
}

// GetUser returns a User filled with hook values or provided defaults
func (a *HookAuth) GetUser(d *users.User) *users.User {
	// adds all permissions when user is admin
	isAdmin := a.Fields.GetBoolean("user.perm.admin", d.Perm.Admin)
	perms := users.Permissions{
		Admin:    isAdmin,
		Execute:  isAdmin || a.Fields.GetBoolean("user.perm.execute", d.Perm.Execute),
		Create:   isAdmin || a.Fields.GetBoolean("user.perm.create", d.Perm.Create),
		Rename:   isAdmin || a.Fields.GetBoolean("user.perm.rename", d.Perm.Rename),
		Modify:   isAdmin || a.Fields.GetBoolean("user.perm.modify", d.Perm.Modify),
		Delete:   isAdmin || a.Fields.GetBoolean("user.perm.delete", d.Perm.Delete),
		Share:    isAdmin || a.Fields.GetBoolean("user.perm.share", d.Perm.Share),
		Download: isAdmin || a.Fields.GetBoolean("user.perm.download", d.Perm.Download),
	}
	// Preserve fields the hook does not support when updating an account.
	user := *d
	user.Scope = a.Fields.GetString("user.scope", d.Scope)
	if user.Scope != d.Scope {
		user.Fs = nil
	}
	user.Locale = a.Fields.GetString("user.locale", d.Locale)
	user.ViewMode = users.ViewMode(a.Fields.GetString("user.viewMode", string(d.ViewMode)))
	user.SingleClick = a.Fields.GetBoolean("user.singleClick", d.SingleClick)
	user.RedirectAfterCopyMove = a.Fields.GetBoolean("user.redirectAfterCopyMove", d.RedirectAfterCopyMove)
	user.Sorting = files.Sorting{
		Asc: a.Fields.GetBoolean("user.sorting.asc", d.Sorting.Asc),
		By:  a.Fields.GetString("user.sorting.by", d.Sorting.By),
	}
	user.Commands = a.Fields.GetArray("user.commands", d.Commands)
	user.DateFormat = a.Fields.GetBoolean("user.dateFormat", d.DateFormat)
	user.HideDotfiles = a.Fields.GetBoolean("user.hideDotfiles", d.HideDotfiles)
	user.Perm = perms
	user.LockPassword = true

	return &user
}

// hookFields is used to access fields from the hook
type hookFields struct {
	Values map[string]string
}

// validHookFields contains names of the fields that can be used
var validHookFields = []string{
	"hook.action",
	"user.scope",
	"user.locale",
	"user.viewMode",
	"user.singleClick",
	"user.redirectAfterCopyMove",
	"user.sorting.by",
	"user.sorting.asc",
	"user.commands",
	"user.hideDotfiles",
	"user.perm.admin",
	"user.perm.execute",
	"user.perm.create",
	"user.perm.rename",
	"user.perm.modify",
	"user.perm.delete",
	"user.perm.share",
	"user.perm.download",
}

// IsValid checks if the provided field is on the valid fields list
func (hf *hookFields) IsValid(field string) bool {
	return slices.Contains(validHookFields, field)
}

// GetString returns the string value or provided default
func (hf *hookFields) GetString(k, dv string) string {
	val, ok := hf.Values[k]
	if ok {
		return val
	}
	return dv
}

// GetBoolean returns the bool value or provided default
func (hf *hookFields) GetBoolean(k string, dv bool) bool {
	val, ok := hf.Values[k]
	if ok {
		return val == "true"
	}
	return dv
}

// GetArray returns the array value or provided default
func (hf *hookFields) GetArray(k string, dv []string) []string {
	val, ok := hf.Values[k]
	if ok && strings.TrimSpace(val) != "" {
		return strings.Split(val, " ")
	}
	return dv
}
