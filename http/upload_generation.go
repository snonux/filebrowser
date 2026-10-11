package fbhttp

import (
	"hash/fnv"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/spf13/afero"
)

// Upload operations share the barrier with recursive resource mutations. File
// writes use a stripe so unrelated uploads can progress concurrently. These
// locks protect this process only; Redis replicas need distributed coordination.
var uploadMutations = struct {
	barrier sync.RWMutex
	stripes [256]sync.Mutex
	entries sync.Map // on-disk path -> *uploadGeneration
}{}

type uploadGeneration struct {
	cache    UploadCache
	cacheKey string
	owned    os.FileInfo
	pathKey  string
	owner    *memoryUploadCache
}

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

func lockFileUploadMutation(d *data, path string) (string, func()) {
	uploadMutations.barrier.RLock()
	key := uploadLockKey(d, path)
	unlock := lockUploadStripe(key)
	return key, func() { unlock(); uploadMutations.barrier.RUnlock() }
}

func lockUploadMutation(key string) func() {
	uploadMutations.barrier.RLock()
	unlock := lockUploadStripe(key)
	return func() { unlock(); uploadMutations.barrier.RUnlock() }
}

func lockUploadStripe(key string) func() {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	stripe := &uploadMutations.stripes[h.Sum32()%uint32(len(uploadMutations.stripes))]
	stripe.Lock()
	return stripe.Unlock
}

// retireUpload must be called while holding the path's mutation lock (or the
// exclusive barrier). Removing the generation also revokes callbacks that TTL
// eviction already dispatched, before a write can truncate the same inode.
func retireUpload(key string) {
	if value, ok := uploadMutations.entries.LoadAndDelete(key); ok {
		generation := value.(*uploadGeneration)
		generation.cache.Complete(generation.cacheKey)
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

func retireUploadsUnder(key string) {
	key = filepath.Clean(key)
	uploadMutations.entries.Range(func(k, value any) bool {
		candidate := k.(string)
		pathKey := value.(*uploadGeneration).pathKey
		if candidate == key || strings.HasPrefix(candidate, key+string(filepath.Separator)) || pathKey == key || strings.HasPrefix(pathKey, key+string(filepath.Separator)) {
			retireUpload(candidate)
		}
		return true
	})
}

// retireCopyDestination retires only file targets present in the source tree.
// Directory copies merge with their destination, leaving other uploads intact.
// Identity lookup catches hardlinks to uploads outside that tree. The caller
// holds the exclusive barrier throughout discovery and copying.
func retireCopyDestination(d *data, src, dst string) error {
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
		retireUpload(uploadLockKey(d, target))
		return nil
	})
}

func registerOwnedUpload(cache UploadCache, key, pathKey, cacheKey string, size int64, fs afero.Fs, path string, owned os.FileInfo) {
	// Redis has no eviction cleanup. Do not retain local generation records for
	// its expiring entries, or pretend these locks serialize other replicas.
	if _, ok := cache.(*redisUploadCache); ok {
		cache.Register(cacheKey, size, nil)
		return
	}
	generation := &uploadGeneration{cache: cache, cacheKey: cacheKey, owned: owned, pathKey: pathKey}
	if owner, ok := cache.(interface{ uploadCacheOwner() *memoryUploadCache }); ok {
		generation.owner = owner.uploadCacheOwner()
	}
	uploadMutations.entries.Store(key, generation)
	cache.Register(cacheKey, size, func() error {
		unlock := lockUploadMutation(key)
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
