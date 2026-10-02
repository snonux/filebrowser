package fbhttp

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/filebrowser/filebrowser/v2/diskcache"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

// Regression for GHSA-c4fr-5f24-4wrj: an upload aimed at an existing directory
// used to fail in the write and then have its failure cleanup recursively
// delete that directory, so a user with Create and Modify but no Delete
// permission could destroy whole trees.
func TestResourcePostDoesNotDeleteExistingDirectory(t *testing.T) {
	userScope := t.TempDir()
	if err := os.MkdirAll(filepath.Join(userScope, "team", "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	plan := filepath.Join(userScope, "team", "sub", "plan.txt")
	if err := os.WriteFile(plan, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}

	key := []byte("test-signing-key")
	perm := users.Permissions{Create: true, Modify: true} // no Delete
	st := scopedUserStorage(t, userScope, perm, key)
	signed := signToken(t, perm, key)

	post := func(target string) *httptest.ResponseRecorder {
		req, _ := http.NewRequest(http.MethodPost, target, strings.NewReader("x"))
		req.Header.Set("X-Auth", signed)
		rec := httptest.NewRecorder()
		handle(resourcePostHandler(diskcache.NewNoOp()), "", st, &settings.Server{}).ServeHTTP(rec, req)
		return rec
	}

	t.Run("upload over a directory is rejected and deletes nothing", func(t *testing.T) {
		rec := post("/team?override=true")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("POST /team?override=true = %d, want 400", rec.Code)
		}
		if _, err := os.Stat(plan); err != nil {
			t.Fatalf("VULNERABLE: upload over a directory deleted its contents: %v", err)
		}
	})

	t.Run("upload over a file still works", func(t *testing.T) {
		rec := post("/team/sub/plan.txt?override=true")
		if rec.Code != http.StatusOK {
			t.Fatalf("POST over an existing file = %d body=%q, want 200", rec.Code, rec.Body.String())
		}
		if data, err := os.ReadFile(plan); err != nil || string(data) != "x" {
			t.Fatalf("file content = %q, %v; want %q", data, err, "x")
		}
	})
}
