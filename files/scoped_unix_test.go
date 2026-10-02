//go:build unix

package files

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/spf13/afero"
)

// Opening a writer-less named pipe blocks forever, so the scoped filesystem
// must refuse it — directly and through a symlink — while regular files,
// directories and not-yet-existing files keep opening.
func TestScopedFsRefusesToOpenNamedPipes(t *testing.T) {
	scope := t.TempDir()
	if err := os.WriteFile(filepath.Join(scope, "file.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(scope, "pipe"), 0o644); err != nil {
		t.Skipf("cannot create a named pipe: %v", err)
	}
	if err := os.Symlink("pipe", filepath.Join(scope, "pipelink")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}

	afs := NewScopedFs(afero.NewOsFs(), scope)

	for _, name := range []string{"/pipe", "/pipelink"} {
		done := make(chan error, 2)
		go func() {
			_, err := afs.Open(name)
			done <- err
		}()
		go func() {
			_, err := afs.OpenFile(name, os.O_WRONLY|os.O_APPEND, 0o644)
			done <- err
		}()

		for range 2 {
			select {
			case err := <-done:
				if !os.IsPermission(err) {
					t.Errorf("opening %s: err = %v, want a permission error", name, err)
				}
			case <-time.After(5 * time.Second):
				t.Fatalf("VULNERABLE: opening %s blocked", name)
			}
		}
	}

	for _, name := range []string{"/file.txt", "/"} {
		f, err := afs.Open(name)
		if err != nil {
			t.Fatalf("opening %s: %v", name, err)
		}
		_ = f.Close()
	}

	f, err := afs.OpenFile("/new.txt", os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("creating a new file: %v", err)
	}
	_ = f.Close()
}
