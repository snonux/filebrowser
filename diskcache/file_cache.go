package diskcache

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/spf13/afero"
)

type FileCache struct {
	fs afero.Fs

	// Fixed stripes bound synchronization memory regardless of historical keys.
	// Hash collisions serialize unrelated mutations; reads remain lock-free.
	scopedLocks [256]sync.Mutex
}

func New(fs afero.Fs, root string) *FileCache {
	return &FileCache{
		fs: afero.NewBasePathFs(fs, root),
	}
}

func (f *FileCache) Store(_ context.Context, key string, value []byte) error {
	mu := f.getScopedLock(key)
	mu.Lock()
	defer mu.Unlock()

	fileName := f.getFileName(key)
	if err := f.fs.MkdirAll(filepath.Dir(fileName), 0700); err != nil {
		return err
	}

	// Publish only a complete, closed file. Readers can keep using the previous
	// entry while this same-directory temporary file is being written.
	tmp, err := afero.TempFile(f.fs, filepath.Dir(fileName), ".cache-*")
	if err != nil {
		return err
	}
	// Some filesystems change the open file's name when it is renamed.
	tmpName := tmp.Name()
	closed := false
	defer func() {
		if !closed {
			_ = tmp.Close()
		}
		_ = f.fs.Remove(tmpName)
	}()

	n, err := tmp.Write(value)
	if err != nil {
		return err
	}
	if n != len(value) {
		return io.ErrShortWrite
	}
	err = tmp.Close()
	closed = true
	if err != nil {
		return err
	}
	return f.fs.Rename(tmpName, fileName)
}

func (f *FileCache) Load(_ context.Context, key string) (value []byte, exist bool, err error) {
	r, ok, err := f.open(key)
	if err != nil || !ok {
		return nil, ok, err
	}
	defer func() { _ = r.Close() }()

	value, err = io.ReadAll(r)
	if err != nil {
		return nil, false, err
	}
	return value, true, nil
}

func (f *FileCache) Delete(_ context.Context, key string) error {
	mu := f.getScopedLock(key)
	mu.Lock()
	defer mu.Unlock()

	fileName := f.getFileName(key)
	if err := f.fs.Remove(fileName); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (f *FileCache) open(key string) (afero.File, bool, error) {
	fileName := f.getFileName(key)
	file, err := f.fs.Open(fileName)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, err
	}

	return file, true, nil
}

func (f *FileCache) getScopedLock(key string) *sync.Mutex {
	hash := sha1.Sum([]byte(key))
	return &f.scopedLocks[hash[0]]
}

func (f *FileCache) getFileName(key string) string {
	hasher := sha1.New()
	_, _ = hasher.Write([]byte(key))
	hash := hex.EncodeToString(hasher.Sum(nil))
	return fmt.Sprintf("%s/%s/%s", hash[:1], hash[1:3], hash)
}
