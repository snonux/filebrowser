package auth

import (
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/rules"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
	"github.com/spf13/afero"
)

func TestAuthProvisioningDefaultsAndCollisions(t *testing.T) {
	for _, mode := range []string{"proxy", "hook"} {
		t.Run(mode, func(t *testing.T) {
			store := &mockUserStore{users: map[string]*users.User{}}
			srv := &settings.Server{Root: t.TempDir()}
			s := &settings.Settings{CreateUserDir: true, UserHomeBasePath: "/users", Defaults: settings.UserDefaults{Scope: ".", AceEditorTheme: "monokai", Locale: "de", DateFormat: true, HideDotfiles: true, Perm: users.Permissions{Admin: true, Execute: true}, Commands: []string{"ls"}}}
			create := func(name string) (*users.User, error) {
				if mode == "hook" {
					return newHookAuth(store, s, srv, name, map[string]string{}).SaveUser()
				}
				req := httptest.NewRequest("GET", "/", nil)
				req.Header.Set("X-User", name)
				return (ProxyAuth{Header: "X-User"}).Auth(req, store, s, srv)
			}
			u, err := create("team-x")
			if err != nil {
				t.Fatal(err)
			}
			if u.AceEditorTheme != "monokai" || u.Locale != "de" || !u.DateFormat || !u.HideDotfiles || !u.LockPassword {
				t.Fatalf("defaults lost: %+v", u)
			}
			if mode == "hook" && (!u.Perm.Admin || !u.Perm.Execute || len(u.Commands) != 1) {
				t.Fatalf("hook rights lost: %+v", u)
			}
			if u.Scope != "/users/team-x" {
				t.Fatal(u.Scope)
			}
			if _, err := os.Stat(filepath.Join(srv.Root, "users/team-x")); err != nil {
				t.Fatal(err)
			}
			if _, err := create("team/x"); !errors.Is(err, fberrors.ErrExist) {
				t.Fatalf("collision = %v", err)
			}
		})
	}
}

func TestHookUpdatePreservesFieldsAndOverrides(t *testing.T) {
	for _, scope := range []string{"/original", "/changed"} {
		t.Run(scope, func(t *testing.T) {
			pass, err := users.ValidateAndHashPwd("a-strong-password", 0)
			if err != nil {
				t.Fatal(err)
			}
			old := &users.User{ID: 42, Username: "alice", Password: pass, Scope: "/original", AceEditorTheme: "twilight", Rules: []rules.Rule{{}}, Commands: []string{"old"}, Fs: afero.NewMemMapFs()}
			store := &mockUserStore{users: map[string]*users.User{"alice": old}}
			hook := newHookAuth(store, &settings.Settings{}, &settings.Server{}, "alice", map[string]string{"user.locale": "fr", "user.scope": scope, "user.commands": "new other", "user.perm.admin": "true"})
			u, err := hook.SaveUser()
			if err != nil {
				t.Fatal(err)
			}
			if u.ID != 42 || u.AceEditorTheme != "twilight" || len(u.Rules) != 1 || u.Locale != "fr" || len(u.Commands) != 2 || !u.Perm.Download || !u.Perm.Execute || !u.LockPassword {
				t.Fatalf("fields lost: %+v", u)
			}
			if scope == old.Scope && u.Fs != old.Fs {
				t.Fatal("unchanged scope lost filesystem")
			}
			if scope != old.Scope && u.Fs != nil {
				t.Fatal("changed scope retains old filesystem")
			}
			if old.Scope != "/original" || old.Locale != "" || old.Commands[0] != "old" {
				t.Fatal("hook mutated input")
			}
		})
	}
}

func TestHookNewAccountOverridesDefaults(t *testing.T) {
	store := &mockUserStore{users: map[string]*users.User{}}
	s := &settings.Settings{CreateUserDir: true, UserHomeBasePath: "/homes", Defaults: settings.UserDefaults{AceEditorTheme: "monokai", Locale: "de", Perm: users.Permissions{Admin: true, Execute: true}, Commands: []string{"default"}}}
	hook := newHookAuth(store, s, &settings.Server{Root: t.TempDir()}, "alice", map[string]string{"user.scope": "/chosen", "user.locale": "fr", "user.perm.admin": "false", "user.perm.execute": "false", "user.commands": "custom"})
	u, err := hook.SaveUser()
	if err != nil {
		t.Fatal(err)
	}
	if u.Scope != "/chosen" || u.Locale != "fr" || u.AceEditorTheme != "monokai" || u.Perm.Admin || u.Perm.Execute || len(u.Commands) != 1 || u.Commands[0] != "custom" || !users.CheckPwd("a-strong-password", u.Password) {
		t.Fatalf("overrides lost: %+v", u)
	}
	if s.Defaults.Commands[0] != "default" || !s.Defaults.Perm.Admin || s.Defaults.Locale != "de" {
		t.Fatal("hook modified configured defaults")
	}
}
