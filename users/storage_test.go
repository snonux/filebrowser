package users

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/spf13/afero"
)

// Interface is implemented by storage
var _ Store = &Storage{}

// slowBackend is a minimal StorageBackend whose scope lookup is deliberately
// slow, so that an unsynchronized check-then-save reliably interleaves.
type slowBackend struct {
	mu    sync.Mutex
	users []*User
	delay time.Duration
}

func (b *slowBackend) GetByScope(scope string) (*User, error) {
	time.Sleep(b.delay)

	b.mu.Lock()
	defer b.mu.Unlock()
	for _, u := range b.users {
		if strings.EqualFold(u.Scope, scope) {
			return u, nil
		}
	}
	return nil, fberrors.ErrNotExist
}

func (b *slowBackend) Save(u *User) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.users = append(b.users, u)
	return nil
}

func (b *slowBackend) GetBy(interface{}) (*User, error) { return nil, fberrors.ErrNotExist }
func (b *slowBackend) Gets() ([]*User, error)           { return b.users, nil }
func (b *slowBackend) Update(*User, ...string) error    { return nil }
func (b *slowBackend) DeleteByID(uint) error            { return nil }
func (b *slowBackend) DeleteByUsername(string) error    { return nil }
func (b *slowBackend) CountAdmins() (int, error)        { return 0, nil }

// Two usernames that normalize to the same home directory must not both be
// provisioned, even when their requests are handled concurrently: checking the
// scope and saving the user has to be a single atomic step.
func TestSaveProvisionedRejectsConcurrentScopeCollision(t *testing.T) {
	back := &slowBackend{delay: 50 * time.Millisecond}
	store := NewStorage(back)

	errs := make([]error, 2)
	var wg, ready sync.WaitGroup
	ready.Add(2)
	for i, username := range []string{"teamone-x", "teamone/x"} {
		wg.Add(1)
		go func(i int, username string) {
			defer wg.Done()
			// Only start once both goroutines are actually running, so that an
			// unsynchronized implementation is guaranteed to interleave rather
			// than to pass by scheduling luck.
			ready.Done()
			ready.Wait()
			errs[i] = store.SaveProvisioned(&User{
				Username: username,
				Password: "pw",
				Scope:    "/users/teamone-x",
			}, true)
		}(i, username)
	}
	wg.Wait()

	saved := 0
	for _, err := range errs {
		switch {
		case err == nil:
			saved++
		case !errors.Is(err, fberrors.ErrExist):
			t.Fatalf("unexpected error: %v", err)
		}
	}

	if saved != 1 {
		t.Fatalf("VULNERABLE: %d users provisioned into /users/teamone-x, want 1", saved)
	}
	if len(back.users) != 1 {
		t.Fatalf("%d users stored, want 1", len(back.users))
	}
}

// A scope that was not derived from the username (explicitly configured by an
// administrator or returned by an auth hook) may legitimately be shared, so it
// must not be subject to the collision check.
func TestSaveProvisionedAllowsSharedExplicitScope(t *testing.T) {
	back := &slowBackend{}
	store := NewStorage(back)

	for _, username := range []string{"alice", "bob"} {
		if err := store.SaveProvisioned(&User{
			Username: username,
			Password: "pw",
			Scope:    "/shared/team",
		}, false); err != nil {
			t.Fatalf("saving %q with an explicit shared scope: %v", username, err)
		}
	}

	if len(back.users) != 2 {
		t.Fatalf("%d users stored, want 2", len(back.users))
	}
}

// validationBackend captures writes and returns copies, as a persisted backend
// does, so runtime binding cannot accidentally be reused by a later read.
type validationBackend struct {
	slowBackend
	stored User
}

func (b *validationBackend) Save(u *User) error {
	b.stored = *u
	return nil
}

func (b *validationBackend) Update(u *User, _ ...string) error {
	b.stored = *u
	return nil
}

func (b *validationBackend) GetBy(interface{}) (*User, error) {
	u := b.stored
	return &u, nil
}

