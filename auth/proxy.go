package auth

import (
	"errors"
	"net/http"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

// MethodProxyAuth is used to identify no auth.
const MethodProxyAuth settings.AuthMethod = "proxy"

// ProxyAuth is a proxy implementation of an auther.
type ProxyAuth struct {
	Header string `json:"header"`
}

// Auth authenticates the user via an HTTP header.
func (a ProxyAuth) Auth(r *http.Request, usr users.Store, setting *settings.Settings, srv *settings.Server) (*users.User, error) {
	username := r.Header.Get(a.Header)
	user, err := usr.Get(srv.Root, srv.FollowExternalSymlinks, username)
	if errors.Is(err, fberrors.ErrNotExist) {
		return a.createUser(usr, setting, srv, username)
	}
	return user, err
}

func (a ProxyAuth) createUser(usr users.Store, setting *settings.Settings, srv *settings.Server, username string) (*users.User, error) {
	user, err := setting.NewUser(username, "", settings.ProvisionProxy)
	if err != nil {
		return nil, err
	}
	if err := setting.ProvisionUser(usr, user, srv.Root, settings.ProvisionProxy, false); err != nil {
		return nil, err
	}

	return user, nil
}

// LoginPage tells that proxy auth doesn't require a login page.
func (a ProxyAuth) LoginPage() bool {
	return false
}
