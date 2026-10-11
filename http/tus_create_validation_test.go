package fbhttp

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

func TestTusCreationValidatesBeforeMutation(t *testing.T) {
	for _, length := range []string{"", "invalid", "-1", "9223372036854775808"} {
		t.Run("length="+length, func(t *testing.T) {
			scope := t.TempDir()
			name := filepath.Join(scope, "existing.txt")
			if err := os.WriteFile(name, []byte("keep me"), 0600); err != nil {
				t.Fatal(err)
			}
			key := []byte("test-key")
			perm := users.Permissions{Create: true, Modify: true}
			st := scopedUserStorage(t, scope, perm, key)
			cache := newMemoryUploadCache()
			t.Cleanup(cache.Close)
			handler := handle(tusPostHandler(cache), "", st, &settings.Server{})
			for _, path := range []string{"/existing.txt?override=true", "/new/sub/file.txt"} {
				req := httptest.NewRequest(http.MethodPost, path, http.NoBody)
				req.Header.Set("X-Auth", signToken(t, perm, key))
				req.Header.Set("Upload-Length", length)
				rec := httptest.NewRecorder()
				handler.ServeHTTP(rec, req)
				if rec.Code != http.StatusBadRequest {
					t.Fatalf("%s: status %d, body %q", path, rec.Code, rec.Body.String())
				}
			}
			if got, err := os.ReadFile(name); err != nil || string(got) != "keep me" {
				t.Fatalf("existing file changed: %q, %v", got, err)
			}
			if _, err := os.Stat(filepath.Join(scope, "new")); !os.IsNotExist(err) {
				t.Fatalf("rejected request created parent directory: %v", err)
			}
			if len(cache.cache.Items()) != 0 {
				t.Fatal("rejected request registered an upload")
			}
		})
	}
}

func TestTusCreationAcceptsValidLength(t *testing.T) {
	for _, path := range []string{"/new/sub/file.txt", "/existing.txt?override=true"} {
		t.Run(path, func(t *testing.T) {
			scope := t.TempDir()
			if err := os.WriteFile(filepath.Join(scope, "existing.txt"), []byte("old"), 0600); err != nil {
				t.Fatal(err)
			}
			key := []byte("test-key")
			perm := users.Permissions{Create: true, Modify: true}
			st := scopedUserStorage(t, scope, perm, key)
			cache := newMemoryUploadCache()
			t.Cleanup(cache.Close)
			req := httptest.NewRequest(http.MethodPost, path, http.NoBody)
			req.Header.Set("X-Auth", signToken(t, perm, key))
			req.Header.Set("Upload-Length", "5")
			rec := httptest.NewRecorder()
			handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, req)
			if rec.Code != http.StatusCreated {
				t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
			}
			if len(cache.cache.Items()) != 1 {
				t.Fatal("valid upload was not registered")
			}
		})
	}
}
