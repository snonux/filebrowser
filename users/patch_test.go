package users

import (
	"encoding/json"
	"errors"
	"testing"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
)

func TestUserPatchPresenceAndAllowlist(t *testing.T) {
	current := User{ID: 1, Username: "alice", Password: "hash", SingleClick: true, HideDotfiles: true}
	for _, tc := range []struct {
		name, data string
		which      []string
		fail       bool
	}{
		{"false", `{"id":1,"singleClick":false}`, []string{"singleClick"}, false},
		{"absent", `{"id":1,"locale":"en"}`, []string{"locale"}, false},
		{"unknown late selection", `{"id":1,"singleClick":false}`, []string{"singleClick", "futureField"}, true},
		{"unknown data", `{"id":1,"futureField":true}`, nil, true},
		{"identity", `{"id":1}`, []string{"ID"}, true},
		{"filesystem", `{"id":1,"fs":{}}`, nil, true},
		{"missing", `{"id":1}`, []string{"singleClick"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, patch, _, err := DecodePatch(json.RawMessage(tc.data), tc.which)
			if (err != nil) != tc.fail {
				t.Fatalf("error = %v", err)
			}
			if tc.fail {
				return
			}
			merged := patch.Merge(current)
			if tc.name == "false" && merged.SingleClick {
				t.Fatal("explicit false was not applied")
			}
			if tc.name == "absent" && !merged.SingleClick {
				t.Fatal("absent field changed")
			}
			if !merged.HideDotfiles || !current.SingleClick {
				t.Fatal("unselected or input field changed")
			}
		})
	}
}

func TestUserPatchAuthorizationAndValidation(t *testing.T) {
	hash, err := HashPwd("existing-password!")
	if err != nil {
		t.Fatal(err)
	}
	current := User{ID: 1, Username: "alice", Password: hash, LockPassword: true}
	admin := User{ID: 2, Password: hash, Perm: Permissions{Admin: true}}
	for _, tc := range []struct {
		name, data string
		actor      *User
		full       bool
		want       error
	}{
		{"privilege escalation", `{"perm":{"admin":true}}`, &current, false, ErrForbiddenPatch},
		{"locked password", `{"password":"new-uncommon-password!"}`, &current, false, ErrForbiddenPatch},
		{"empty username", `{"username":"","singleClick":true}`, &admin, false, fberrors.ErrEmptyUsername},
		{"share requires download", `{"perm":{"share":true},"singleClick":true}`, &admin, false, fberrors.ErrShareRequiresDownload},
		{"empty password", `{"password":""}`, &admin, false, fberrors.ErrEmptyPassword},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var patch Patch
			if err := json.Unmarshal([]byte(tc.data), &patch); err != nil {
				t.Fatal(err)
			}
			_, _, err := patch.Prepare(current, tc.full, PatchPolicy{Actor: tc.actor})
			if !errors.Is(err, tc.want) {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
			if current.Username != "alice" || current.SingleClick || current.Password != hash {
				t.Fatal("input mutated on failure")
			}
		})
	}
	password := "new-uncommon-password!"
	merged, prepared, err := (Patch{Password: &password}).Prepare(current, false, PatchPolicy{Actor: &admin, RequireCurrentPassword: true, CurrentPassword: "existing-password!", MinimumPasswordLength: 8})
	if err != nil {
		t.Fatal(err)
	}
	if !CheckPwd(password, merged.Password) || prepared.Password == nil || password != "new-uncommon-password!" {
		t.Fatal("password hashing failed or changed input")
	}
	empty := ""
	merged, prepared, err = (Patch{Password: &empty}).Prepare(current, true, PatchPolicy{Actor: &admin})
	if err != nil || prepared.Password != nil || merged.Password != hash {
		t.Fatalf("full update did not preserve password: %v", err)
	}
	lock := false
	_, _, err = (Patch{LockPassword: &lock}).Prepare(current, false, PatchPolicy{Actor: &admin, RequireCurrentPassword: true})
	if !errors.Is(err, fberrors.ErrCurrentPasswordIncorrect) {
		t.Fatalf("lockPassword needs current password: %v", err)
	}
}

func TestUserPatchLegacyEmptyLists(t *testing.T) {
	_, patch, _, err := DecodePatch(json.RawMessage(`{"id":1,"commands":null,"rules":null}`), []string{"commands", "rules"})
	if err != nil {
		t.Fatal(err)
	}
	if patch.Commands == nil || patch.Rules == nil || *patch.Commands == nil || *patch.Rules == nil {
		t.Fatal("null lists did not become explicit empty lists")
	}
}
