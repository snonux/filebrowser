package diskcache

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/spf13/afero"
	"github.com/stretchr/testify/require"
)

// The fault wrappers delegate to actual files, including partial writes, so
// assertions check cache byte integrity and filesystem cleanup, not mock calls.
type cacheTestFaultFS struct {
	afero.Fs
	failure string
	entered chan struct{}
	resume  chan struct{}
	paused  atomic.Bool
}

type cacheTestFaultFile struct {
	afero.File
	fs *cacheTestFaultFS
}

func TestFileCache(t *testing.T) {
	ctx := context.Background()
	const (
		key            = "key"
		value          = "some text"
		newValue       = "new text"
		cacheRoot      = "/cache"
		cachedFilePath = "a/62/a62f2225bf70bfaccbc7f1ef2a397836717377de"
	)

	fs := afero.NewMemMapFs()
	cache := New(fs, "/cache")

	// store new key
	err := cache.Store(ctx, key, []byte(value))
	require.NoError(t, err)
	checkValue(ctx, t, fs, filepath.Join(cacheRoot, cachedFilePath), cache, key, value)

	// update existing key
	err = cache.Store(ctx, key, []byte(newValue))
	require.NoError(t, err)
	checkValue(ctx, t, fs, filepath.Join(cacheRoot, cachedFilePath), cache, key, newValue)

	// delete key
	err = cache.Delete(ctx, key)
	require.NoError(t, err)
	exists, err := afero.Exists(fs, filepath.Join(cacheRoot, cachedFilePath))
	require.NoError(t, err)
	require.False(t, exists)
}

func checkValue(ctx context.Context, t *testing.T, fs afero.Fs, fileFullPath string, cache *FileCache, key, wantValue string) {
	t.Helper()
	// check actual file content
	b, err := afero.ReadFile(fs, fileFullPath)
	require.NoError(t, err)
	require.Equal(t, wantValue, string(b))

	// check cache content
	b, ok, err := cache.Load(ctx, key)
	require.NoError(t, err)
	require.True(t, ok)
	require.Equal(t, wantValue, string(b))
}

// Pausing after real bytes have been written makes the publication race
// deterministic: a Load during the pause must see the entire old value or miss.
func TestFileCacheStorePublishesCompleteValue(t *testing.T) {
	for _, backend := range []string{"memory", "os"} {
		for _, existing := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/existing=%t", backend, existing), func(t *testing.T) {
				fs, root := cacheTestFS(t, backend)
				ctx := context.Background()
				cache := New(fs, root)
				oldValue := []byte("complete previous thumbnail")
				newValue := []byte("complete replacement thumbnail with more bytes")
				if existing {
					require.NoError(t, cache.Store(ctx, "key", oldValue))
				}
				entered, resume := make(chan struct{}), make(chan struct{})
				var release sync.Once
				cache = New(&cacheTestFaultFS{Fs: fs, entered: entered, resume: resume}, root)
				done := make(chan error, 1)
				finished := make(chan struct{})
				go func() {
					defer close(finished)
					done <- cache.Store(ctx, "key", newValue)
				}()
				defer func() {
					release.Do(func() { close(resume) })
					<-finished
				}()
				select {
				case <-entered:
				case err := <-done:
					t.Fatalf("Store finished before write pause: %v", err)
				case <-time.After(5 * time.Second):
					t.Fatal("Store did not reach write pause")
				}
				value, exists, err := cache.Load(ctx, "key")
				require.NoError(t, err)
				require.Equal(t, existing, exists)
				if existing {
					require.Equal(t, oldValue, value)
				} else {
					require.Nil(t, value)
				}
				release.Do(func() { close(resume) })
				require.NoError(t, <-done)
				checkValue(ctx, t, fs, filepath.Join(root, cache.getFileName("key")), cache, "key", string(newValue))
				entries, err := afero.ReadDir(fs, filepath.Join(root, filepath.Dir(cache.getFileName("key"))))
				require.NoError(t, err)
				require.Len(t, entries, 1, "temporary file must be removed")
			})
		}
	}
}

func TestFileCacheFailedStorePreservesEntry(t *testing.T) {
	for _, backend := range []string{"memory", "os"} {
		for _, failure := range []string{"mkdir", "create", "write", "short-write", "close", "rename"} {
			for _, existing := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/existing=%t", backend, failure, existing), func(t *testing.T) {
					fs, root := cacheTestFS(t, backend)
					ctx := context.Background()
					cache := New(fs, root)
					const oldValue = "previous complete entry"
					if existing {
						require.NoError(t, cache.Store(ctx, "key", []byte(oldValue)))
					}
					cache = New(&cacheTestFaultFS{Fs: fs, failure: failure}, root)
					err := cache.Store(ctx, "key", []byte("new complete entry"))
					if failure == "short-write" {
						require.ErrorIs(t, err, io.ErrShortWrite)
					} else {
						require.ErrorIs(t, err, os.ErrPermission)
					}
					value, exists, err := cache.Load(ctx, "key")
					require.NoError(t, err)
					require.Equal(t, existing, exists)
					if existing {
						require.Equal(t, oldValue, string(value))
					} else {
						require.Nil(t, value)
					}
					entries, err := afero.ReadDir(fs, filepath.Join(root, filepath.Dir(cache.getFileName("key"))))
					if !existing && failure == "mkdir" {
						require.ErrorIs(t, err, os.ErrNotExist)
					} else {
						require.NoError(t, err)
						wantEntries := 0
						if existing {
							wantEntries = 1
						}
						require.Len(t, entries, wantEntries, "failed Store must not leave temporary files")
					}
				})
			}
		}
	}
}

