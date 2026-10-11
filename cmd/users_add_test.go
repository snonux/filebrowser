package cmd

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/asdine/storm/v3"
	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/storage/bolt"
	"github.com/filebrowser/filebrowser/v2/users"
	"github.com/spf13/cobra"
)

func TestAddUserProvisioning(t *testing.T) {
	for _, tc := range []struct{ name, defaultScope, flagScope, wantScope string }{
		{"derived", "", "", "/homes/team-x"},
		{"configured", "/shared", "", "/shared"},
		{"override", "/shared", "/chosen", "/chosen"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, err := storm.Open(filepath.Join(t.TempDir(), "db"))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = db.Close() })
			st, err := bolt.NewStorage(db)
			if err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			s := &settings.Settings{Key: []byte("key"), CreateUserDir: true, UserHomeBasePath: "/homes", MinimumPasswordLength: 8, Defaults: settings.UserDefaults{Scope: tc.defaultScope, AceEditorTheme: "monokai", Locale: "de", DateFormat: true, HideDotfiles: true, Perm: users.Permissions{Admin: true, Execute: true}, Commands: []string{"ls"}}}
			if err := st.Settings.Save(s); err != nil {
				t.Fatal(err)
			}
			if err := st.Settings.SaveServer(&settings.Server{Root: root}); err != nil {
				t.Fatal(err)
			}
			command := &cobra.Command{}
			addUserFlags(command.Flags())
			if err := command.Flags().Set("lockPassword", "true"); err != nil {
				t.Fatal(err)
			}
			if tc.flagScope != "" {
				if err := command.Flags().Set("scope", tc.flagScope); err != nil {
					t.Fatal(err)
				}
			}
			if err := addUser(command, []string{"team-x", "a-strong-password"}, &store{Storage: st}); err != nil {
				t.Fatal(err)
			}
			u, err := st.Users.Get(root, false, "team-x")
			if err != nil {
				t.Fatal(err)
			}
			if u.Scope != tc.wantScope || u.AceEditorTheme != "monokai" || u.Locale != "de" || !u.DateFormat || !u.HideDotfiles || !u.LockPassword || !u.Perm.Admin || !u.Perm.Execute || len(u.Commands) != 1 || !users.CheckPwd("a-strong-password", u.Password) {
				t.Fatalf("user = %+v", u)
			}
			if _, err := os.Stat(filepath.Join(root, tc.wantScope)); err != nil {
				t.Fatal(err)
			}
			err = addUser(command, []string{"team/x", "a-strong-password"}, &store{Storage: st})
			if tc.name == "derived" && !errors.Is(err, fberrors.ErrExist) {
				t.Fatalf("collision = %v", err)
			}
			if tc.name != "derived" && err != nil {
				t.Fatalf("intentional shared scope = %v", err)
			}
			var short fberrors.ErrShortPassword
			if err := addUser(command, []string{"short", "x"}, &store{Storage: st}); !errors.As(err, &short) {
				t.Fatalf("short password = %v", err)
			}
		})
	}
}
