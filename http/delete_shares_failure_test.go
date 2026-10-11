package fbhttp

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/filebrowser/filebrowser/v2/diskcache"
)

type failingDeleteCache struct{ FileCache }

func (failingDeleteCache) Delete(context.Context, string) error {
	return errors.New("cache unavailable")
}

func TestFailedDeleteKeepsStoredPublicShare(t *testing.T) {
	f := newShareCleanupFixture(t)
	f.write(t, "x.txt")
	f.share(t, "original", f.owner, "/x.txt")
	if status := f.do(t, resourceDeleteHandler(failingDeleteCache{diskcache.NewNoOp()}), f.admin, http.MethodDelete, "/x.txt"); status != http.StatusInternalServerError {
		t.Fatalf("failed DELETE = %d", status)
	}
	if !f.exists("original") {
		t.Fatal("failed DELETE removed stored public share")
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "x.txt")); err != nil || string(got) != "x" {
		t.Fatalf("source = %q, %v", got, err)
	}
	if status := f.do(t, resourceDeleteHandler(diskcache.NewNoOp()), f.admin, http.MethodDelete, "/x.txt"); status != http.StatusNoContent {
		t.Fatalf("retry DELETE = %d", status)
	}
	if f.exists("original") {
		t.Fatal("successful retry retained public share")
	}
	if _, err := os.Stat(filepath.Join(f.root, "x.txt")); !os.IsNotExist(err) {
		t.Fatalf("successful retry source stat = %v", err)
	}
}
