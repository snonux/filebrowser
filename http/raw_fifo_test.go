//go:build unix

package fbhttp

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/spf13/afero"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/share"
	"github.com/filebrowser/filebrowser/v2/users"
)

// serveOrHang runs the handler and fails the test if it does not answer in
// time. A blocked open(2) on a named pipe cannot be interrupted, so a hang here
// is exactly the defect under test rather than a slow machine.
func serveOrHang(t *testing.T, handler http.Handler, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()

	rec := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		defer close(done)
		handler.ServeHTTP(rec, req)
	}()

	select {
	case <-done:
		return rec
	case <-time.After(5 * time.Second):
		t.Fatalf("VULNERABLE: %s %s hung on a named pipe", req.Method, req.URL.Path)
		return nil
	}
}

// Regression for GHSA-8q5j-8wcr-8v2v: archiving a directory that contains a
// named pipe, or downloading a public share that points at one, opened the pipe
// and blocked forever. Both filesystem flavours are covered: the scoped one,
// which refuses to open special files at all, and the bare one used when
// external symlinks are followed, which relies on the handlers' own checks.
func TestDownloadsDoNotHangOnNamedPipes(t *testing.T) {
	for name, followExternal := range map[string]bool{"scoped fs": false, "follow external symlinks": true} {
		t.Run(name, func(t *testing.T) {
			scope := t.TempDir()
			if err := os.MkdirAll(filepath.Join(scope, "f"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(scope, "f", "normal.txt"), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := syscall.Mkfifo(filepath.Join(scope, "f", "pipe"), 0o644); err != nil {
				t.Skipf("cannot create a named pipe: %v", err)
			}
			if err := os.Symlink("pipe", filepath.Join(scope, "f", "pipelink")); err != nil {
				t.Skipf("cannot create symlink: %v", err)
			}

			key := []byte("test-signing-key")
			perm := users.Permissions{Share: true, Download: true}
			st := scopedUserStorage(t, scope, perm, key)
			st.Users.(*customFSUser).followExternal = followExternal
			st.Users.(*customFSUser).fs = afero.NewBasePathFs(afero.NewOsFs(), scope)
			for hash, path := range map[string]string{"dir": "/f", "pipe": "/f/pipe", "link": "/f/pipelink"} {
				if err := st.Share.Save(&share.Link{Hash: hash, UserID: 1, Path: path}); err != nil {
					t.Fatal(err)
				}
			}
			server := &settings.Server{FollowExternalSymlinks: followExternal}

			assertArchive := func(t *testing.T, rec *httptest.ResponseRecorder) {
				t.Helper()
				if rec.Code != http.StatusOK {
					t.Fatalf("archive status = %d body=%q, want 200", rec.Code, rec.Body.String())
				}
				zr, err := zip.NewReader(bytes.NewReader(rec.Body.Bytes()), int64(rec.Body.Len()))
				if err != nil {
					t.Fatalf("archive is not a zip: %v", err)
				}
				var names []string
				for _, f := range zr.File {
					names = append(names, f.Name)
				}
				if len(names) != 1 || names[0] != "normal.txt" {
					t.Fatalf("archive entries = %v, want only normal.txt", names)
				}
			}

			t.Run("authenticated archive skips the pipe", func(t *testing.T) {
				req, _ := http.NewRequest(http.MethodGet, "/f/?algo=zip", http.NoBody)
				req.Header.Set("X-Auth", signToken(t, perm, key))
				assertArchive(t, serveOrHang(t, handle(rawHandler, "", st, server), req))
			})

			t.Run("public archive skips the pipe", func(t *testing.T) {
				req := newHTTPRequest(t, func(r *http.Request) { r.URL.Path = "dir/" })
				assertArchive(t, serveOrHang(t, handle(publicDlHandler, "", st, server), req))
			})

			t.Run("public share of a pipe is refused", func(t *testing.T) {
				for _, hash := range []string{"pipe", "link"} {
					req := newHTTPRequest(t, func(r *http.Request) { r.URL.Path = hash })
					rec := serveOrHang(t, handle(publicDlHandler, "", st, server), req)
					if rec.Code == http.StatusOK {
						t.Errorf("share %q of a named pipe = 200, want a refusal", hash)
					}
				}
			})
		})
	}
}
