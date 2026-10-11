package fbhttp

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/asdine/storm/v3"
	"github.com/gorilla/mux"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/storage/bolt"
	"github.com/filebrowser/filebrowser/v2/users"
)

func TestUserPutTypedPatch(t *testing.T) {
	for _, tc := range []struct {
		name, selection, data string
		want                  int
		wantSingleClick       bool
		wantLocale            string
	}{
		{"explicit false", `["singleClick"]`, `"singleClick":false`, http.StatusOK, false, "en"},
		{"preference", `["locale"]`, `"locale":"fr"`, http.StatusOK, true, "fr"},
		{"permissions", `["perm"]`, `"perm":{"admin":true}`, http.StatusForbidden, true, "en"},
		{"scope", `["scope"]`, `"scope":"/elsewhere"`, http.StatusForbidden, true, "en"},
		{"username", `["username"]`, `"username":"bob"`, http.StatusForbidden, true, "en"},
		{"commands", `["commands"]`, `"commands":["sh"]`, http.StatusForbidden, true, "en"},
		{"rules", `["rules"]`, `"rules":[]`, http.StatusForbidden, true, "en"},
		{"unknown late field", `["locale","unknown"]`, `"locale":"evil"`, http.StatusBadRequest, true, "en"},
		{"all", `["all"]`, `"locale":"evil"`, http.StatusForbidden, true, "en"},
		{"empty selection", `[]`, `"locale":"evil"`, http.StatusForbidden, true, "en"},
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
			user := &users.User{Username: "alice", Password: "hash", SingleClick: true, HideDotfiles: true, Locale: "en"}
			if err := st.Users.Save(user); err != nil {
				t.Fatal(err)
			}
			key := []byte("user-patch-test-key")
			d := &data{store: st, server: &settings.Server{}, settings: &settings.Settings{Key: key}}
			body := fmt.Sprintf(`{"what":"user","which":%s,"data":{"id":%d,%s}}`, tc.selection, user.ID, tc.data)
			req := httptest.NewRequest(http.MethodPut, "/api/users/1", strings.NewReader(body))
			req = mux.SetURLVars(req, map[string]string{"id": fmt.Sprint(user.ID)})
			req.Header.Set("X-Auth", signShareTestToken(t, user.ID, user.Username, user.Perm, key))
			status, err := userPutHandler(httptest.NewRecorder(), req, d)
			if status != tc.want {
				t.Fatalf("status = %d, want %d, error %v", status, tc.want, err)
			}
			got, err := st.Users.Get("", false, user.ID)
			if err != nil {
				t.Fatal(err)
			}
			if got.SingleClick != tc.wantSingleClick || !got.HideDotfiles || got.Perm.Admin || got.Username != "alice" || got.Scope != "" || got.Password != "hash" || len(got.Commands) != 0 || len(got.Rules) != 0 {
				t.Fatalf("unexpected stored user: %+v", got)
			}
			if got.Locale != tc.wantLocale {
				t.Fatalf("locale = %q, want %q", got.Locale, tc.wantLocale)
			}
		})
	}
}

func TestUserPutAdminFullPatch(t *testing.T) {
	db, err := storm.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	st, err := bolt.NewStorage(db)
	if err != nil {
		t.Fatal(err)
	}
	user := &users.User{Username: "alice", Password: "stored-hash", SingleClick: true, Locale: "fr"}
	if err := st.Users.Save(user); err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`{"what":"user","which":["all"],"data":{"id":%d,"password":"","singleClick":false}}`, user.ID)
	req := httptest.NewRequest(http.MethodPut, "/", strings.NewReader(body))
	status, err := updateUser(httptest.NewRecorder(), req, &data{raw: user.ID, user: &users.User{Perm: users.Permissions{Admin: true}}, store: st, server: &settings.Server{}, settings: &settings.Settings{}})
	if status != http.StatusOK {
		t.Fatalf("status = %d, error %v", status, err)
	}
	got, err := st.Users.Get("", false, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Password != "stored-hash" || got.SingleClick || got.Locale != "fr" {
		t.Fatalf("unexpected full patch: %+v", got)
	}
}
