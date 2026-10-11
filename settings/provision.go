package settings

import (
	"strings"

	"github.com/filebrowser/filebrowser/v2/users"
)

// ProvisioningMode identifies the policy for a newly created account.
type ProvisioningMode uint8

const (
	// ProvisionSignup restricts self-registered accounts.
	ProvisionSignup ProvisioningMode = iota
	// ProvisionProxy restricts proxy-created accounts and locks their random password.
	ProvisionProxy
	// ProvisionHook allows defaults and hook overrides, with a locked password.
	ProvisionHook
	// ProvisionCLI allows administrator-selected defaults and scopes.
	ProvisionCLI
)

// NewUser applies defaults, hashes the password and enforces the entry point's
// account policy. Proxy passwords are generated here rather than supplied.
// Hook and CLI overrides can be applied before ProvisionUser persists the user.
func (s *Settings) NewUser(username, password string, mode ProvisioningMode) (*users.User, error) {
	if mode == ProvisionProxy {
		var err error
		password, err = users.RandomPwd(DefaultMinimumPasswordLength + 10)
		if err != nil {
			return nil, err
		}
	}
	hash, err := users.ValidateAndHashPwd(password, s.MinimumPasswordLength)
	if err != nil {
		return nil, err
	}
	u := &users.User{Username: username, Password: hash}
	s.Defaults.Apply(u)
	switch mode {
	case ProvisionSignup, ProvisionProxy:
		// Execution and administrator rights require an explicit administrator grant.
		u.Perm.Admin = false
		u.Perm.Execute = false
		u.Commands = []string{}
	}
	u.LockPassword = mode == ProvisionProxy || mode == ProvisionHook
	return u, nil
}

// ProvisionUser creates the home and saves a new account with collision checks
// for derived scopes. Hook scopes are explicit only when returned by the hook;
// CLI scopes preserve the configured or flag-selected scope when nonempty.
func (s *Settings) ProvisionUser(store users.Store, u *users.User, serverRoot string, mode ProvisioningMode, explicitScope bool) error {
	switch mode {
	case ProvisionSignup, ProvisionProxy:
		explicitScope = false
	case ProvisionCLI:
		explicitScope = strings.TrimSpace(u.Scope) != ""
	}
	derived, err := s.CreateUserHome(u, serverRoot, explicitScope)
	if err != nil {
		return err
	}
	return store.SaveProvisioned(u, derived)
}