func TestFileCacheDeleteAndMissing(t *testing.T) {
	for _, backend := range []string{"memory", "os"} {
		t.Run(backend, func(t *testing.T) {
			fs, root := cacheTestFS(t, backend)
			cache := New(fs, root)
			ctx := context.Background()
			for _, stored := range []bool{false, true} {
				if stored {
					require.NoError(t, cache.Store(ctx, "key", nil))
					value, exists, err := cache.Load(ctx, "key")
					require.NoError(t, err)
					require.True(t, exists, "intentional empty entries are valid")
					require.Empty(t, value)
				}
				require.NoError(t, cache.Delete(ctx, "key"))
				value, exists, err := cache.Load(ctx, "key")
				require.NoError(t, err)
				require.False(t, exists)
				require.Nil(t, value)
			}
		})
	}
}

func TestFileCacheLocksBoundedAcrossHistoricalKeys(t *testing.T) {
	cache := New(afero.NewMemMapFs(), "/cache")
	ctx := context.Background()
	locks := make(map[*sync.Mutex]bool)
	for i := 0; i < 4096; i++ {
		key := fmt.Sprintf("historical-key-%d", i)
		lock := cache.getScopedLock(key)
		locks[lock] = true
		require.NoError(t, cache.Store(ctx, key, []byte("thumbnail")))
		require.NoError(t, cache.Delete(ctx, key))
		require.NoError(t, cache.Delete(ctx, "missing-"+key))
		locks[cache.getScopedLock("missing-"+key)] = true
		require.Same(t, lock, cache.getScopedLock(key), "key lock must remain stable after deletion")
	}
	require.LessOrEqual(t, len(locks), 256, "historical keys must not retain individual locks")
}

func TestFileCacheSameKeyMutationsWaitForPublication(t *testing.T) {
	for _, backend := range []string{"memory", "os"} {
		for _, mutation := range []string{"store", "delete"} {
			t.Run(backend+"/"+mutation, func(t *testing.T) {
				fs, root := cacheTestFS(t, backend)
				ctx := context.Background()
				entered, resume := make(chan struct{}), make(chan struct{})
				var release sync.Once
				cache := New(&cacheTestFaultFS{Fs: fs, entered: entered, resume: resume}, root)
				stored := make(chan error, 1)
				storeFinished := make(chan struct{})
				go func() {
					defer close(storeFinished)
					stored <- cache.Store(ctx, "key", []byte("first thumbnail"))
				}()
				defer func() {
					release.Do(func() { close(resume) })
					<-storeFinished
				}()
				select {
				case <-entered:
				case <-time.After(5 * time.Second):
					t.Fatal("Store did not reach write pause")
				}
				started, mutated := make(chan struct{}), make(chan error, 1)
				mutationFinished := make(chan struct{})
				go func() {
					defer close(mutationFinished)
					close(started)
					if mutation == "delete" {
						mutated <- cache.Delete(ctx, "key")
					} else {
						mutated <- cache.Store(ctx, "key", []byte("second thumbnail"))
					}
				}()
				defer func() {
					release.Do(func() { close(resume) })
					<-mutationFinished
				}()
				<-started
				select {
				case err := <-mutated:
					t.Fatalf("same-key %s finished before publication: %v", mutation, err)
				case <-time.After(25 * time.Millisecond):
				}
				release.Do(func() { close(resume) })
				require.NoError(t, <-stored)
				require.NoError(t, <-mutated)
				value, exists, err := cache.Load(ctx, "key")
				require.NoError(t, err)
				require.Equal(t, mutation == "store", exists)
				if exists {
					require.Equal(t, "second thumbnail", string(value))
				}
			})
		}
	}
}

func cacheTestFS(t *testing.T, backend string) (afero.Fs, string) {
	t.Helper()
	if backend == "os" {
		return afero.NewOsFs(), t.TempDir()
	}
	return afero.NewMemMapFs(), "/cache"
}

func (f *cacheTestFaultFS) MkdirAll(name string, mode os.FileMode) error {
	if f.failure == "mkdir" {
		return os.ErrPermission
	}
	return f.Fs.MkdirAll(name, mode)
}

func (f *cacheTestFaultFS) OpenFile(name string, flag int, mode os.FileMode) (afero.File, error) {
	if f.failure == "create" {
		return nil, os.ErrPermission
	}
	file, err := f.Fs.OpenFile(name, flag, mode)
	if err != nil {
		return nil, err
	}
	return &cacheTestFaultFile{File: file, fs: f}, nil
}

func (f *cacheTestFaultFS) Rename(oldname, newname string) error {
	if f.failure == "rename" {
		return os.ErrPermission
	}
	return f.Fs.Rename(oldname, newname)
}

func (f *cacheTestFaultFile) Write(value []byte) (int, error) {
	if f.fs.entered == nil && f.fs.failure != "write" && f.fs.failure != "short-write" {
		return f.File.Write(value)
	}
	n, err := f.File.Write(value[:len(value)/2])
	if err != nil {
		return n, err
	}
	if f.fs.failure == "write" {
		return n, os.ErrPermission
	}
	if f.fs.failure == "short-write" {
		return n, nil
	}
	// Claim the pause without blocking later writers, so the fixture itself
	// cannot supply the same-key serialization being tested.
	if f.fs.paused.CompareAndSwap(false, true) {
		close(f.fs.entered)
		<-f.fs.resume
	}
	m, err := f.File.Write(value[n:])
	return n + m, err
}

func (f *cacheTestFaultFile) Close() error {
	err := f.File.Close()
	if err != nil {
		return err
	}
	if f.fs.failure == "close" {
		return os.ErrPermission
	}
	return nil
}
