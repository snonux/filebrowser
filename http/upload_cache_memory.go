package fbhttp

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/jellydator/ttlcache/v3"
)

const uploadCacheTTL = 3 * time.Minute
const uploadCacheIOTimeout = 5 * time.Second

// UploadCache is an interface for tracking active uploads.
// Allows for different backends (e.g. in-memory or redis)
// to support both single instance and multi replica deployments.
type UploadCache interface {
	// Register stores an upload with its expected file size. remove is called if
	// the upload expires before completion, to delete the partial file; it must
	// route through the uploading user's scoped filesystem so that eviction
	// cannot follow a symlink out of the user's scope.
	Register(ctx context.Context, filePath string, fileSize int64, remove func() error)

	// Complete removes an upload from the cache
	Complete(ctx context.Context, filePath string)

	// GetLength returns the expected file size for an active upload
	GetLength(ctx context.Context, filePath string) (int64, error)

	// Touch refreshes the TTL for an active upload
	Touch(ctx context.Context, filePath string)

	// Close cleans up any resources
	Close()
}

// memoryUploadEntry is the value stored for each active upload.
type memoryUploadEntry struct {
	size   int64
	remove func() error
}

// memoryUploadCache is an upload cache for single replica deployments
type memoryUploadCache struct {
	cache       *ttlcache.Cache[string, memoryUploadEntry]
	ctx         context.Context
	cancel      context.CancelFunc
	done        chan struct{}
	unsubscribe func()
	closeOnce   sync.Once
}

func newMemoryUploadCache() *memoryUploadCache {
	cache := ttlcache.New[string, memoryUploadEntry]()
	unsubscribe := cache.OnEviction(func(_ context.Context, reason ttlcache.EvictionReason, item *ttlcache.Item[string, memoryUploadEntry]) {
		if reason == ttlcache.EvictionReasonExpired {
			fmt.Printf("deleting incomplete upload file: \"%s\"\n", item.Key())
			// Delete through the scoped removal callback rather than a raw
			// os.Remove on the cached path, so an ancestor directory swapped for
			// a symlink during the TTL window cannot redirect the delete outside
			// the user's scope.
			if remove := item.Value().remove; remove != nil {
				if err := remove(); err != nil {
					fmt.Printf("failed to delete incomplete upload file %q: %v\n", item.Key(), err)
				}
			}
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	c := &memoryUploadCache{cache: cache, ctx: ctx, cancel: cancel, done: make(chan struct{}), unsubscribe: unsubscribe}
	go func() {
		defer close(c.done)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				cache.DeleteExpired()
			}
		}
	}()
	return c
}

func (c *memoryUploadCache) Register(_ context.Context, filePath string, fileSize int64, remove func() error) {
	c.cache.Set(filePath, memoryUploadEntry{size: fileSize, remove: remove}, uploadCacheTTL)
}

func (c *memoryUploadCache) Complete(_ context.Context, filePath string) {
	c.cache.Delete(filePath)
}

func (c *memoryUploadCache) GetLength(_ context.Context, filePath string) (int64, error) {
	item := c.cache.Get(filePath)
	if item == nil {
		return 0, fmt.Errorf("no active upload found for the given path")
	}
	return item.Value().size, nil
}

func (c *memoryUploadCache) Touch(_ context.Context, filePath string) {
	c.cache.Touch(filePath)
}

func (c *memoryUploadCache) uploadCacheOwner() *memoryUploadCache { return c }

func (c *memoryUploadCache) Close() {
	c.closeOnce.Do(func() {
		c.cancel()
		<-c.done
		c.unsubscribe()
		forgetUploadCache(c)
		c.cache.DeleteAll()
	})
}

// NewUploadCache creates a new upload cache.
// If redisURL is empty, an in-memory cache will be used (suitable for single instance deployments).
// Otherwise, Redis will be used for the cache (suitable for multi-instance deployments).
// The redisURL can include credentials, e.g. redis://user:pass@host:port
func NewUploadCache(redisURL string) (UploadCache, error) {
	if redisURL != "" {
		return newRedisUploadCache(redisURL)
	}
	return newMemoryUploadCache(), nil
}
