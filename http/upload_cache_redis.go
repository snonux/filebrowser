package fbhttp

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"sync"

	"golang.org/x/sync/semaphore"

	"github.com/redis/go-redis/v9"
)

// redisUploadCache is an upload cache for multi replica deployments
type redisUploadCache struct {
	options   *redis.Options
	ctx       context.Context
	cancel    context.CancelFunc
	slots     *semaphore.Weighted
	mu        sync.Mutex
	idle      []*redis.Client
	closed    bool
	active    sync.WaitGroup
	closeOnce sync.Once
}

func newRedisUploadCache(redisURL string) (*redisUploadCache, error) {
	if redisURL == "" {
		return nil, fmt.Errorf("redis URL is required")
	}

	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("invalid redis URL: %w", err)
	}

	opts.ContextTimeoutEnabled = true
	client := redis.NewClient(opts)

	// Bound startup I/O independently of request lifetimes.
	ctx, cancel := context.WithTimeout(context.Background(), uploadCacheIOTimeout)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("failed to connect to redis: %w", err)
	}

	return ownedRedisUploadCache(client), nil
}

const redisUploadReservations = 16

// Each command reserves a single-connection client. Cancellation closes only
// that reservation's socket (go-redis has no public per-command socket
// interruption API); healthy clients are reused by subsequent commands.
func ownedRedisUploadCache(client *redis.Client) *redisUploadCache {
	ctx, cancel := context.WithCancel(context.Background())
	options := *client.Options()
	options.PoolSize = 1
	options.MaxActiveConns = 1
	return &redisUploadCache{options: &options, ctx: ctx, cancel: cancel, slots: semaphore.NewWeighted(redisUploadReservations), idle: []*redis.Client{client}}
}

func (c *redisUploadCache) run(ctx context.Context, fn func(context.Context, *redis.Client) error) error {
	ctx, cancel := context.WithTimeout(ctx, uploadCacheIOTimeout)
	defer cancel()
	stopShutdown := context.AfterFunc(c.ctx, cancel)
	defer stopShutdown()
	if err := c.slots.Acquire(ctx, 1); err != nil {
		return err
	}
	defer c.slots.Release(1)
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return context.Canceled
	}
	c.active.Add(1)
	var client *redis.Client
	if n := len(c.idle); n > 0 {
		client = c.idle[n-1]
		c.idle = c.idle[:n-1]
	} else {
		options := *c.options
		client = redis.NewClient(&options)
	}
	c.mu.Unlock()
	defer c.active.Done()
	canceled := make(chan struct{})
	interrupt := context.AfterFunc(ctx, func() { _ = client.Close(); close(canceled) })
	err := fn(ctx, client)
	if !interrupt() {
		<-canceled
	}
	if ctx.Err() != nil {
		_ = client.Close()
		return ctx.Err()
	}
	c.mu.Lock()
	if c.closed {
		_ = client.Close()
	} else {
		c.idle = append(c.idle, client)
	}
	c.mu.Unlock()
	return err
}

func (c *redisUploadCache) filePathKey(filePath string) string {
	return "filebrowser:upload:" + filePath
}

// Register stores the upload length. The scoped removal callback is unused by
// the redis backend, which does not delete partial files on eviction.
func (c *redisUploadCache) Register(ctx context.Context, filePath string, fileSize int64, _ func() error) {
	err := c.run(ctx, func(ctx context.Context, client *redis.Client) error {
		return client.Set(ctx, c.filePathKey(filePath), fileSize, uploadCacheTTL).Err()
	})
	if err != nil {
		log.Printf("failed to register upload in redis cache: %v", err)
	}
}

func (c *redisUploadCache) Complete(ctx context.Context, filePath string) {
	err := c.run(ctx, func(ctx context.Context, client *redis.Client) error {
		return client.Del(ctx, c.filePathKey(filePath)).Err()
	})
	if err != nil {
		log.Printf("failed to complete upload in redis cache: %v", err)
	}
}

func (c *redisUploadCache) GetLength(ctx context.Context, filePath string) (int64, error) {
	var result string
	err := c.run(ctx, func(ctx context.Context, client *redis.Client) error {
		var err error
		result, err = client.Get(ctx, c.filePathKey(filePath)).Result()
		return err
	})
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return 0, fmt.Errorf("no active upload found for the given path")
		}
		return 0, fmt.Errorf("redis error: %w", err)
	}

	size, err := strconv.ParseInt(result, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid upload length in cache: %w", err)
	}

	c.Touch(ctx, filePath)

	return size, nil
}

func (c *redisUploadCache) Touch(ctx context.Context, filePath string) {
	err := c.run(ctx, func(ctx context.Context, client *redis.Client) error {
		return client.Expire(ctx, c.filePathKey(filePath), uploadCacheTTL).Err()
	})
	if err != nil {
		log.Printf("failed to touch upload in redis cache: %v", err)
	}
}

func (c *redisUploadCache) Close() {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		c.cancel()
		c.mu.Unlock()
		c.active.Wait()
		for _, client := range c.idle {
			_ = client.Close()
		}
		c.idle = nil
	})
}
