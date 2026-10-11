package fbhttp

import (
	"context"
	"hash/fnv"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"golang.org/x/sync/semaphore"

	"github.com/spf13/afero"
)

// Upload operations share the barrier with recursive resource mutations. File
// writes use a stripe so unrelated uploads can progress concurrently. These
// locks protect this process only; Redis replicas need distributed coordination.
var uploadMutations = struct {
	barrier contextRWLock
	stripes [256]contextRWLock
	entries sync.Map // on-disk path -> *uploadGeneration
}{}

type uploadGeneration struct {
	cache    UploadCache
	cacheKey string
	owned    os.FileInfo
	pathKey  string
	owner    *memoryUploadCache
}

// Weighted acquisition queues writers ahead of subsequent readers. No helper
// goroutine is needed to cancel a wait, including a wait on an upload stripe.
const mutationReaders int64 = 1 << 30

type contextRWLock struct {
	once sync.Once
	sem  *semaphore.Weighted
}

func (l *contextRWLock) init() { l.once.Do(func() { l.sem = semaphore.NewWeighted(mutationReaders) }) }
func (l *contextRWLock) acquire(ctx context.Context, n int64) error {
	l.init()
	return l.sem.Acquire(ctx, n)
}
func (l *contextRWLock) Lock()    { _ = l.acquire(context.Background(), mutationReaders) }
func (l *contextRWLock) Unlock()  { l.sem.Release(mutationReaders) }
func (l *contextRWLock) RLock()   { _ = l.acquire(context.Background(), 1) }
func (l *contextRWLock) RUnlock() { l.sem.Release(1) }

func forgetUploadCache(c *memoryUploadCache) {
	uploadMutations.barrier.Lock()
	defer uploadMutations.barrier.Unlock()
	uploadMutations.entries.Range(func(k, value any) bool {
		if value.(*uploadGeneration).owner == c {
			uploadMutations.entries.Delete(k)
		}
		return true
	})
}

func lockFileUploadMutation(ctx context.Context, d *data, path string) (string, func(), error) {
	if err := uploadMutations.barrier.acquire(ctx, 1); err != nil {
		return "", nil, err
	}
	key := uploadLockKey(d, path)
	unlock, err := lockUploadStripe(ctx, key)
	if err != nil {
		uploadMutations.barrier.RUnlock()
		return "", nil, err
	}
	return key, func() { unlock(); uploadMutations.barrier.RUnlock() }, nil
}

func lockUploadMutation(ctx context.Context, key string) (func(), error) {
	if err := uploadMutations.barrier.acquire(ctx, 1); err != nil {
		return nil, err
	}
	unlock, err := lockUploadStripe(ctx, key)
	if err != nil {
		uploadMutations.barrier.RUnlock()
		return nil, err
	}
	return func() { unlock(); uploadMutations.barrier.RUnlock() }, nil
}

func lockUploadStripe(ctx context.Context, key string) (func(), error) {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	stripe := &uploadMutations.stripes[h.Sum32()%uint32(len(uploadMutations.stripes))]
	if err := stripe.acquire(ctx, mutationReaders); err != nil {
		return nil, err
	}
	return stripe.Unlock, nil
}

// retireUpload must be called while holding the path's mutation lock (or the
// exclusive barrier). Removing the generation also revokes callbacks that TTL
// eviction already dispatched, before a write can truncate the same inode.
func retireUpload(ctx context.Context, key string) {
	if value, ok := uploadMutations.entries.LoadAndDelete(key); ok {
		generation := value.(*uploadGeneration)
		generation.cache.Complete(ctx, generation.cacheKey)
	}
}

// uploadIdentityKey makes API writes through a symlink or hardlink contend
// with the generation whose inode they would truncate.
func uploadIdentityKey(fs afero.Fs, path, key string) string {
	info, err := fs.Stat(path)
	if err != nil {
		return key
	}
	uploadMutations.entries.Range(func(k, value any) bool {
		if os.SameFile(info, value.(*uploadGeneration).owned) {
			key = k.(string)
			return false
		}
		return true
	})
	return key
}

func retireUploadsUnder(ctx context.Context, key string) {
	key = filepath.Clean(key)
	uploadMutations.entries.Range(func(k, value any) bool {
		candidate := k.(string)
		pathKey := value.(*uploadGeneration).pathKey
		if candidate == key || strings.HasPrefix(candidate, key+string(filepath.Separator)) || pathKey == key || strings.HasPrefix(pathKey, key+string(filepath.Separator)) {
			retireUpload(ctx, candidate)
		}
		return true
	})
}

// retireCopyDestination retires only file targets present in the source tree.
// Directory copies merge with their destination, leaving other uploads intact.
// Identity lookup catches hardlinks to uploads outside that tree. The caller
// holds the exclusive barrier throughout discovery and copying.
func retireCopyDestination(ctx context.Context, d *data, src, dst string) error {
	return afero.Walk(d.user.Fs, src, func(candidate string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(src, candidate)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, relative)
		retireUpload(ctx, uploadLockKey(d, target))
		return nil
	})
}

func registerOwnedUpload(ctx context.Context, cache UploadCache, key, pathKey, cacheKey string, size int64, fs afero.Fs, path string, owned os.FileInfo) {
	// Redis has no eviction cleanup. Do not retain local generation records for
	// its expiring entries, or pretend these locks serialize other replicas.
	if _, ok := cache.(*redisUploadCache); ok {
		cache.Register(ctx, cacheKey, size, nil)
		return
	}
	generation := &uploadGeneration{cache: cache, cacheKey: cacheKey, owned: owned, pathKey: pathKey}
	if owner, ok := cache.(interface{ uploadCacheOwner() *memoryUploadCache }); ok {
		generation.owner = owner.uploadCacheOwner()
	}
	uploadMutations.entries.Store(key, generation)
	cache.Register(ctx, cacheKey, size, func() error {
		if current, ok := uploadMutations.entries.Load(key); !ok || current != generation {
			return nil
		}
		cleanupCtx := context.Background()
		if generation.owner != nil {
			cleanupCtx = generation.owner.ctx
		}
		cleanupCtx, cancel := context.WithTimeout(cleanupCtx, uploadCacheIOTimeout)
		defer cancel()
		unlock, err := lockUploadMutation(cleanupCtx, key)
		if err != nil {
			// Expiry runs only once. Drop this exact retired generation even if
			// shutdown or a busy mutation prevents safe partial-file removal.
			uploadMutations.entries.CompareAndDelete(key, generation)
			return err
		}
		defer unlock()
		current, ok := uploadMutations.entries.Load(key)
		if !ok || current != generation {
			return nil
		}
		uploadMutations.entries.Delete(key)
		currentInfo, err := fs.Stat(path)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		// Keep the scoped filesystem check at deletion time. File identity also
		// protects a replacement made outside the API. Filesystems without stable
		// identity cannot safely prove ownership, so leave their partial file alone.
		if !os.SameFile(owned, currentInfo) {
			return nil
		}
		return fs.Remove(path)
	})
}
