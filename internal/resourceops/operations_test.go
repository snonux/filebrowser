package resourceops

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/share"
	"github.com/spf13/afero"
)

type testChecker struct{ denied string }

func (c *testChecker) Check(src string) bool { return c.CheckRules(src) }
func (c *testChecker) CheckRules(src string) bool {
	return c.denied == "" || !strings.HasSuffix(src, c.denied)
}

func fixture(t *testing.T) Operations {
	t.Helper()
	fs := afero.NewMemMapFs()
	if err := fs.MkdirAll("/src", 0755); err != nil {
		t.Fatal(err)
	}
	if err := afero.WriteFile(fs, "/src/secret", []byte("source"), 0644); err != nil {
		t.Fatal(err)
	}
	return Operations{Fs: fs, Checker: &testChecker{}, DeleteAllowed: true, RenameAllowed: true, Modify: true, FileMode: 0644, DirMode: 0755}
}

func TestDeniedDescendants(t *testing.T) {
	for _, operation := range []string{"delete", "rename source", "rename destination"} {
		t.Run(operation, func(t *testing.T) {
			o := fixture(t)
			denied := "/src/secret"
			if operation == "rename destination" {
				denied = "/dst/secret"
			}
			o.Checker = &testChecker{denied: denied}
			o.CleanupShares = func(string) error { t.Fatal("denied operation cleaned shares"); return nil }
			o.Invalidate = func(context.Context, *files.FileInfo) error {
				t.Fatal("denied operation invalidated cache")
				return nil
			}
			var err error
			if operation == "delete" {
				err = o.Delete(context.Background(), "/src")
			} else {
				err = o.Rename(context.Background(), "/src", "/dst", false)
			}
			if !errors.Is(err, fberrors.ErrPermissionDenied) {
				t.Fatalf("error = %v", err)
			}
			if _, err := o.Fs.Stat("/src/secret"); err != nil {
				t.Fatal(err)
			}
			if _, err := o.Fs.Stat("/dst"); !os.IsNotExist(err) {
				t.Fatalf("destination stat = %v", err)
			}
		})
	}
}

