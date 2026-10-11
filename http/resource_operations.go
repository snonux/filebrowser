package fbhttp

import (
	"context"
	"log"

	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/internal/resourceops"
)

func resourceOperations(d *data, cache FileCache) resourceops.Operations {
	return resourceops.Operations{
		Fs: d.user.Fs, Checker: d,
		DeleteAllowed: d.user.Perm.Delete, RenameAllowed: d.user.Perm.Rename,
		Modify: d.user.Perm.Modify, ReadHeader: d.server.TypeDetectionByHeader,
		SkipDescendantChecks: len(d.settings.Rules) == 0 && len(d.user.Rules) == 0,
		FileMode:             d.settings.FileMode, DirMode: d.settings.DirMode,
		Invalidate:    func(ctx context.Context, file *files.FileInfo) error { return delThumbs(ctx, cache, file) },
		CleanupShares: func(src string) error { return deleteSharesUnder(d, src) },
		Warn: func(err error) {
			log.Printf("WARNING: Error(s) occurred while deleting associated shares with file: %s", err)
		},
		Run:                   func(fn func() error, action, src, dst string) error { return d.RunHook(fn, action, src, dst, d.user) },
		Lock:                  func() func() { uploadMutations.barrier.Lock(); return uploadMutations.barrier.Unlock },
		RetireTree:            func(src string) { retireUploadsUnder(uploadLockKey(d, src)) },
		RetireDestination:     func(dst string) { retireUploadsUnder(uploadPathKey(d, dst)) },
		RetireCopyDestination: func(src, dst string) error { return retireCopyDestination(d, src, dst) },
	}
}
