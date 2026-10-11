package resourceops

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/share"
	"github.com/spf13/afero"
)

func TestFailedDeletePreservesShares(t *testing.T) {
	for _, scenario := range []string{"cache", "before hook", "recheck", "filesystem", "canceled lock"} {
		t.Run(scenario, func(t *testing.T) {
			o := fixture(t)
			failure := errors.New("dependency failed")
			want := failure
			cleaned := false
			o.CleanupShares = func(string) error { cleaned = true; return nil }
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var entered chan struct{}
			switch scenario {
			case "cache":
				o.Invalidate = func(context.Context, *files.FileInfo) error { return failure }
			case "before hook":
				o.Run = func(func() error, string, string, string) error { return failure }
			case "recheck":
				want = fberrors.ErrPermissionDenied
				o.Run = func(fn func() error, _, _, _ string) error {
					o.Checker.(*testChecker).denied = "/src/secret"
					return fn()
				}
			case "filesystem":
				want = os.ErrPermission
				o.Fs = afero.NewReadOnlyFs(o.Fs)
			case "canceled lock":
				want = context.Canceled
				entered = make(chan struct{})
				o.LockContext = func(ctx context.Context) (func(), error) {
					close(entered)
					<-ctx.Done()
					return nil, ctx.Err()
				}
			}
			done := make(chan error, 1)
			go func() { done <- o.Delete(ctx, "/src") }()
			if entered != nil {
				select {
				case <-entered:
				case <-time.After(time.Second):
					t.Fatal("delete never reached held mutation lock")
				}
				cancel()
			}
			select {
			case err := <-done:
				if !errors.Is(err, want) {
					t.Fatalf("Delete = %v, want %v", err, want)
				}
			case <-time.After(time.Second):
				t.Fatal("delete did not return")
			}
			if cleaned {
				t.Fatal("failed delete removed public shares")
			}
			if got, err := afero.ReadFile(o.Fs, "/src/secret"); err != nil || string(got) != "source" {
				t.Fatalf("source = %q, %v", got, err)
			}
		})
	}
}

func TestDeleteCleansSharesBeforeAfterHook(t *testing.T) {
	o := fixture(t)
	store := &testShares{links: []*share.Link{{Hash: "old", UserID: 1, Path: "/src/secret"}}}
	locked := false
	o.Lock = func() func() { locked = true; return func() { locked = false } }
	o.CleanupShares = func(src string) error {
		if locked {
			t.Fatal("share cleanup held mutation lock")
		}
		return DeleteSharesUnder(store, src, 1, "/disk/src", func(_ uint, path string) (string, error) { return "/disk" + path, nil })
	}
	o.Run = func(fn func() error, _, _, _ string) error {
		if err := fn(); err != nil {
			return err
		}
		if len(store.deleted) != 1 || store.deleted[0] != "old" {
			t.Fatalf("old share survived into after hook: %v", store.deleted)
		}
		if err := o.Fs.MkdirAll("/src", 0o755); err != nil {
			return err
		}
		if err := afero.WriteFile(o.Fs, "/src/secret", []byte("new"), 0o600); err != nil {
			return err
		}
		store.links = append(store.links, &share.Link{Hash: "new", UserID: 1, Path: "/src/secret"})
		return nil
	}
	if err := o.Delete(context.Background(), "/src"); err != nil {
		t.Fatal(err)
	}
	if len(store.deleted) != 1 || store.deleted[0] != "old" {
		t.Fatalf("new share removed after hook: %v", store.deleted)
	}
	if got, err := afero.ReadFile(o.Fs, "/src/secret"); err != nil || string(got) != "new" {
		t.Fatalf("new file = %q, %v", got, err)
	}
}
