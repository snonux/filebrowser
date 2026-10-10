package fbhttp

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/share"
	"github.com/filebrowser/filebrowser/v2/users"
	"golang.org/x/crypto/bcrypt"
)

// shareResponse is the client-facing representation of a share. It deliberately
// omits the server-side secrets of share.Link — the bcrypt PasswordHash (which
// would be crackable offline) and the bypass Token — exposing only whether the
// share is password-protected via HasPassword.
type shareResponse struct {
	Hash        string `json:"hash"`
	Path        string `json:"path"`
	UserID      uint   `json:"userID"`
	Expire      int64  `json:"expire"`
	HasPassword bool   `json:"hasPassword"`
}

func toShareResponse(l *share.Link) *shareResponse {
	return &shareResponse{
		Hash:        l.Hash,
		Path:        l.Path,
		UserID:      l.UserID,
		Expire:      l.Expire,
		HasPassword: l.PasswordHash != "",
	}
}

func toShareResponses(links []*share.Link) []*shareResponse {
	res := make([]*shareResponse, 0, len(links))
	for _, l := range links {
		res = append(res, toShareResponse(l))
	}
	return res
}

func withPermShare(fn handleFunc) handleFunc {
	return withUser(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
		if !d.user.Perm.Share || !d.user.Perm.Download {
			return http.StatusForbidden, nil
		}

		return fn(w, r, d)
	})
}

var shareListHandler = withPermShare(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
	var (
		s   []*share.Link
		err error
	)
	if d.user.Perm.Admin {
		s, err = d.store.Share.All()
	} else {
		s, err = d.store.Share.FindByUserID(d.user.ID)
	}
	if errors.Is(err, fberrors.ErrNotExist) {
		return renderJSON(w, r, []*shareResponse{})
	}

	if err != nil {
		return http.StatusInternalServerError, err
	}

	sort.Slice(s, func(i, j int) bool {
		if s[i].UserID != s[j].UserID {
			return s[i].UserID < s[j].UserID
		}
		return s[i].Expire < s[j].Expire
	})

	return renderJSON(w, r, toShareResponses(s))
})

var shareGetsHandler = withPermShare(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
	var (
		s   []*share.Link
		err error
	)
	if d.user.Perm.Admin {
		s, err = getSharesForAdminPath(d, r.URL.Path)
	} else {
		s, err = d.store.Share.Gets(r.URL.Path, d.user.ID)
	}
	if errors.Is(err, fberrors.ErrNotExist) {
		return renderJSON(w, r, []*shareResponse{})
	}

	if err != nil {
		return http.StatusInternalServerError, err
	}

	return renderJSON(w, r, toShareResponses(s))
})

func getSharesForAdminPath(d *data, path string) ([]*share.Link, error) {
	links, err := d.store.Share.All()
	if err != nil {
		return nil, err
	}

	adminPath := filepath.Clean(d.user.FullPath(path))
	owners := make(map[uint]*users.User)
	filtered := make([]*share.Link, 0, len(links))
	for _, link := range links {
		owner, err := shareOwner(d, owners, link.UserID)
		if err != nil {
			return nil, err
		}
		if owner != nil && filepath.Clean(owner.FullPath(link.Path)) == adminPath {
			filtered = append(filtered, link)
		}
	}

	return filtered, nil
}

// shareOwner returns the user owning a share, or nil if that user no longer
// exists. Lookups are memoized in owners, since one user usually owns many
// shares.
func shareOwner(d *data, owners map[uint]*users.User, id uint) (*users.User, error) {
	if owner, ok := owners[id]; ok {
		return owner, nil
	}

	owner, err := d.store.Users.Get(d.server.Root, d.server.FollowExternalSymlinks, id)
	if err != nil && !errors.Is(err, fberrors.ErrNotExist) {
		return nil, err
	}
	owners[id] = owner // owner is nil on ErrNotExist
	return owner, nil
}

// deleteSharesUnder removes every public share that points at path, or at
// something below it, in the current user's filesystem. It is called when that
// path stops naming what was shared — it was deleted or renamed — because a
// share is resolved lazily on each request: a record left behind would start
// serving whatever unrelated file later appears under the old name.
//
// Shares are matched by the on-disk location they resolve to through their own
// owner's scope, not by the stored path string. That removes the shares other
// users hold on the same file (an administrator deleting a user's shared file),
// while leaving alone a share whose scope-relative path merely collides with
// the one being removed but names a different file.
func deleteSharesUnder(d *data, path string) error {
	// Without a disk-backed filesystem there is no on-disk location to compare,
	// so fall back to matching the user's own shares by path.
	if files.BasePath(d.user.Fs) == nil {
		return d.store.Share.DeleteWithPathPrefix(path, d.user.ID)
	}

	links, err := d.store.Share.All()
	if errors.Is(err, fberrors.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}

	target := d.shareLocation(d.user, path)
	owners := make(map[uint]*users.User)
	for _, link := range links {
		owner, ownerErr := shareOwner(d, owners, link.UserID)
		if ownerErr != nil {
			err = errors.Join(err, ownerErr)
			continue
		}
		if owner == nil || !isPathWithin(d.shareLocation(owner, link.Path), target) {
			continue
		}

		err = errors.Join(err, d.store.Share.Delete(link.Hash))
	}

	return err
}

