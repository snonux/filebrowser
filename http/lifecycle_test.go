package fbhttp

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/img"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
	"github.com/redis/go-redis/v9"
	"github.com/spf13/afero"
)

type contextPreviewService struct{ ctx context.Context }

func (*contextPreviewService) FormatFromExtension(string) (img.Format, error) {
	return img.FormatJpeg, nil
}
func (s *contextPreviewService) Resize(ctx context.Context, _ io.Reader, _, _ int, out io.Writer, _ ...img.Option) error {
	s.ctx = ctx
	if err := ctx.Err(); err != nil {
		return err
	}
	_, err := out.Write([]byte("preview"))
	return err
}

type joinedPreviewCache struct {
	ctx     context.Context
	entered chan struct{}
	release chan struct{}
}

func (c *joinedPreviewCache) Store(ctx context.Context, _ string, _ []byte) error {
	c.ctx = ctx
	close(c.entered)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-c.release:
		return nil
	}
}
func (*joinedPreviewCache) Load(context.Context, string) ([]byte, bool, error) {
	return nil, false, nil
}
func (*joinedPreviewCache) Delete(context.Context, string) error { return nil }

func TestPreviewUsesRequestContextAndJoinsPublication(t *testing.T) {
	fs := afero.NewMemMapFs()
	if err := afero.WriteFile(fs, "/image", []byte("image"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	svc := &contextPreviewService{}
	cache := &joinedPreviewCache{entered: make(chan struct{}), release: make(chan struct{})}
	done := make(chan error, 1)
	go func() {
		_, err := createPreview(ctx, svc, cache, &files.FileInfo{Fs: fs, Path: "/image"}, PreviewSizeThumb)
		done <- err
	}()
	<-cache.entered
	if svc.ctx != ctx || cache.ctx != ctx {
		t.Fatal("preview lost request context")
	}
	select {
	case <-done:
		t.Fatal("preview returned with cache write outstanding")
	default:
	}
	close(cache.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	cancel()
	_, err := createPreview(ctx, svc, cache, &files.FileInfo{Fs: fs, Path: "/image"}, PreviewSizeThumb)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled preview = %v", err)
	}
}

func TestPatchCancelsWhileMutationLockHeld(t *testing.T) {
	for _, kind := range []string{"barrier", "stripe"} {
		t.Run(kind, func(t *testing.T) {
			scope := t.TempDir()
			tokenKey := []byte("cancel-blocked-patch")
			perm := users.Permissions{Create: true, Modify: true}
			st := scopedUserStorage(t, scope, perm, tokenKey)
			memory := newMemoryUploadCache()
			defer memory.Close()
			cache := &touchedUploadCache{memoryUploadCache: memory, touched: make(chan string, 8)}
			post := httptest.NewRequest(http.MethodPost, "/partial", nil)
			post.Header.Set("X-Auth", signToken(t, perm, tokenKey))
			post.Header.Set("Upload-Length", "8")
			rec := httptest.NewRecorder()
			handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, post)
			if rec.Code != http.StatusCreated {
				t.Fatalf("POST = %d", rec.Code)
			}
			var release func()
			if kind == "barrier" {
				uploadMutations.barrier.Lock()
				release = uploadMutations.barrier.Unlock
			} else {
				var err error
				release, err = lockUploadStripe(context.Background(), filepath.Join(scope, "partial"))
				if err != nil {
					t.Fatal(err)
				}
			}
			var once sync.Once
			defer once.Do(release)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			req := httptest.NewRequest(http.MethodPatch, "/partial", bytes.NewReader([]byte("part"))).WithContext(ctx)
			req.Header.Set("X-Auth", signToken(t, perm, tokenKey))
			req.Header.Set("Upload-Offset", "0")
			req.Header.Set("Content-Type", "application/offset+octet-stream")
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				r := httptest.NewRecorder()
				handle(tusPatchHandler(cache), "", st, &settings.Server{}).ServeHTTP(r, req)
				done <- r
			}()
			<-cache.touched
			select {
			case <-done:
				t.Fatal("PATCH bypassed held mutation lock")
			default:
			}
			cancel()
			select {
			case r := <-done:
				if r.Code != http.StatusRequestTimeout {
					t.Fatalf("PATCH = %d: %s", r.Code, r.Body.String())
				}
			case <-time.After(time.Second):
				t.Fatal("canceled PATCH waited for mutation lock")
			}
			content, err := os.ReadFile(filepath.Join(scope, "partial"))
			if err != nil || len(content) != 0 {
				t.Fatalf("canceled PATCH wrote %q: %v", content, err)
			}
			once.Do(release)
			resumed := req.Clone(context.Background())
			resumed.Body = io.NopCloser(bytes.NewReader([]byte("part")))
			rec = httptest.NewRecorder()
			handle(tusPatchHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, resumed)
			if rec.Code != http.StatusNoContent {
				t.Fatalf("PATCH after canceled waiter = %d: %s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestMemoryCacheCloseJoinsWorkerAndEviction(t *testing.T) {
	cache := newMemoryUploadCache()
	entered, release := make(chan struct{}), make(chan struct{})
	cache.cache.Set("expired", memoryUploadEntry{remove: func() error { close(entered); <-release; return nil }}, time.Nanosecond)
	cache.cache.DeleteExpired()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("eviction callback never ran")
	}
	done := make(chan struct{})
	go func() { cache.Close(); close(done) }()
	<-cache.ctx.Done()
	select {
	case <-done:
		t.Fatal("Close returned before active eviction callback")
	default:
	}
	close(release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Close did not join eviction")
	}
	select {
	case <-cache.done:
	default:
		t.Fatal("cache worker still running")
	}
	cache.Close()
}

func newHeldRedisCache(t *testing.T) (*redisUploadCache, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	entered := make(chan string, 32)
	var mu sync.Mutex
	var connections []net.Conn
	var workers sync.WaitGroup
	acceptDone := make(chan struct{})
	go func() {
		defer close(acceptDone)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			connections = append(connections, conn)
			mu.Unlock()
			workers.Add(1)
			go func() {
				defer workers.Done()
				defer func() { _ = conn.Close() }()
				reader := bufio.NewReader(conn)
				for {
					line, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					n, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "*")))
					if err != nil {
						return
					}
					args := make([]string, n)
					for i := range args {
						if _, err := reader.ReadString('\n'); err != nil {
							return
						}
						line, err = reader.ReadString('\n')
						if err != nil {
							return
						}
						args[i] = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
					}
					reply := "+OK\r\n"
					switch strings.ToLower(args[0]) {
					case "hello":
						reply = "-ERR unknown command 'hello'\r\n"
					case "get":
						if strings.HasSuffix(args[1], "held") {
							entered <- args[1]
							_, _ = io.Copy(io.Discard, reader)
							return
						}
						reply = "$1\r\n8\r\n"
					case "expire":
						reply = ":1\r\n"
					case "ping":
						reply = "+PONG\r\n"
					}
					if _, err := io.WriteString(conn, reply); err != nil {
						return
					}
				}
			}()
		}
	}()
	client := redis.NewClient(&redis.Options{Addr: listener.Addr().String(), Protocol: 2, DisableIdentity: true, ContextTimeoutEnabled: true, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, MaxRetries: -1})
	cache := ownedRedisUploadCache(client)
	t.Cleanup(func() {
		cache.Close()
		_ = listener.Close()
		<-acceptDone
		mu.Lock()
		for _, conn := range connections {
			_ = conn.Close()
		}
		mu.Unlock()
		workers.Wait()
	})
	return cache, entered
}

