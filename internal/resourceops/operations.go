// Package resourceops implements scoped delete and rename operations independently
// of HTTP request decoding and response handling.
package resourceops

import (
	"context"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	fberrors "github.com/filebrowser/filebrowser/v2/errors"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/fileutils"
	"github.com/spf13/afero"
)

// Checker separates authorization of operation roots from descendant rules.
// Descendants ignore display preferences such as hidden dotfiles.
type Checker interface {
	Check(string) bool
	CheckRules(string) bool
}

// Operations holds the focused dependencies needed to mutate a scoped tree.
// Run invokes hooks around the supplied mutation; Lock protects only the actual
// filesystem mutation. Hooks and cache/share callbacks run outside that lock.
// Nil callbacks are optional when no corresponding integration is needed.
type Operations struct {
	Fs                                               afero.Fs
	Checker                                          Checker
	DeleteAllowed, RenameAllowed, Modify, ReadHeader bool
	// SkipDescendantChecks is safe only when no descendant rules are configured.
	SkipDescendantChecks  bool
	FileMode, DirMode     fs.FileMode
	Invalidate            func(context.Context, *files.FileInfo) error
	CleanupShares         func(string) error
	Warn                  func(error)
	Run                   func(func() error, string, string, string) error
	Lock                  func() func()
	LockContext           func(context.Context) (func(), error)
	RetireTree            func(string)
	RetireDestination     func(string)
	RetireCopyDestination func(string, string) error
}

// Delete removes a tree after checking every descendant. Share cleanup failures
// are warnings, matching rename's successful-mutation behavior.
func (o Operations) Delete(ctx context.Context, src string) error {
	if path.Clean("/"+src) == "/" || !o.DeleteAllowed {
		return fberrors.ErrPermissionDenied
	}
	file, err := o.file(src, o.ReadHeader)
	if err != nil {
		return err
	}
	if err := o.CheckDescendants(src, ""); err != nil {
		return err
	}
	o.cleanup(file.Path)
	if err := o.invalidate(ctx, file); err != nil {
		return err
	}
	return o.run(func() error {
		unlock, err := o.lock(ctx)
		if err != nil {
			return err
		}
		defer unlock()
		if !o.Checker.Check(src) {
			return fberrors.ErrPermissionDenied
		}
		if err := o.CheckDescendants(src, ""); err != nil {
			return err
		}
		o.retire(src)
		return o.Fs.RemoveAll(src)
	}, "delete", src, "")
}

// Rename moves src to dst, optionally replacing an existing destination. Both
// names are scoped paths; request decoding and keep-both naming belong to callers.
func (o Operations) Rename(ctx context.Context, src, dst string, override bool) error {
	src, dst = path.Clean("/"+src), path.Clean("/"+dst)
	if src == "/" || dst == "/" || !o.RenameAllowed || !o.Checker.Check(src) || !o.Checker.Check(dst) {
		return fberrors.ErrPermissionDenied
	}
	if err := CheckParent(src, dst); err != nil {
		return err
	}
	if err := o.CheckDescendants(src, dst); err != nil {
		return err
	}
	return o.run(func() error {
		file, err := o.file(src, false)
		if err != nil {
			return err
		}
		if err := o.invalidate(ctx, file); err != nil {
			return err
		}
		if err := o.move(ctx, src, dst, override); err != nil {
			return err
		}
		o.cleanup(src)
		return nil
	}, "rename", src, dst)
}

// CheckDescendants rejects a tree if any source or projected destination path
// fails the rules, including paths reached through the scoped filesystem.
func (o Operations) CheckDescendants(src, dst string) error {
	if o.SkipDescendantChecks {
		return nil
	}
	return afero.Walk(o.Fs, src, func(candidate string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !o.Checker.CheckRules(candidate) {
			return fberrors.ErrPermissionDenied
		}
		if dst == "" {
			return nil
		}
		relative, err := filepath.Rel(src, candidate)
		if err != nil {
			return err
		}
		if !o.Checker.CheckRules(filepath.Join(dst, relative)) {
			return fberrors.ErrPermissionDenied
		}
		return nil
	})
}

// CheckParent prevents moving or copying a directory into its own descendant.
func CheckParent(src, dst string) error {
	relative, err := filepath.Rel(src, dst)
	if err != nil {
		return err
	}
	relative = filepath.ToSlash(relative)
	if !strings.HasPrefix(relative, "../") && relative != ".." && relative != "." {
		return fberrors.ErrSourceIsParent
	}
	return nil
}

func (o Operations) move(ctx context.Context, src, dst string, override bool) error {
	unlock, err := o.lock(ctx)
	if err != nil {
		return err
	}
	defer unlock()
	if !o.Checker.Check(src) || !o.Checker.Check(dst) {
		return fberrors.ErrPermissionDenied
	}
	if err := o.CheckDescendants(src, dst); err != nil {
		return err
	}
	srcInfo, err := o.Fs.Stat(src)
	if err != nil {
		return err
	}
	dstInfo, dstErr := o.Fs.Stat(dst)
	same := os.SameFile(srcInfo, dstInfo)
	if override && !o.Modify && !same {
		return fberrors.ErrPermissionDenied
	}
	if dstErr == nil && !same {
		if !override {
			return fberrors.ErrExist
		}
	}
	o.retire(src)
	copied := false
	err = fileutils.MoveFileWithFallback(o.Fs, src, dst, o.FileMode, o.DirMode, func() error {
		copied = true
		if o.RetireCopyDestination != nil {
			return o.RetireCopyDestination(src, dst)
		}
		return nil
	})
	if err == nil && !copied && o.RetireDestination != nil {
		o.RetireDestination(dst)
	}
	return err
}

func (o Operations) file(src string, readHeader bool) (*files.FileInfo, error) {
	return files.NewFileInfo(&files.FileOptions{Fs: o.Fs, Path: src, Modify: o.Modify, ReadHeader: readHeader, Checker: o.Checker})
}

func (o Operations) invalidate(ctx context.Context, file *files.FileInfo) error {
	if o.Invalidate != nil {
		return o.Invalidate(ctx, file)
	}
	return nil
}

func (o Operations) cleanup(src string) {
	if o.CleanupShares != nil {
		if err := o.CleanupShares(src); err != nil && o.Warn != nil {
			o.Warn(err)
		}
	}
}

func (o Operations) run(fn func() error, action, src, dst string) error {
	if o.Run != nil {
		return o.Run(fn, action, src, dst)
	}
	return fn()
}

func (o Operations) lock(ctx context.Context) (func(), error) {
	if o.LockContext != nil {
		return o.LockContext(ctx)
	}
	if o.Lock != nil {
		return o.Lock(), nil
	}
	return func() {}, nil
}

func (o Operations) retire(src string) {
	if o.RetireTree != nil {
		o.RetireTree(src)
	}
}