func (b *validationBackend) Gets() ([]*User, error) {
	u := b.stored
	return []*User{&u}, nil
}

func TestStorageWritesOnlyValidate(t *testing.T) {
	back := &validationBackend{}
	store := NewStorageWithFilesystem(back, nil) // Writes never need a source.
	u := &User{ID: 7, Username: "u", Password: "p", Scope: "/missing"}
	if err := store.Save(u); err != nil {
		t.Fatal(err)
	}
	if u.Fs != nil || back.stored.Fs != nil || back.stored.ViewMode != ListViewMode {
		t.Fatalf("save initialized filesystem or missed defaults: %+v", back.stored)
	}
	u.ViewMode = ""
	if err := store.Update(u, "ViewMode"); err != nil {
		t.Fatal(err)
	}
	if u.Fs != nil || u.ViewMode != "" || back.stored.Fs != nil || back.stored.ViewMode != ListViewMode {
		t.Fatalf("update changed caller or initialized filesystem: %+v", back.stored)
	}
}

func TestStorageReadsBindInjectedFilesystem(t *testing.T) {
	source := afero.NewMemMapFs()
	if err := source.MkdirAll("/server/data", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := afero.WriteFile(source, "/server/data/file", []byte("injected"), 0o600); err != nil {
		t.Fatal(err)
	}
	back := &validationBackend{stored: User{Username: "u", Password: "p", Scope: "data"}}
	store := NewStorageWithFilesystem(back, source)
	u, err := store.Get("/server", true, "u")
	if err != nil {
		t.Fatal(err)
	}
	all, err := store.Gets("/server", true)
	if err != nil {
		t.Fatal(err)
	}
	for _, user := range append(all, u) {
		got, err := afero.ReadFile(user.Fs, "/file")
		if err != nil || string(got) != "injected" {
			t.Fatalf("runtime read ignored injected source: %q, %v", got, err)
		}
	}
	if back.stored.Fs != nil {
		t.Fatal("read changed persisted user filesystem")
	}
}

func TestStorageReadValidationFailureDoesNotBind(t *testing.T) {
	back := &validationBackend{stored: User{Password: "p"}}
	store := NewStorageWithFilesystem(back, nil)
	if _, err := store.Get("/server", false, "u"); !errors.Is(err, fberrors.ErrEmptyUsername) {
		t.Fatalf("Get: %v", err)
	}
	if _, err := store.Gets("/server", false); !errors.Is(err, fberrors.ErrEmptyUsername) {
		t.Fatalf("Gets: %v", err)
	}
}

func TestStorageReadPreservesExistingRuntimeFilesystem(t *testing.T) {
	existing := afero.NewMemMapFs()
	back := &validationBackend{stored: User{Username: "u", Password: "p", Fs: existing}}
	store := NewStorageWithFilesystem(back, nil)
	u, err := store.Get("/server", false, "u")
	if err != nil {
		t.Fatal(err)
	}
	if u.Fs != existing {
		t.Fatal("read replaced an already bound filesystem")
	}
}

func TestStorageReadsOSFilesystemPolicy(t *testing.T) {
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
	back := &validationBackend{stored: User{Username: "u", Password: "p", Scope: "data"}}
	for _, store := range []*Storage{NewStorage(back), NewStorageWithFilesystem(back, afero.NewOsFs())} {
		for _, follow := range []bool{false, true} {
			u, err := store.Get(root, follow, "u")
			if err != nil {
				t.Fatal(err)
			}
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
}

func TestPatchPrepareOnlyValidates(t *testing.T) {
	current := User{ID: 7, Username: "u", Password: "p", Scope: "/missing"}
	viewMode := ViewMode("")
	merged, _, err := (Patch{ViewMode: &viewMode}).Prepare(current, false, PatchPolicy{Actor: &current})
	if err != nil {
		t.Fatal(err)
	}
	if merged.Fs != nil || merged.ViewMode != ListViewMode || current.ViewMode != "" {
		t.Fatalf("prepare initialized filesystem or mutated original: %+v", merged)
	}
}
