package bolt

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/asdine/storm/v3"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/users"
)

// GetByScope must match case-insensitively: on a case-insensitive filesystem
// two scopes that differ only in case resolve to the same home directory, so
// the provisioning collision check has to treat them as the same scope.
func TestGetByScopeCaseInsensitive(t *testing.T) {
	db, err := storm.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	st, err := NewStorage(db)
	if err != nil {
		t.Fatalf("new storage: %v", err)
	}
	if err := st.Users.Save(&users.User{Username: "CaseVictim", Password: "pw", Scope: "/users/CaseVictim"}); err != nil {
		t.Fatalf("save: %v", err)
	}

	for _, scope := range []string{"/users/CaseVictim", "/users/casevictim", "/USERS/CASEVICTIM"} {
		u, err := st.Users.GetByScope(scope)
		if err != nil {
			t.Errorf("GetByScope(%q) unexpected error: %v", scope, err)
			continue
		}
		if u.Username != "CaseVictim" {
			t.Errorf("GetByScope(%q) returned %q, want CaseVictim", scope, u.Username)
		}
	}

	// A genuinely different scope must still miss (and the regex-escaped query
	// must not match a superstring).
	for _, scope := range []string{"/users/other", "/users/CaseVictimX"} {
		if _, err := st.Users.GetByScope(scope); !errors.Is(err, fberrors.ErrNotExist) {
			t.Errorf("GetByScope(%q) expected ErrNotExist, got %v", scope, err)
		}
	}
}

func TestUserPatchAtomicPersistence(t *testing.T) {
	db, err := storm.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	st, err := NewStorage(db)
	if err != nil {
		t.Fatal(err)
	}
	original := &users.User{Username: "alice", Password: "hash", SingleClick: true, Locale: "en"}
	if err := st.Users.Save(original); err != nil {
		t.Fatal(err)
	}
	if err := st.Users.Save(&users.User{Username: "bob", Password: "hash"}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		update users.User
		fields []string
	}{
		{"unknown late field", users.User{ID: original.ID, SingleClick: false}, []string{"SingleClick", "Unknown"}},
		{"unique collision", users.User{ID: original.ID, Username: "bob", SingleClick: false}, []string{"SingleClick", "Username"}},
		{"invalid multi field", users.User{ID: original.ID, Username: "", SingleClick: false}, []string{"SingleClick", "Username"}},
		{"lowercase validation", users.User{ID: original.ID, Username: "", SingleClick: false}, []string{"singleClick", "username"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := st.Users.Update(&tc.update, tc.fields...); err == nil {
				t.Fatal("expected rejection")
			}
			if tc.update.Fs != nil {
				t.Fatal("rejected update changed caller-owned user")
			}
			got, err := st.Users.Get("", false, original.ID)
			if err != nil {
				t.Fatal(err)
			}
			if !got.SingleClick || got.Username != "alice" {
				t.Fatalf("partial update: %+v", got)
			}
			if st.Users.LastUpdate(original.ID) != 0 {
				t.Fatal("failed update invalidated tokens")
			}
		})
	}
	// A stale caller updating one field must preserve another caller's change.
	stale := *original
	latest := *original
	latest.Locale = "fr"
	if err := st.Users.Update(&latest, "Locale"); err != nil {
		t.Fatal(err)
	}
	stale.SingleClick = false
	if err := st.Users.Update(&stale, "SingleClick"); err != nil {
		t.Fatal(err)
	}
	got, err := st.Users.Get("", false, original.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.SingleClick || got.Locale != "fr" || got.Password != "hash" {
		t.Fatalf("bad merged persistence: %+v", got)
	}
}