// shareLocation returns the on-disk location a path names for a given user, in
// a form that can be compared across users. On a case-insensitive filesystem
// names differing only in case are the same file, so they are folded.
func (d *data) shareLocation(u *users.User, path string) string {
	location := filepath.Clean(u.FullPath(path))
	if d.server.CaseInsensitiveFs {
		location = strings.ToLower(location)
	}
	return location
}

// isPathWithin reports whether location is dir itself or lies below it.
func isPathWithin(location, dir string) bool {
	if location == dir {
		return true
	}
	if !strings.HasSuffix(dir, string(filepath.Separator)) {
		dir += string(filepath.Separator)
	}
	return strings.HasPrefix(location, dir)
}

var shareDeleteHandler = withPermShare(func(_ http.ResponseWriter, r *http.Request, d *data) (int, error) {
	hash := strings.TrimSuffix(r.URL.Path, "/")
	hash = strings.TrimPrefix(hash, "/")

	if hash == "" {
		return http.StatusBadRequest, nil
	}

	link, err := d.store.Share.GetByHash(hash)
	if err != nil {
		return errToStatus(err), err
	}

	if link.UserID != d.user.ID && !d.user.Perm.Admin {
		return http.StatusForbidden, nil
	}

	err = d.store.Share.Delete(hash)
	return errToStatus(err), err
})

// shareExpiry returns the Unix time at which a share created at now with the
// lifetime asked for in body expires, or 0 for one that never does.
//
// The lifetime must be a whole number that is not negative and fits a
// time.Duration in its unit. A negative one, or one so long that the
// nanosecond count wraps around, would otherwise yield a time in the past:
// the share would be reported as created and be dead on first use.
func shareExpiry(body share.CreateBody, now time.Time) (int64, error) {
	if body.Expires == "" {
		return 0, nil
	}

	num, err := strconv.ParseInt(body.Expires, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid share lifetime %q", body.Expires)
	}

	var unit time.Duration
	switch body.Unit {
	case "seconds":
		unit = time.Second
	case "minutes":
		unit = time.Minute
	case "days":
		unit = time.Hour * 24
	default:
		unit = time.Hour
	}

	if num < 0 || num > math.MaxInt64/int64(unit) {
		return 0, fmt.Errorf("share lifetime %q is out of range", body.Expires)
	}

	return now.Add(unit * time.Duration(num)).Unix(), nil
}

var sharePostHandler = withPermShare(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
	// Only allow sharing paths that currently exist. Otherwise a share could be
	// created for a non-existent path and would silently start exposing
	// whatever file later appears there.
	//
	// d.user.Fs is scoped, so Stat also refuses to follow a symlink whose target
	// escapes the user's scope: that returns a permission error here and so
	// blocks creating a share that points out of scope.
	if _, err := d.user.Fs.Stat(r.URL.Path); err != nil {
		return errToStatus(err), err
	}

	var s *share.Link
	var body share.CreateBody
	if r.Body != nil {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			return http.StatusBadRequest, fmt.Errorf("failed to decode body: %w", err)
		}
		defer r.Body.Close()
	}

	bytes := make([]byte, 6)
	_, err := rand.Read(bytes)
	if err != nil {
		return http.StatusInternalServerError, err
	}

	str := base64.URLEncoding.EncodeToString(bytes)

	expire, err := shareExpiry(body, time.Now())
	if err != nil {
		return http.StatusBadRequest, err
	}

	hash, status, err := getSharePasswordHash(body)
	if err != nil {
		return status, err
	}

	var token string
	if len(hash) > 0 {
		tokenBuffer := make([]byte, 96)
		if _, err := rand.Read(tokenBuffer); err != nil {
			return http.StatusInternalServerError, err
		}
		token = base64.URLEncoding.EncodeToString(tokenBuffer)
	}

	s = &share.Link{
		Path:         r.URL.Path,
		Hash:         str,
		Expire:       expire,
		UserID:       d.user.ID,
		PasswordHash: string(hash),
		Token:        token,
	}

	if err := d.store.Share.Save(s); err != nil {
		return http.StatusInternalServerError, err
	}

	return renderJSON(w, r, toShareResponse(s))
})

func getSharePasswordHash(body share.CreateBody) (data []byte, statuscode int, err error) {
	if body.Password == "" {
		return nil, 0, nil
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, http.StatusInternalServerError, fmt.Errorf("failed to hash password: %w", err)
	}

	return hash, 0, nil
}
