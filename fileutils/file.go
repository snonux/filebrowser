package fileutils

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"

	"github.com/spf13/afero"
)

// ErrSameFile means the source and destination identify the same file.
var ErrSameFile = errors.New("source and destination are the same file")

// MoveFile moves file from src to dst.
// By default the rename filesystem system call is used. If src and dst point to different volumes
// the file copy is used as a fallback
func MoveFile(afs afero.Fs, src, dst string, fileMode, dirMode fs.FileMode) error {
	return MoveFileWithFallback(afs, src, dst, fileMode, dirMode, nil)
}

// MoveFileWithFallback moves a file like MoveFile, calling beforeCopy only when
// a failed rename will fall back to copying. A callback error aborts the move
// without copying or removing either path.
func MoveFileWithFallback(afs afero.Fs, src, dst string, fileMode, dirMode fs.FileMode, beforeCopy func() error) error {
	if afs.Rename(src, dst) == nil {
		return nil
	}
	// A failed rename must not fall back to copying or cleaning up an alias
	// of the source. Successful renames still support case-only name changes.
	srcInfo, err := afs.Stat(src)
	if err != nil {
		return err
	}
	dstInfo, err := afs.Stat(dst)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if filepath.Clean(src) == filepath.Clean(dst) || os.SameFile(srcInfo, dstInfo) {
		return ErrSameFile
	}
	// fallback
	if beforeCopy != nil {
		if err := beforeCopy(); err != nil {
			return err
		}
	}
	err = Copy(afs, src, dst, fileMode, dirMode)
	if err != nil {
		if !errors.Is(err, ErrSameFile) {
			_ = afs.Remove(dst)
		}
		return err
	}
	if err := afs.RemoveAll(src); err != nil {
		return err
	}
	return nil
}

// CopyFile copies a file from source to dest and returns
// an error if any.
func CopyFile(afs afero.Fs, source, dest string, fileMode, dirMode fs.FileMode) error {
	if filepath.Clean(source) == filepath.Clean(dest) {
		return ErrSameFile
	}
	// Open the source file.
	src, err := afs.Open(source)
	if err != nil {
		return err
	}
	defer func() { _ = src.Close() }()
	info, err := src.Stat()
	if err != nil {
		return err
	}

	// Makes the directory needed to create the dst
	// file.
	err = afs.MkdirAll(filepath.Dir(dest), dirMode)
	if err != nil {
		return err
	}

	// Open without truncation so identity is checked on the actual handles,
	// even if the destination changes between a path stat and this open.
	dst, err := afs.OpenFile(dest, os.O_RDWR|os.O_CREATE, fileMode)
	if err != nil {
		return err
	}
	defer func() { _ = dst.Close() }()
	dstInfo, err := dst.Stat()
	if err != nil {
		return err
	}
	if os.SameFile(info, dstInfo) {
		return ErrSameFile
	}
	if err := dst.Truncate(0); err != nil {
		return err
	}

	// Copy the contents of the file.
	_, err = io.Copy(dst, src)
	if err != nil {
		return err
	}

	// Copy the mode
	err = afs.Chmod(dest, info.Mode())
	if err != nil {
		return err
	}

	return nil
}

// CommonPrefix returns common directory path of provided files
func CommonPrefix(sep byte, paths ...string) string {
	// Handle special cases.
	switch len(paths) {
	case 0:
		return ""
	case 1:
		return path.Clean(paths[0])
	}

	// Note, we treat string as []byte, not []rune as is often
	// done in Go. (And sep as byte, not rune). This is because
	// most/all supported OS' treat paths as string of non-zero
	// bytes. A filename may be displayed as a sequence of Unicode
	// runes (typically encoded as UTF-8) but paths are
	// not required to be valid UTF-8 or in any normalized form
	// (e.g. "é" (U+00C9) and "é" (U+0065,U+0301) are different
	// file names.
	c := []byte(path.Clean(paths[0]))

	// We add a trailing sep to handle the case where the
	// common prefix directory is included in the path list
	// (e.g. /home/user1, /home/user1/foo, /home/user1/bar).
	// path.Clean will have cleaned off trailing / separators with
	// the exception of the root directory, "/" (in which case we
	// make it "//", but this will get fixed up to "/" below).
	c = append(c, sep)

	// Ignore the first path since it's already in c
	for _, v := range paths[1:] {
		// Clean up each path before testing it
		v = path.Clean(v) + string(sep)

		// Find the first non-common byte and truncate c
		if len(v) < len(c) {
			c = c[:len(v)]
		}
		for i := 0; i < len(c); i++ {
			if v[i] != c[i] {
				c = c[:i]
				break
			}
		}
	}

	// Remove trailing non-separator characters and the final separator
	for i := len(c) - 1; i >= 0; i-- {
		if c[i] == sep {
			c = c[:i]
			break
		}
	}

	return string(c)
}
