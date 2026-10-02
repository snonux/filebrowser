package fbhttp

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/filebrowser/filebrowser/v2/diskcache"
	"github.com/filebrowser/filebrowser/v2/rules"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/share"
	"github.com/filebrowser/filebrowser/v2/users"
)

// symlinkAliasScope lays out a scope in which "/denied" is reachable through
// links that live under "/allowed":
//
//	/denied/secret.txt
//	/other/public.txt
//	/allowed/link   -> ../denied             (directory alias)
//	/allowed/flink  -> ../denied/secret.txt  (file alias)
//	/allowed/newln  -> ../denied/new.txt     (dangling alias)
//	/allowed/ok     -> ../other              (alias of an allowed directory)
//
// It skips the test where symlinks are unavailable.
func symlinkAliasScope(t *testing.T) string {
	t.Helper()

	scope := t.TempDir()
	for _, dir := range []string{"denied", "other", "allowed"} {
		if err := os.MkdirAll(filepath.Join(scope, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(scope, "denied", "secret.txt"), []byte("SECRET"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scope, "other", "public.txt"), []byte("PUBLIC"), 0o644); err != nil {
		t.Fatal(err)
	}

	links := map[string]string{
		"link":  filepath.Join("..", "denied"),
		"flink": filepath.Join("..", "denied", "secret.txt"),
		"newln": filepath.Join("..", "denied", "new.txt"),
		"ok":    filepath.Join("..", "other"),
	}
	for name, target := range links {
		if err := os.Symlink(target, filepath.Join(scope, "allowed", name)); err != nil {
			t.Skipf("cannot create symlink on this platform: %v", err)
		}
	}

	return scope
}

// Regression for GHSA-7w29-q235-57m9: the rule check matched only the requested
// name while the filesystem followed symbolic links, so a link under an allowed
// path that points at a rule-denied object let a user read and overwrite it.
func TestRuleDeniesSymlinkAliasOfDeniedPath(t *testing.T) {
	scope := symlinkAliasScope(t)

	key := []byte("test-signing-key")
	perm := users.Permissions{Create: true, Modify: true, Download: true}
	st := denyRuleStorage(t, scope, "/denied", perm, key)
	signed := signToken(t, perm, key)

	do := func(fn handleFunc, method, path, body string) *httptest.ResponseRecorder {
		req, _ := http.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("X-Auth", signed)
		rec := httptest.NewRecorder()
		handle(fn, "", st, &settings.Server{}).ServeHTTP(rec, req)
		return rec
	}
	secret := filepath.Join(scope, "denied", "secret.txt")

	t.Run("the denied name is refused", func(t *testing.T) {
		if rec := do(rawHandler, http.MethodGet, "/denied/secret.txt", ""); rec.Code != http.StatusForbidden {
			t.Fatalf("GET /denied/secret.txt = %d, want 403", rec.Code)
		}
	})

	t.Run("reading through an alias is refused", func(t *testing.T) {
		for _, path := range []string{"/allowed/link/secret.txt", "/allowed/flink"} {
			if rec := do(rawHandler, http.MethodGet, path, ""); rec.Code != http.StatusForbidden {
				t.Errorf("VULNERABLE: GET %s = %d body=%q, want 403", path, rec.Code, rec.Body.String())
			}
		}
	})

	t.Run("overwriting through an alias is refused", func(t *testing.T) {
		for _, path := range []string{"/allowed/link/secret.txt", "/allowed/flink"} {
			if rec := do(resourcePutHandler, http.MethodPut, path, "TAMPERED"); rec.Code != http.StatusForbidden {
				t.Errorf("VULNERABLE: PUT %s = %d, want 403", path, rec.Code)
			}
		}
		if data, err := os.ReadFile(secret); err != nil || string(data) != "SECRET" {
			t.Fatalf("VULNERABLE: denied file was modified: %q, %v", data, err)
		}
	})

	t.Run("creating through an alias is refused", func(t *testing.T) {
		post := resourcePostHandler(diskcache.NewNoOp())
		// A new name behind the directory alias, and a dangling link whose
		// target would be created inside the denied directory.
		for _, path := range []string{"/allowed/link/new.txt", "/allowed/newln"} {
			if rec := do(post, http.MethodPost, path, "NEW"); rec.Code != http.StatusForbidden {
				t.Errorf("VULNERABLE: POST %s = %d, want 403", path, rec.Code)
			}
		}
		if _, err := os.Stat(filepath.Join(scope, "denied", "new.txt")); err == nil {
			t.Fatal("VULNERABLE: a file was created inside the denied directory")
		}
	})

	t.Run("an alias of an allowed path still works", func(t *testing.T) {
		rec := do(rawHandler, http.MethodGet, "/allowed/ok/public.txt", "")
		if rec.Code != http.StatusOK || rec.Body.String() != "PUBLIC" {
			t.Fatalf("GET /allowed/ok/public.txt = %d body=%q, want 200 PUBLIC", rec.Code, rec.Body.String())
		}
	})
}

// The same alias must not work through a public share either. There the user's
// filesystem is rebased onto the shared directory, so the link target has to be
// measured against the owner's original scope, where the rules live.
func TestPublicShareDeniesSymlinkAliasOfDeniedPath(t *testing.T) {
	scope := t.TempDir()
	for _, dir := range []string{"denied", "allowed"} {
		if err := os.MkdirAll(filepath.Join(scope, "shared", dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(scope, "shared", "denied", "secret.txt"), []byte("SECRET"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scope, "shared", "allowed", "public.txt"), []byte("PUBLIC"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join("..", "denied"), filepath.Join(scope, "shared", "allowed", "link")); err != nil {
		t.Skipf("cannot create symlink on this platform: %v", err)
	}

	key := []byte("test-signing-key")
	st := scopedUserStorage(t, scope, users.Permissions{Share: true, Download: true}, key)
	if err := st.Settings.Save(&settings.Settings{
		Key:   key,
		Rules: []rules.Rule{{Path: "/shared/denied", Allow: false}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.Share.Save(&share.Link{Hash: "h", UserID: 1, Path: "/shared"}); err != nil {
		t.Fatal(err)
	}

	get := func(path string) *httptest.ResponseRecorder {
		req := newHTTPRequest(t, func(r *http.Request) { r.URL.Path = path })
		rec := httptest.NewRecorder()
		handle(publicDlHandler, "", st, &settings.Server{}).ServeHTTP(rec, req)
		return rec
	}

	if rec := get("h/denied/secret.txt"); rec.Code == http.StatusOK {
		t.Fatalf("GET h/denied/secret.txt = 200, the rule itself is not applied")
	}
	if rec := get("h/allowed/link/secret.txt"); rec.Code == http.StatusOK {
		t.Fatalf("VULNERABLE: share served a rule-denied file through an alias: %q", rec.Body.String())
	}
	if rec := get("h/allowed/public.txt"); rec.Code != http.StatusOK || rec.Body.String() != "PUBLIC" {
		t.Fatalf("GET h/allowed/public.txt = %d body=%q, want 200 PUBLIC", rec.Code, rec.Body.String())
	}
}