func TestMutationRechecksAfterHook(t *testing.T) {
	for _, action := range []string{"delete", "rename"} {
		t.Run(action, func(t *testing.T) {
			o := fixture(t)
			checker := o.Checker.(*testChecker)
			o.Run = func(fn func() error, _, _, _ string) error { checker.denied = "/src/secret"; return fn() }
			var err error
			if action == "delete" {
				err = o.Delete(context.Background(), "/src")
			} else {
				err = o.Rename(context.Background(), "/src", "/dst", false)
			}
			if !errors.Is(err, fberrors.ErrPermissionDenied) {
				t.Fatalf("error = %v", err)
			}
			if _, err := o.Fs.Stat("/src/secret"); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestCallbacksOutsideMutationLock(t *testing.T) {
	for _, action := range []string{"delete", "rename"} {
		t.Run(action, func(t *testing.T) {
			o := fixture(t)
			locked, cleaned, invalidated, retired := false, false, false, false
			o.Lock = func() func() { locked = true; return func() { locked = false } }
			o.Run = func(fn func() error, _, _, _ string) error {
				if locked {
					t.Fatal("hook under mutation lock")
				}
				err := fn()
				if locked {
					t.Fatal("post hook under mutation lock")
				}
				return err
			}
			o.Invalidate = func(context.Context, *files.FileInfo) error {
				if locked {
					t.Fatal("cache under lock")
				}
				invalidated = true
				return nil
			}
			o.CleanupShares = func(src string) error {
				if locked {
					t.Fatal("share cleanup under lock")
				}
				if src != "/src/" && src != "/src" {
					t.Fatalf("cleanup path = %s", src)
				}
				cleaned = true
				return nil
			}
			o.RetireTree = func(string) {
				if !locked {
					t.Fatal("retirement outside lock")
				}
				retired = true
			}
			var err error
			if action == "delete" {
				err = o.Delete(context.Background(), "/src")
			} else {
				err = o.Rename(context.Background(), "/src", "/dst", false)
			}
			if err != nil {
				t.Fatal(err)
			}
			if !cleaned || !invalidated || !retired {
				t.Fatalf("cleanup=%v invalidate=%v retirement=%v", cleaned, invalidated, retired)
			}
			if _, err := o.Fs.Stat("/src"); !os.IsNotExist(err) {
				t.Fatalf("source stat = %v", err)
			}
		})
	}
}

func TestRenameFailuresPreserveSourceAndShares(t *testing.T) {
	for _, failure := range []string{"permission", "conflict", "cache", "filesystem", "parent", "root"} {
		t.Run(failure, func(t *testing.T) {
			o := fixture(t)
			dst := "/dst"
			expected := fberrors.ErrPermissionDenied
			switch failure {
			case "permission":
				o.RenameAllowed = false
			case "conflict":
				if err := afero.WriteFile(o.Fs, dst, []byte("destination"), 0644); err != nil {
					t.Fatal(err)
				}
				expected = fberrors.ErrExist
			case "cache":
				expected = errors.New("cache unavailable")
				o.Invalidate = func(context.Context, *files.FileInfo) error { return expected }
			case "filesystem":
				o.Fs = afero.NewReadOnlyFs(o.Fs)
				expected = os.ErrPermission
			case "parent":
				dst = "/src/child"
				expected = fberrors.ErrSourceIsParent
			case "root":
				dst = "/"
			}
			o.CleanupShares = func(string) error { t.Fatal("failed rename cleaned shares"); return nil }
			if err := o.Rename(context.Background(), "/src", dst, false); !errors.Is(err, expected) {
				t.Fatalf("error = %v, want %v", err, expected)
			}
			if content, err := afero.ReadFile(o.Fs, "/src/secret"); err != nil || string(content) != "source" {
				t.Fatalf("source = %q, %v", content, err)
			}
		})
	}
}

func TestRenameCleansSharesAfterPostHookFailure(t *testing.T) {
	o := fixture(t)
	failure := errors.New("post hook failed")
	cleaned := false
	o.Run = func(fn func() error, _, _, _ string) error {
		if err := fn(); err != nil {
			return err
		}
		return failure
	}
	o.CleanupShares = func(string) error { cleaned = true; return nil }
	if err := o.Rename(context.Background(), "/src", "/dst", false); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if !cleaned {
		t.Fatal("successful move left old shares")
	}
}

type testShares struct {
	links        []*share.Link
	deleted      []string
	fallbackPath string
	fallbackID   uint
	failure      error
}

func (s *testShares) All() ([]*share.Link, error) { return s.links, nil }
func (s *testShares) Delete(hash string) error {
	s.deleted = append(s.deleted, hash)
	if hash == "failed" {
		return s.failure
	}
	return nil
}
func (s *testShares) DeleteWithPathPrefix(src string, id uint) error {
	s.fallbackPath, s.fallbackID = src, id
	return s.failure
}

func TestDeleteSharesMatchesOwnersScopes(t *testing.T) {
	store := &testShares{links: []*share.Link{
		{Hash: "same", UserID: 1, Path: "/file"}, {Hash: "child", UserID: 2, Path: "/dir/file"},
		{Hash: "collision", UserID: 3, Path: "/file"}, {Hash: "prefix", UserID: 4, Path: "/file"}, {Hash: "missing", UserID: 5, Path: "/file"},
	}}
	locations := map[uint]string{1: "/disk/target", 2: "/disk/target/file", 3: "/other/target", 4: "/disk/target-other"}
	err := DeleteSharesUnder(store, "/target", 1, "/disk/target", func(id uint, _ string) (string, error) { return locations[id], nil })
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(store.deleted, ",") != "same,child" {
		t.Fatalf("deleted = %v", store.deleted)
	}
}

func TestDeleteSharesContinuesAfterErrors(t *testing.T) {
	failure := errors.New("storage failed")
	ownerFailure := errors.New("owner failed")
	store := &testShares{links: []*share.Link{{Hash: "failed", UserID: 1}, {Hash: "bad owner", UserID: 2}, {Hash: "last", UserID: 3}}, failure: failure}
	err := DeleteSharesUnder(store, "/target", 1, "/disk/target", func(id uint, _ string) (string, error) {
		if id == 2 {
			return "", ownerFailure
		}
		return "/disk/target", nil
	})
	if !errors.Is(err, failure) || !errors.Is(err, ownerFailure) {
		t.Fatalf("error = %v", err)
	}
	if strings.Join(store.deleted, ",") != "failed,last" {
		t.Fatalf("deleted = %v", store.deleted)
	}
}

func TestDeleteSharesVirtualFallback(t *testing.T) {
	store := &testShares{}
	if err := DeleteSharesUnder(store, "/target", 42, "", nil); err != nil {
		t.Fatal(err)
	}
	if store.fallbackPath != "/target" || store.fallbackID != 42 {
		t.Fatalf("fallback = %q, %d", store.fallbackPath, store.fallbackID)
	}
}

func TestRenameCleansOldSharesBeforeAfterHook(t *testing.T) {
	o := fixture(t)
	store := &testShares{links: []*share.Link{{Hash: "old", UserID: 1, Path: "/src/secret"}}}
	o.CleanupShares = func(src string) error {
		return DeleteSharesUnder(store, src, 1, "/disk"+src, func(_ uint, src string) (string, error) { return "/disk" + src, nil })
	}
	o.Run = func(fn func() error, _, _, _ string) error {
		if err := fn(); err != nil {
			return err
		}
		if strings.Join(store.deleted, ",") != "old" {
			t.Fatalf("old share survived into after hook: %v", store.deleted)
		}
		if err := o.Fs.MkdirAll("/src", 0755); err != nil {
			return err
		}
		if err := afero.WriteFile(o.Fs, "/src/secret", []byte("new"), 0644); err != nil {
			return err
		}
		store.links = append(store.links, &share.Link{Hash: "new", UserID: 1, Path: "/src/secret"})
		return nil
	}
	if err := o.Rename(context.Background(), "/src", "/dst", false); err != nil {
		t.Fatal(err)
	}
	if strings.Join(store.deleted, ",") != "old" {
		t.Fatalf("after hook's new share deleted: %v", store.deleted)
	}
}

func TestDeleteFailureAndWarning(t *testing.T) {
	for _, scenario := range []string{"permission", "root", "cache", "share warning"} {
		t.Run(scenario, func(t *testing.T) {
			o := fixture(t)
			src := "/src"
			failure := errors.New("dependency failed")
			expected := error(nil)
			warned := false
			switch scenario {
			case "permission":
				o.DeleteAllowed = false
				expected = fberrors.ErrPermissionDenied
			case "root":
				src = "/"
				expected = fberrors.ErrPermissionDenied
			case "cache":
				o.Invalidate = func(context.Context, *files.FileInfo) error { return failure }
				expected = failure
			case "share warning":
				o.CleanupShares = func(string) error { return failure }
				o.Warn = func(err error) { warned = errors.Is(err, failure) }
			}
			err := o.Delete(context.Background(), src)
			if !errors.Is(err, expected) {
				t.Fatalf("error = %v, want %v", err, expected)
			}
			_, statErr := o.Fs.Stat("/src/secret")
			if expected != nil && statErr != nil {
				t.Fatalf("failed delete removed source: %v", statErr)
			}
			if scenario == "share warning" && (!warned || !os.IsNotExist(statErr)) {
				t.Fatalf("warning=%v, stat=%v", warned, statErr)
			}
		})
	}
}

func TestRenameOverrideRequiresModify(t *testing.T) {
	o := fixture(t)
	o.Modify = false
	if err := o.Rename(context.Background(), "/src", "/dst", true); !errors.Is(err, fberrors.ErrPermissionDenied) {
		t.Fatalf("error = %v", err)
	}
	if _, err := o.Fs.Stat("/src/secret"); err != nil {
		t.Fatal(err)
	}
}

type unreadableDirectoryFs struct {
	afero.Fs
	failure error
}
type unreadableDirectory struct {
	afero.File
	failure error
}

func (fs unreadableDirectoryFs) Open(src string) (afero.File, error) {
	file, err := fs.Fs.Open(src)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	if info.IsDir() {
		return unreadableDirectory{File: file, failure: fs.failure}, nil
	}
	return file, nil
}
func (file unreadableDirectory) Readdir(int) ([]os.FileInfo, error) { return nil, file.failure }

func TestDescendantWalkOnlySkippedWithoutRules(t *testing.T) {
	for _, action := range []string{"delete", "rename"} {
		for _, rulesConfigured := range []bool{false, true} {
			t.Run(action+" rules="+map[bool]string{false: "absent", true: "configured"}[rulesConfigured], func(t *testing.T) {
				o := fixture(t)
				failure := errors.New("descendants unreadable")
				o.Fs = unreadableDirectoryFs{Fs: o.Fs, failure: failure}
				o.SkipDescendantChecks = !rulesConfigured
				var err error
				if action == "delete" {
					err = o.Delete(context.Background(), "/src")
				} else {
					err = o.Rename(context.Background(), "/src", "/dst", false)
				}
				if rulesConfigured {
					if !errors.Is(err, failure) {
						t.Fatalf("error = %v", err)
					}
					if _, err := o.Fs.Stat("/src/secret"); err != nil {
						t.Fatal(err)
					}
				} else {
					if err != nil {
						t.Fatal(err)
					}
					if _, err := o.Fs.Stat("/src"); !os.IsNotExist(err) {
						t.Fatalf("source stat = %v", err)
					}
				}
			})
		}
	}
}

func (file unreadableDirectory) Readdirnames(int) ([]string, error) { return nil, file.failure }
