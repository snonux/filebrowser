package users

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/spf13/afero"
)

// TestUserCleanFs verifies that Clean builds the user filesystem according to the
// followExternalSymlinks flag and that FullPath resolves correctly for either
// implementation.
func TestUserCleanFs(t *testing.T) {
	base := t.TempDir()
	want := filepath.Join(base, "data", "x")

	t.Run("default builds a symlink-confining ScopedFs", func(t *testing.T) {
		u := &User{Username: "u", Password: "p", Scope: "data"}
		if err := u.Clean(base, false); err != nil {
			t.Fatal(err)
		}
		if _, ok := u.Fs.(*files.ScopedFs); !ok {
			t.Fatalf("expected *files.ScopedFs, got %T", u.Fs)
		}
		if got := u.FullPath("/x"); got != want {
			t.Fatalf("FullPath: got %q, want %q", got, want)
		}
	})

	t.Run("followExternalSymlinks builds a bare BasePathFs", func(t *testing.T) {
		u := &User{Username: "u", Password: "p", Scope: "data"}
		if err := u.Clean(base, true); err != nil {
			t.Fatal(err)
		}
		if _, ok := u.Fs.(*afero.BasePathFs); !ok {
			t.Fatalf("expected *afero.BasePathFs, got %T", u.Fs)
		}
		if got := u.FullPath("/x"); got != want {
			t.Fatalf("FullPath: got %q, want %q", got, want)
		}
	})
}

func TestValidateDefaultsWithoutFilesystem(t *testing.T) {
	u := &User{Username: "u", Password: "p", Scope: "/not-a-real-root/data"}
	if err := u.Validate(); err != nil {
		t.Fatal(err)
	}
	if u.Fs != nil {
		t.Fatal("validation initialized a filesystem")
	}
	if u.ViewMode != ListViewMode || u.Sorting.By != "name" || u.Commands == nil || u.Rules == nil {
		t.Fatalf("missing defaults: %+v", u)
	}
}

func TestValidateLeavesRuntimeFilesystemUntouched(t *testing.T) {
	for _, tc := range []struct {
		name string
		user User
		want error
	}{
		{"valid", User{Username: "u", Password: "p"}, nil},
		{"missing username", User{Password: "p"}, fberrors.ErrEmptyUsername},
		{"missing password", User{Username: "u"}, fberrors.ErrEmptyPassword},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source := afero.NewMemMapFs()
			tc.user.Fs = source
			if err := tc.user.Validate(); !errors.Is(err, tc.want) {
				t.Fatalf("Validate: got %v, want %v", err, tc.want)
			}
			if tc.user.Fs != source {
				t.Fatal("validation replaced the filesystem")
			}
		})
	}
	u := &User{}
	if err := u.Validate("ViewMode"); err != nil {
		t.Fatal(err)
	}
	if u.ViewMode != ListViewMode || u.Sorting.By != "" || u.Commands != nil || u.Rules != nil || u.Fs != nil {
		t.Fatalf("validation changed unselected fields: %+v", u)
	}
}

func TestBindFilesystemMemory(t *testing.T) {
	source := afero.NewMemMapFs()
	if err := source.MkdirAll("/server/data", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := afero.WriteFile(source, "/server/data/x", []byte("memory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := afero.WriteFile(source, "/server/outside", []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	u := &User{Scope: "data", Fs: afero.NewMemMapFs()}
	u.BindFilesystem(source, "/server", true)
	got, err := afero.ReadFile(u.Fs, "/x")
	if err != nil || string(got) != "memory" {
		t.Fatalf("reading injected filesystem: %q, %v", got, err)
	}
	if err := afero.WriteFile(u.Fs, "/new", []byte("bound"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := afero.ReadFile(source, "/server/data/new"); err != nil || string(got) != "bound" {
		t.Fatalf("write did not reach injected source: %q, %v", got, err)
	}
	if _, err := u.Fs.Open("../outside"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("scope traversal: %v", err)
	}
	if u.Scope != "data" || u.ViewMode != "" || u.Commands != nil {
		t.Fatalf("binding changed persisted fields: %+v", u)
	}
	if got := u.FullPath("/x"); got != filepath.Join("/server/data", "x") {
		t.Fatalf("FullPath: %q", got)
	}
}

func TestBindFilesystemOSSymlinkPolicy(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "data"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "outside"), []byte("external"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(root, "data", "link")); err != nil {
		t.Fatal(err)
	}
	for _, follow := range []bool{false, true} {
		u := &User{Scope: "data"}
		u.BindFilesystem(afero.NewOsFs(), root, follow)
		got, err := afero.ReadFile(u.Fs, "/link")
		if follow {
			if err != nil || string(got) != "external" {
				t.Fatalf("external symlink allowed: %q, %v", got, err)
			}
		} else if !errors.Is(err, os.ErrPermission) {
			t.Fatalf("external symlink denied: %v", err)
		}
	}
}