func TestRedisCacheCancellationInterruptsHeldIO(t *testing.T) {
	cache, entered := newHeldRedisCache(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := cache.GetLength(ctx, "held"); done <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("GET never reached Redis socket")
	}
	// A separate client must remain usable while one command is held.
	if length, err := cache.GetLength(context.Background(), "healthy"); err != nil || length != 8 {
		t.Fatalf("parallel healthy command = %d, %v", length, err)
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("held GET = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Redis ignored manual cancellation during GET")
	}
	// Reserve both slots again: the canceled client must be replaced and the
	// unaffected client must continue to work.
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	go func() { _, err := cache.GetLength(ctx2, "held"); done <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("replacement reservation did not run GET")
	}
	if length, err := cache.GetLength(context.Background(), "healthy"); err != nil || length != 8 {
		t.Fatalf("post-cancel healthy command = %d, %v", length, err)
	}
	cancel2()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestRedisCacheCloseCancelsHeldIOAndWaiter(t *testing.T) {
	cache, entered := newHeldRedisCache(t)
	if err := cache.slots.Acquire(context.Background(), 15); err != nil {
		t.Fatal(err)
	}
	defer cache.slots.Release(15)
	active := make(chan error, 1)
	go func() { _, err := cache.GetLength(context.Background(), "held"); active <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("held GET never ran")
	}
	waiter := make(chan error, 1)
	go func() { _, err := cache.GetLength(context.Background(), "healthy"); waiter <- err }()
	cache.Close()
	for _, done := range []<-chan error{active, waiter} {
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("Close command = %v", err)
			}
		case <-time.After(time.Second):
			t.Fatal("Close left Redis operation running")
		}
	}
}

