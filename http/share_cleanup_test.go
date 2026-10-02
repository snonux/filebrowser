package fbhttp

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/asdine/storm/v3"

	"github.com/filebrowser/filebrowser/v2/diskcache"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/share"
	"github.com/filebrowser/filebrowser/v2/storage"
	"github.com/filebrowser/filebrowser/v2/storage/bolt"
	"github.com/filebrowser/filebrowser/v2/users"
)

// shareCleanupFixture is a server root shared by three users, as in production
// (no injected filesystem — each user's scope is resolved under the root):
//
//	admin   scope /        every permission
//	owner   scope /        shares files the admin can also reach
//	tenant  scope /tenant  whose scope-relative paths collide with root paths
type shareCleanupFixture struct {
	st     *storage.Storage
	server *settings.Server
	root   string
	key    []byte
	admin  *users.User
	owner  *users.User
	tenant *users.User
}

func newShareCleanupFixture(t *testing.T) *shareCleanupFixture {
	t.Helper()

	root := t.TempDir()
	db, err := storm.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatalf("failed to open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	st, err := bolt.NewStorage(db)
	if err != nil {
		t.Fatalf("failed to get storage: %v", err)
	}

	f := &shareCleanupFixture{st: st, server: &settings.Server{Root: root}, root: root, key: []byte("test-signing-key")}
	all := users.Permissions{Create: true, Rename: true, Modify: true, Delete: true, Share: true, Download: true}
	f.admin = &users.User{Username: "admin", Password: "pw", Scope: "/", Perm: all}
	f.admin.Perm.Admin = true
	f.owner = &users.User{Username: "owner", Password: "pw", Scope: "/", Perm: all}
	f.tenant = &users.User{Username: "tenant", Password: "pw", Scope: "/tenant", Perm: all}
	for _, u := range []*users.User{f.admin, f.owner, f.tenant} {
		if err := st.Users.Save(u); err != nil {
			t.Fatalf("failed to save user %s: %v", u.Username, err)
		}
	}
	if err := st.Settings.Save(&settings.Settings{Key: f.key}); err != nil {
		t.Fatalf("failed to save settings: %v", err)
	}

	return f
}

// write creates a file under the server root, with its parent directories.
func (f *shareCleanupFixture) write(t *testing.T, rel string) {
	t.Helper()
	full := filepath.Join(f.root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// share records a public share of path as seen from u's scope.
func (f *shareCleanupFixture) share(t *testing.T, hash string, u *users.User, path string) {
	t.Helper()
	if err := f.st.Share.Save(&share.Link{Hash: hash, UserID: u.ID, Path: path}); err != nil {
		t.Fatalf("failed to save share %s: %v", hash, err)
	}
}

// do sends a request as u through fn and returns the status code.
func (f *shareCleanupFixture) do(t *testing.T, fn handleFunc, u *users.User, method, target string) int {
	t.Helper()
	req, err := http.NewRequest(method, target, http.NoBody)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Auth", signShareTestToken(t, u.ID, u.Username, u.Perm, f.key))
	rec := httptest.NewRecorder()
	handle(fn, "", f.st, f.server).ServeHTTP(rec, req)
	return rec.Code
}

// exists reports whether the share record is still stored.
func (f *shareCleanupFixture) exists(hash string) bool {
	_, err := f.st.Share.GetByHash(hash)
	return err == nil
}

// Regression for GHSA-r6pg-pg54-rcr5: deleting a file only removed the shares
// owned by the user doing the delete, so a share another user held on the same
// file survived and later served whatever appeared at that path.
func TestDeleteRemovesSharesOfOtherUsers(t *testing.T) {
	f := newShareCleanupFixture(t)
	f.write(t, "x.txt")
	f.write(t, "dir/inner.txt")
	f.write(t, "tenant/x.txt")
	f.write(t, "keep.txt")

	f.share(t, "owner-file", f.owner, "/x.txt")
	f.share(t, "owner-inner", f.owner, "/dir/inner.txt")
	f.share(t, "owner-keep", f.owner, "/keep.txt")
	// Same stored path string as owner-file, but a different file on disk.
	f.share(t, "tenant-file", f.tenant, "/x.txt")

	del := resourceDeleteHandler(diskcache.NewNoOp())
	if code := f.do(t, del, f.admin, http.MethodDelete, "/x.txt"); code != http.StatusNoContent {
		t.Fatalf("DELETE /x.txt = %d, want 204", code)
	}
	if code := f.do(t, del, f.admin, http.MethodDelete, "/dir/"); code != http.StatusNoContent {
		t.Fatalf("DELETE /dir/ = %d, want 204", code)
	}

	for _, hash := range []string{"owner-file", "owner-inner"} {
		if f.exists(hash) {
			t.Errorf("VULNERABLE: share %q survived the deletion of its file by another user", hash)
		}
	}
	// Dropping the owner filter outright would reopen GHSA-5ww9-jg6q-38r7:
	// shares on other files must survive, including one whose path collides.
	for _, hash := range []string{"owner-keep", "tenant-file"} {
		if !f.exists(hash) {
			t.Errorf("share %q on an unrelated file was deleted", hash)
		}
	}
}
