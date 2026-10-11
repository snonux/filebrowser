package resourceops

import (
	"errors"
	"path/filepath"
	"strings"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/share"
)

// ShareStore is the subset of share storage needed when a path stops naming
// its original object.
type ShareStore interface {
	All() ([]*share.Link, error)
	Delete(string) error
	DeleteWithPathPrefix(string, uint) error
}

// DeleteSharesUnder removes links whose owner's resolved location is within
// target. An empty owner location denotes a deleted user. Without a disk-backed
// scope, links are matched against the acting user's virtual path instead.
func DeleteSharesUnder(store ShareStore, src string, userID uint, target string, ownerLocation func(uint, string) (string, error)) error {
	if ownerLocation == nil {
		return store.DeleteWithPathPrefix(src, userID)
	}
	links, err := store.All()
	if errors.Is(err, fberrors.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, link := range links {
		location, ownerErr := ownerLocation(link.UserID, link.Path)
		if ownerErr != nil {
			err = errors.Join(err, ownerErr)
			continue
		}
		if location == "" || !IsPathWithin(location, target) {
			continue
		}
		err = errors.Join(err, store.Delete(link.Hash))
	}
	return err
}

// IsPathWithin compares canonical filesystem locations with a separator boundary.
func IsPathWithin(location, dir string) bool {
	if location == dir {
		return true
	}
	if !strings.HasSuffix(dir, string(filepath.Separator)) {
		dir += string(filepath.Separator)
	}
	return strings.HasPrefix(location, dir)
}