func TestCanceledCleanupForgetsOnlyOwnedGeneration(t *testing.T) {
	for _, replacement := range []bool{false, true} {
		t.Run(fmt.Sprintf("replacement=%t", replacement), func(t *testing.T) {
			memory := newMemoryUploadCache()
			defer memory.Close()
			cache := &capturedUploadCache{UploadCache: memory}
			fs := afero.NewMemMapFs()
			if err := afero.WriteFile(fs, "/partial", []byte("part"), 0600); err != nil {
				t.Fatal(err)
			}
			info, err := fs.Stat("/partial")
			if err != nil {
				t.Fatal(err)
			}
			key := filepath.Join(t.TempDir(), "partial")
			registerOwnedUpload(context.Background(), cache, key, key, key, 8, fs, "/partial", info)
			remove := cache.removal()
			var newer *uploadGeneration
			if replacement {
				newer = &uploadGeneration{owner: memory, cache: cache}
				uploadMutations.entries.Store(key, newer)
			}
			uploadMutations.barrier.Lock()
			memory.cancel()
			err = remove()
			uploadMutations.barrier.Unlock()
			if !replacement && !errors.Is(err, context.Canceled) {
				t.Fatalf("cleanup = %v", err)
			}
			current, ok := uploadMutations.entries.Load(key)
			if replacement {
				if !ok || current != newer {
					t.Fatal("canceled cleanup retired newer generation")
				}
			} else if ok {
				t.Fatal("expired generation retained after canceled cleanup")
			}
			if _, err := fs.Stat("/partial"); err != nil {
				t.Fatalf("unlocked cleanup deleted file: %v", err)
			}
		})
	}
}

type heldKeepaliveCache struct {
	UploadCache
	entered chan struct{}
	exited  chan struct{}
	calls   int
}

func (c *heldKeepaliveCache) Touch(ctx context.Context, _ string) {
	c.calls++
	if c.calls == 1 {
		return
	}
	close(c.entered)
	<-ctx.Done()
	close(c.exited)
}

func TestKeepaliveStopCancelsAndJoinsPendingIO(t *testing.T) {
	cache := &heldKeepaliveCache{entered: make(chan struct{}), exited: make(chan struct{})}
	stop := keepUploadActive(context.Background(), cache, "cache", "absent-generation", nil)
	select {
	case <-cache.entered:
	case <-time.After(3 * time.Second):
		stop()
		t.Fatal("keepalive never entered pending I/O")
	}
	done := make(chan struct{})
	go func() { stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stop did not cancel pending keepalive I/O")
	}
	select {
	case <-cache.exited:
	default:
		t.Fatal("stop returned before pending I/O exited")
	}
}
