package users

import (
	"path/filepath"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/rules"
	"github.com/spf13/afero"
)

// ViewMode describes a view mode.
type ViewMode string

const (
	ListViewMode   ViewMode = "list"
	MosaicViewMode ViewMode = "mosaic"
)

// User describes a user.
type User struct {
	ID                    uint          `storm:"id,increment" json:"id"`
	Username              string        `storm:"unique" json:"username"`
	Password              string        `json:"password"`
	Scope                 string        `json:"scope"`
	Locale                string        `json:"locale"`
	LockPassword          bool          `json:"lockPassword"`
	ViewMode              ViewMode      `json:"viewMode"`
	SingleClick           bool          `json:"singleClick"`
	RedirectAfterCopyMove bool          `json:"redirectAfterCopyMove"`
	Perm                  Permissions   `json:"perm"`
	Commands              []string      `json:"commands"`
	Sorting               files.Sorting `json:"sorting"`
	Fs                    afero.Fs      `json:"-" yaml:"-"`
	Rules                 []rules.Rule  `json:"rules"`
	HideDotfiles          bool          `json:"hideDotfiles"`
	DateFormat            bool          `json:"dateFormat"`
	AceEditorTheme        string        `json:"aceEditorTheme"`
}

// GetRules implements rules.Provider.
func (u *User) GetRules() []rules.Rule {
	return u.Rules
}

var checkableFields = []string{
	"Username",
	"Password",
	"Scope",
	"ViewMode",
	"Commands",
	"Sorting",
	"Rules",
}

// Clean validates a user and initializes its filesystem when absent.
//
// Deprecated: use Validate for persisted data and BindFilesystem explicitly
// when preparing a user to serve files.
func (u *User) Clean(baseScope string, followExternalSymlinks bool, fields ...string) error {
	if err := u.Validate(fields...); err != nil {
		return err
	}
	if u.Fs == nil {
		u.BindFilesystem(afero.NewOsFs(), baseScope, followExternalSymlinks)
	}
	return nil
}

// BindFilesystem replaces the runtime filesystem using the supplied source,
// server root and symlink policy. It does not validate or change persisted fields.
// source must be non-nil. Symlink confinement requires an OS-backed source.
// Filesystems without OS symlink support must use
// followExternalSymlinks=true to retain lexical scope confinement only.
func (u *User) BindFilesystem(source afero.Fs, baseScope string, followExternalSymlinks bool) {
	scope := filepath.Join(baseScope, filepath.Join("/", u.Scope))
	u.Fs = files.NewFs(source, scope, followExternalSymlinks)
}

// Validate checks selected persisted fields and supplies their defaults without
// reading, initializing or replacing the runtime filesystem. No selection
// validates all checkable fields.
func (u *User) Validate(fields ...string) error {
	if len(fields) == 0 {
		fields = checkableFields
	}

	for _, field := range fields {
		switch field {
		case "Username":
			if u.Username == "" {
				return fberrors.ErrEmptyUsername
			}
		case "Password":
			if u.Password == "" {
				return fberrors.ErrEmptyPassword
			}
		case "ViewMode":
			if u.ViewMode == "" {
				u.ViewMode = ListViewMode
			}
		case "Commands":
			if u.Commands == nil {
				u.Commands = []string{}
			}
		case "Sorting":
			if u.Sorting.By == "" {
				u.Sorting.By = "name"
			}
		case "Rules":
			if u.Rules == nil {
				u.Rules = []rules.Rule{}
			}
		}
	}

	return nil
}

// FullPath gets the full path for a user's relative path.
func (u *User) FullPath(path string) string {
	return afero.FullBaseFsPath(files.BasePath(u.Fs), path)
}
