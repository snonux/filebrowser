package users

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/rules"
)

// ErrForbiddenPatch indicates an update the acting user may not perform.
var ErrForbiddenPatch = errors.New("forbidden user update")

// Patch explicitly lists writable user fields. Nil means the field is absent.
type Patch struct {
	Username              *string        `json:"username"`
	Password              *string        `json:"password"`
	Scope                 *string        `json:"scope"`
	Locale                *string        `json:"locale"`
	LockPassword          *bool          `json:"lockPassword"`
	ViewMode              *ViewMode      `json:"viewMode"`
	SingleClick           *bool          `json:"singleClick"`
	RedirectAfterCopyMove *bool          `json:"redirectAfterCopyMove"`
	Perm                  *Permissions   `json:"perm"`
	Commands              *[]string      `json:"commands"`
	Sorting               *files.Sorting `json:"sorting"`
	Rules                 *[]rules.Rule  `json:"rules"`
	HideDotfiles          *bool          `json:"hideDotfiles"`
	DateFormat            *bool          `json:"dateFormat"`
	AceEditorTheme        *string        `json:"aceEditorTheme"`
}

// PatchPolicy supplies the actor and password requirements for an HTTP update.
type PatchPolicy struct {
	Actor                  *User
	RequireCurrentPassword bool
	CurrentPassword        string
	MinimumPasswordLength  uint
}

// DecodePatch decodes the existing data/which wire format without reflection.
// An empty selection or "all" selects only fields actually present in data.
func DecodePatch(data json.RawMessage, which []string) (uint, Patch, bool, error) {
	var values map[string]json.RawMessage
	if err := json.Unmarshal(data, &values); err != nil {
		return 0, Patch{}, false, err
	}
	if values == nil {
		return 0, Patch{}, false, fberrors.ErrEmptyRequest
	}
	var id uint
	normalized := make(map[string]json.RawMessage, len(values))
	for name, value := range values {
		if strings.EqualFold(name, "id") {
			if err := json.Unmarshal(value, &id); err != nil {
				return 0, Patch{}, false, err
			}
			continue
		}
		canonical, err := patchField(name)
		if err != nil {
			return 0, Patch{}, false, err
		}
		if _, exists := normalized[canonical]; exists {
			return 0, Patch{}, false, fmt.Errorf("duplicate field: %s", name)
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			// Preserve the legacy representation of empty command/rule lists.
			if canonical != "Commands" && canonical != "Rules" {
				return 0, Patch{}, false, fmt.Errorf("null field: %s", name)
			}
			value = json.RawMessage("[]")
		}
		normalized[canonical] = value
	}
	full := len(which) == 0 || (len(which) == 1 && strings.EqualFold(which[0], "all"))
	if !full {
		selected := make(map[string]json.RawMessage, len(which))
		for _, name := range which {
			canonical, err := patchField(name)
			if err != nil {
				return 0, Patch{}, false, err
			}
			value, exists := normalized[canonical]
			if !exists {
				return 0, Patch{}, false, fmt.Errorf("missing field: %s", name)
			}
			selected[canonical] = value
		}
		normalized = selected
	}
	encoded, err := json.Marshal(normalized)
	if err != nil {
		return 0, Patch{}, false, err
	}
	var patch Patch
	err = json.Unmarshal(encoded, &patch)
	return id, patch, full, err
}

// PatchFromUser adapts the legacy CLI/storage update API to explicit fields.
func PatchFromUser(user *User, fields ...string) (Patch, error) {
	if user == nil {
		return Patch{}, fberrors.ErrInvalidDataType
	}
	var patch Patch
	if len(fields) == 0 {
		patch.Username = &user.Username
		patch.Password = &user.Password
		patch.Scope = &user.Scope
		patch.Locale = &user.Locale
		patch.LockPassword = &user.LockPassword
		patch.ViewMode = &user.ViewMode
		patch.SingleClick = &user.SingleClick
		patch.RedirectAfterCopyMove = &user.RedirectAfterCopyMove
		patch.Perm = &user.Perm
		patch.Commands = &user.Commands
		patch.Sorting = &user.Sorting
		patch.Rules = &user.Rules
		patch.HideDotfiles = &user.HideDotfiles
		patch.DateFormat = &user.DateFormat
		patch.AceEditorTheme = &user.AceEditorTheme
		return patch, nil
	}
	for _, field := range fields {
		canonical, err := patchField(field)
		if err != nil {
			return Patch{}, err
		}
		switch canonical {
		case "Username":
			patch.Username = &user.Username
		case "Password":
			patch.Password = &user.Password
		case "Scope":
			patch.Scope = &user.Scope
		case "Locale":
			patch.Locale = &user.Locale
		case "LockPassword":
			patch.LockPassword = &user.LockPassword
		case "ViewMode":
			patch.ViewMode = &user.ViewMode
		case "SingleClick":
			patch.SingleClick = &user.SingleClick
		case "RedirectAfterCopyMove":
			patch.RedirectAfterCopyMove = &user.RedirectAfterCopyMove
		case "Perm":
			patch.Perm = &user.Perm
		case "Commands":
			patch.Commands = &user.Commands
		case "Sorting":
			patch.Sorting = &user.Sorting
		case "Rules":
			patch.Rules = &user.Rules
		case "HideDotfiles":
			patch.HideDotfiles = &user.HideDotfiles
		case "DateFormat":
			patch.DateFormat = &user.DateFormat
		case "AceEditorTheme":
			patch.AceEditorTheme = &user.AceEditorTheme
		}
	}
	return patch, nil
}

// Fields returns canonical names of the explicitly selected fields.
func (p Patch) Fields() []string {
	var fields []string
	if p.Username != nil {
		fields = append(fields, "Username")
	}
	if p.Password != nil {
		fields = append(fields, "Password")
	}
	if p.Scope != nil {
		fields = append(fields, "Scope")
	}
	if p.Locale != nil {
		fields = append(fields, "Locale")
	}
	if p.LockPassword != nil {
		fields = append(fields, "LockPassword")
	}
	if p.ViewMode != nil {
		fields = append(fields, "ViewMode")
	}
	if p.SingleClick != nil {
		fields = append(fields, "SingleClick")
	}
	if p.RedirectAfterCopyMove != nil {
		fields = append(fields, "RedirectAfterCopyMove")
	}
	if p.Perm != nil {
		fields = append(fields, "Perm")
	}
	if p.Commands != nil {
		fields = append(fields, "Commands")
	}
	if p.Sorting != nil {
		fields = append(fields, "Sorting")
	}
	if p.Rules != nil {
		fields = append(fields, "Rules")
	}
	if p.HideDotfiles != nil {
		fields = append(fields, "HideDotfiles")
	}
	if p.DateFormat != nil {
		fields = append(fields, "DateFormat")
	}
	if p.AceEditorTheme != nil {
		fields = append(fields, "AceEditorTheme")
	}
	return fields
}

// Merge applies selected fields to a copy, preserving every absent field.
func (p Patch) Merge(user User) User {
	if p.Username != nil {
		user.Username = *p.Username
	}
	if p.Password != nil {
		user.Password = *p.Password
	}
	if p.Scope != nil {
		user.Scope = *p.Scope
	}
	if p.Locale != nil {
		user.Locale = *p.Locale
	}
	if p.LockPassword != nil {
		user.LockPassword = *p.LockPassword
	}
	if p.ViewMode != nil {
		user.ViewMode = *p.ViewMode
	}
	if p.SingleClick != nil {
		user.SingleClick = *p.SingleClick
	}
	if p.RedirectAfterCopyMove != nil {
		user.RedirectAfterCopyMove = *p.RedirectAfterCopyMove
	}
	if p.Perm != nil {
		user.Perm = *p.Perm
	}
	if p.Commands != nil {
		user.Commands = *p.Commands
	}
	if p.Sorting != nil {
		user.Sorting = *p.Sorting
	}
	if p.Rules != nil {
		user.Rules = *p.Rules
	}
	if p.HideDotfiles != nil {
		user.HideDotfiles = *p.HideDotfiles
	}
	if p.DateFormat != nil {
		user.DateFormat = *p.DateFormat
	}
	if p.AceEditorTheme != nil {
		user.AceEditorTheme = *p.AceEditorTheme
	}
	return user
}

// Prepare authorizes and validates the complete update before persistence.
// Full updates with an empty password retain the stored password.
func (p Patch) Prepare(current User, full bool, policy PatchPolicy) (User, Patch, error) {
	if policy.Actor == nil {
		return User{}, Patch{}, ErrForbiddenPatch
	}
	if !policy.Actor.Perm.Admin {
		if full || policy.Actor.ID != current.ID {
			return User{}, Patch{}, ErrForbiddenPatch
		}
		for _, field := range p.Fields() {
			switch field {
			case "Locale", "ViewMode", "SingleClick", "RedirectAfterCopyMove", "Sorting", "HideDotfiles", "DateFormat", "AceEditorTheme":
			case "Password":
				if current.LockPassword {
					return User{}, Patch{}, ErrForbiddenPatch
				}
			default:
				return User{}, Patch{}, ErrForbiddenPatch
			}
		}
	}
	sensitive := full || p.Username != nil || p.Password != nil || p.Scope != nil || p.LockPassword != nil || p.Commands != nil || p.Perm != nil
	if sensitive && policy.RequireCurrentPassword && !CheckPwd(policy.CurrentPassword, policy.Actor.Password) {
		return User{}, Patch{}, fberrors.ErrCurrentPasswordIncorrect
	}
	if p.Password != nil {
		if full && *p.Password == "" {
			p.Password = nil
		} else {
			if *p.Password == "" {
				return User{}, Patch{}, fberrors.ErrEmptyPassword
			}
			hash, err := ValidateAndHashPwd(*p.Password, policy.MinimumPasswordLength)
			if err != nil {
				return User{}, Patch{}, err
			}
			p.Password = &hash
		}
	}
	merged := p.Merge(current)
	if merged.Perm.Share && !merged.Perm.Download {
		return User{}, Patch{}, fberrors.ErrShareRequiresDownload
	}
	if err := merged.Clean("", false, p.Fields()...); err != nil {
		return User{}, Patch{}, err
	}
	return merged, p, nil
}

func patchField(name string) (string, error) {
	switch strings.ToLower(name) {
	case "username":
		return "Username", nil
	case "password":
		return "Password", nil
	case "scope":
		return "Scope", nil
	case "locale":
		return "Locale", nil
	case "lockpassword":
		return "LockPassword", nil
	case "viewmode":
		return "ViewMode", nil
	case "singleclick":
		return "SingleClick", nil
	case "redirectaftercopymove":
		return "RedirectAfterCopyMove", nil
	case "perm":
		return "Perm", nil
	case "commands":
		return "Commands", nil
	case "sorting":
		return "Sorting", nil
	case "rules":
		return "Rules", nil
	case "hidedotfiles":
		return "HideDotfiles", nil
	case "dateformat":
		return "DateFormat", nil
	case "aceeditortheme":
		return "AceEditorTheme", nil
	default:
		return "", fmt.Errorf("invalid user field: %s", name)
	}
}
