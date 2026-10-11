package fbhttp

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/filebrowser/filebrowser/v2/diskcache"
	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
	"github.com/jellydator/ttlcache/v3"
	"github.com/spf13/afero"
)

type capturedUploadCache struct {
	UploadCache
	mu       sync.Mutex
	removals []func() error
}

func (c *capturedUploadCache) uploadCacheOwner() *memoryUploadCache {
	return c.UploadCache.(*memoryUploadCache)
}

func (c *capturedUploadCache) Register(ctx context.Context, key string, size int64, remove func() error) {
	c.mu.Lock()
	c.removals = append(c.removals, remove)
	c.mu.Unlock()
	c.UploadCache.Register(ctx, key, size, remove)
}

func (c *capturedUploadCache) removal() func() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.removals[len(c.removals)-1]
}

type crossDeviceRenameFs struct{ afero.Fs }

func (f crossDeviceRenameFs) Rename(src, dst string) error {
	return &os.LinkError{Op: "rename", Old: src, New: dst, Err: syscall.EXDEV}
}

func TestRenameDestinationUploadOwnership(t *testing.T) {
	for _, kind := range []string{"directory merge", "cross device", "native rename"} {
		t.Run(kind, func(t *testing.T) {
			scope := t.TempDir()
			key := []byte("rename-ownership")
			perm := users.Permissions{Create: true, Modify: true, Rename: true}
			st := scopedUserStorage(t, scope, perm, key)
			if kind == "cross device" {
				st.Users.(*customFSUser).fs = afero.NewBasePathFs(crossDeviceRenameFs{Fs: afero.NewOsFs()}, scope)
			}
			memory := newMemoryUploadCache()
			t.Cleanup(memory.Close)
			cache := &capturedUploadCache{UploadCache: memory}
			request := func(method, path string, body []byte, handler handleFunc) int {
				t.Helper()
				req := httptest.NewRequest(method, path, bytes.NewReader(body))
				req.Header.Set("X-Auth", signToken(t, perm, key))
				req.Header.Set("Upload-Length", "8")
				req.Header.Set("Upload-Offset", "0")
				req.Header.Set("Content-Type", "application/offset+octet-stream")
				rec := httptest.NewRecorder()
				handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
				return rec.Code
			}
			for _, path := range []string{"/outside/upload", "/dest/unrelated"} {
				if status := request(http.MethodPost, path, nil, tusPostHandler(cache)); status != http.StatusCreated {
					t.Fatalf("create %s = %d", path, status)
				}
			}
			cache.mu.Lock()
			removeAlias, removeUnrelated := cache.removals[0], cache.removals[1]
			cache.mu.Unlock()
			if err := os.Link(filepath.Join(scope, "outside", "upload"), filepath.Join(scope, "dest", "alias")); err != nil {
				t.Skip(err)
			}
			source, target := "/source", "/dest/alias"
			if kind == "directory merge" {
				if err := os.Mkdir(filepath.Join(scope, "source"), 0o755); err != nil {
					t.Fatal(err)
				}
				source, target = "/source/alias", "/dest"
			}
			if err := os.WriteFile(filepath.Join(scope, source), []byte("saved"), 0o644); err != nil {
				t.Fatal(err)
			}
			if status := request(http.MethodPatch, "/source?action=rename&destination="+target+"&override=true", nil, resourcePatchHandler(diskcache.NewNoOp())); status != http.StatusOK {
				t.Fatalf("rename = %d", status)
			}
			if _, err := os.Stat(filepath.Join(scope, "source")); !os.IsNotExist(err) {
				t.Fatalf("rename source remained: %v", err)
			}
			if status := request(http.MethodPatch, "/dest/unrelated", []byte("part"), tusPatchHandler(cache)); status != http.StatusNoContent {
				t.Fatalf("unmatched upload no longer resumable: %d", status)
			}
			if kind == "native rename" {
				if status := request(http.MethodPatch, "/outside/upload", []byte("part"), tusPatchHandler(cache)); status != http.StatusNoContent {
					t.Fatalf("native rename retired untouched alias: %d", status)
				}
			} else if status := request(http.MethodPatch, "/outside/upload", []byte("part"), tusPatchHandler(cache)); status != http.StatusNotFound {
				t.Fatalf("overwritten alias upload remained resumable: %d", status)
			}
			if err := removeAlias(); err != nil {
				t.Fatal(err)
			}
			if err := removeUnrelated(); err != nil {
				t.Fatal(err)
			}
			content, err := os.ReadFile(filepath.Join(scope, "dest", "alias"))
			if err != nil || string(content) != "saved" {
				t.Fatalf("renamed save after cleanup = %q, %v", content, err)
			}
			_, err = os.Stat(filepath.Join(scope, "outside", "upload"))
			if kind == "native rename" {
				if !os.IsNotExist(err) {
					t.Fatalf("untouched abandoned alias retained: %v", err)
				}
			} else {
				content, err = os.ReadFile(filepath.Join(scope, "outside", "upload"))
				if err != nil || string(content) != "saved" {
					t.Fatalf("overwritten alias after cleanup = %q, %v", content, err)
				}
			}
			if _, err := os.Stat(filepath.Join(scope, "dest", "unrelated")); !os.IsNotExist(err) {
				t.Fatalf("unmatched abandoned upload retained: %v", err)
			}
		})
	}
}

func TestUploadGenerationCleanup(t *testing.T) {
	for _, mutation := range []string{"put", "post", "symlink", "hardlink", "new-upload", "complete", "external-replacement", "abandoned", "denied", "tus-delete", "denied-delete"} {
		t.Run(mutation, func(t *testing.T) {
			scope := t.TempDir()
			key := []byte("upload-generation-test")
			perm := users.Permissions{Create: true, Modify: true, Delete: true}
			if mutation == "denied" {
				perm.Modify = false
			}
			if mutation == "denied-delete" {
				perm.Delete = false
			}
			st := scopedUserStorage(t, scope, perm, key)
			memory := newMemoryUploadCache()
			t.Cleanup(memory.Close)
			cache := &capturedUploadCache{UploadCache: memory}
			server := &settings.Server{}
			request := func(method, path string, body []byte, headers map[string]string, handler handleFunc) *httptest.ResponseRecorder {
				t.Helper()
				req := httptest.NewRequest(method, path, bytes.NewReader(body))
				req.Header.Set("X-Auth", signToken(t, perm, key))
				for k, v := range headers {
					req.Header.Set(k, v)
				}
				rec := httptest.NewRecorder()
				handle(handler, "", st, server).ServeHTTP(rec, req)
				return rec
			}
			create := func(path string) {
				t.Helper()
				rec := request(http.MethodPost, path, nil, map[string]string{"Upload-Length": "8"}, tusPostHandler(cache))
				if rec.Code != http.StatusCreated {
					t.Fatalf("create = %d: %s", rec.Code, rec.Body.String())
				}
			}
			create("/file")
			originalRemove := cache.removal()
			// Hold a callback that eviction has already dispatched. The callback must
			// recheck its generation after the replacement, rather than relying on
			// removal of the cache entry to cancel dispatched work.
			release := make(chan struct{})
			dispatched := make(chan struct{})
			done := make(chan error, 1)
			go func() { close(dispatched); <-release; done <- originalRemove() }()
			<-dispatched
			content := []byte("saved")
			switch mutation {
			case "put", "symlink", "hardlink", "denied":
				dst := "/file"
				if mutation == "symlink" || mutation == "hardlink" {
					var err error
					if mutation == "symlink" {
						err = os.Symlink("file", filepath.Join(scope, "alias"))
					} else {
						err = os.Link(filepath.Join(scope, "file"), filepath.Join(scope, "alias"))
					}
					if err != nil {
						close(release)
						<-done
						t.Skip(err)
					}
					dst = "/alias"
				}
				rec := request(http.MethodPut, dst, content, nil, resourcePutHandler)
				want := http.StatusOK
				if mutation == "denied" {
					want = http.StatusForbidden
				}
				if rec.Code != want {
					t.Fatalf("PUT = %d: %s", rec.Code, rec.Body.String())
				}
			case "post":
				rec := request(http.MethodPost, "/file?override=true", content, nil, resourcePostHandler(diskcache.NewNoOp()))
				if rec.Code != http.StatusOK {
					t.Fatalf("POST = %d", rec.Code)
				}
			case "new-upload":
				create("/file?override=true")
				content = nil
			case "complete":
				content = []byte("complete")
				rec := request(http.MethodPatch, "/file", content, map[string]string{"Content-Type": "application/offset+octet-stream", "Upload-Offset": "0"}, tusPatchHandler(cache))
				if rec.Code != http.StatusNoContent {
					t.Fatalf("PATCH = %d", rec.Code)
				}
			case "tus-delete", "denied-delete":
				rec := request(http.MethodDelete, "/file", nil, nil, tusDeleteHandler(cache))
				want := http.StatusNoContent
				if mutation == "denied-delete" {
					want = http.StatusForbidden
				}
				if rec.Code != want {
					t.Fatalf("DELETE = %d", rec.Code)
				}
				if mutation == "tus-delete" {
					if err := os.WriteFile(filepath.Join(scope, "file"), content, 0o644); err != nil {
						t.Fatal(err)
					}
				}
			case "external-replacement":
				if err := os.WriteFile(filepath.Join(scope, "replacement"), content, 0o644); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(filepath.Join(scope, "replacement"), filepath.Join(scope, "file")); err != nil {
					t.Fatal(err)
				}
			case "abandoned":
				rec := request(http.MethodPatch, "/file", []byte("part"), map[string]string{"Content-Type": "application/offset+octet-stream", "Upload-Offset": "0"}, tusPatchHandler(cache))
				if rec.Code != http.StatusNoContent {
					t.Fatalf("PATCH = %d", rec.Code)
				}
			}
			close(release)
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			stored, err := os.ReadFile(filepath.Join(scope, "file"))
			if mutation == "abandoned" || mutation == "denied" || mutation == "denied-delete" {
				if !os.IsNotExist(err) {
					t.Fatalf("abandoned upload retained: %v", err)
				}
				return
			}
			if err != nil || !bytes.Equal(stored, content) {
				t.Fatalf("replacement content = %q, %v; want %q", stored, err, content)
			}
			if mutation == "new-upload" {
				// The stale callback must not retire the later generation's length or
				// cleanup ownership. Completing that generation must revoke its callback.
				rec := request(http.MethodPatch, "/file", []byte("complete"), map[string]string{"Content-Type": "application/offset+octet-stream", "Upload-Offset": "0"}, tusPatchHandler(cache))
				if rec.Code != http.StatusNoContent {
					t.Fatalf("new PATCH = %d", rec.Code)
				}
				if err := cache.removal()(); err != nil {
					t.Fatal(err)
				}
				stored, err = os.ReadFile(filepath.Join(scope, "file"))
				if err != nil || string(stored) != "complete" {
					t.Fatalf("completed generation removed: %q, %v", stored, err)
				}
			}
		})
	}
}

func TestUploadGenerationRealExpiryDeletesPartial(t *testing.T) {
	scope := t.TempDir()
	key := []byte("expiry-test")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	cache := newMemoryUploadCache()
	t.Cleanup(cache.Close)
	req := httptest.NewRequest(http.MethodPost, "/partial", nil)
	req.Header.Set("X-Auth", signToken(t, perm, key))
	req.Header.Set("Upload-Length", "8")
	rec := httptest.NewRecorder()
	handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d", rec.Code)
	}
	patch := httptest.NewRequest(http.MethodPatch, "/partial", bytes.NewReader([]byte("part")))
	patch.Header.Set("X-Auth", signToken(t, perm, key))
	patch.Header.Set("Upload-Offset", "0")
	patch.Header.Set("Content-Type", "application/offset+octet-stream")
	patchRec := httptest.NewRecorder()
	handle(tusPatchHandler(cache), "", st, &settings.Server{}).ServeHTTP(patchRec, patch)
	if patchRec.Code != http.StatusNoContent {
		t.Fatalf("partial PATCH = %d", patchRec.Code)
	}
	path := filepath.Join(scope, "partial")
	cacheKeys := cache.cache.Keys()
	if len(cacheKeys) != 1 {
		t.Fatalf("cache keys = %v", cacheKeys)
	}
	cacheKey := cacheKeys[0]
	item := cache.cache.Get(cacheKey)
	if item == nil {
		t.Fatal("upload not registered")
	}
	value := item.Value()
	done := make(chan error, 1)
	remove := value.remove
	value.remove = func() error { err := remove(); done <- err; return err }
	cache.cache.Set(cacheKey, value, time.Millisecond)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expiry did not run")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("partial retained: %v", err)
	}
}

func TestConcurrentAliasUploadCreationRetiresEarlierGeneration(t *testing.T) {
	scope := t.TempDir()
	if err := os.WriteFile(filepath.Join(scope, "file"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(scope, "file"), filepath.Join(scope, "alias")); err != nil {
		t.Skip(err)
	}
	key := []byte("alias-create")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	memory := newMemoryUploadCache()
	t.Cleanup(memory.Close)
	cache := &capturedUploadCache{UploadCache: memory}
	// Hold both creations before identity discovery. They must discover and
	// replace ownership serially, even though their URL paths differ.
	uploadMutations.barrier.Lock()
	entered := make(chan struct{}, 2)
	results := make(chan int, 2)
	for _, path := range []string{"/file?override=true", "/alias?override=true"} {
		go func(path string) {
			req := httptest.NewRequest(http.MethodPost, path, nil)
			req.Header.Set("X-Auth", signToken(t, perm, key))
			req.Header.Set("Upload-Length", "8")
			rec := httptest.NewRecorder()
			entered <- struct{}{}
			handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, req)
			results <- rec.Code
		}(path)
	}
	<-entered
	<-entered
	uploadMutations.barrier.Unlock()
	for range 2 {
		if status := <-results; status != http.StatusCreated {
			t.Fatalf("POST = %d", status)
		}
	}
	cache.mu.Lock()
	callbacks := append([]func() error(nil), cache.removals...)
	cache.mu.Unlock()
	if len(callbacks) != 2 {
		t.Fatalf("callbacks = %d", len(callbacks))
	}
	if err := callbacks[0](); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(scope, "file")); err != nil {
		t.Fatalf("earlier expiry removed later inode: %v", err)
	}
	if _, err := os.Stat(filepath.Join(scope, "alias")); err != nil {
		t.Fatal(err)
	}
	if err := callbacks[1](); err != nil {
		t.Fatal(err)
	}
	// The last creation owns exactly its path; expiry unlinks that file only.
	_, fileErr := os.Stat(filepath.Join(scope, "file"))
	_, aliasErr := os.Stat(filepath.Join(scope, "alias"))
	if os.IsNotExist(fileErr) == os.IsNotExist(aliasErr) {
		t.Fatalf("owned partial not removed exactly once: file=%v alias=%v", fileErr, aliasErr)
	}
}

func TestResourceDirectoryMutationRetiresUploadDescendants(t *testing.T) {
	for _, action := range []string{"delete", "rename", "copy"} {
		t.Run(action, func(t *testing.T) {
			scope := t.TempDir()
			key := []byte("directory-mutation")
			perm := users.Permissions{Create: true, Modify: true, Delete: true, Rename: true}
			st := scopedUserStorage(t, scope, perm, key)
			memory := newMemoryUploadCache()
			t.Cleanup(memory.Close)
			cache := &capturedUploadCache{UploadCache: memory}
			request := func(method, path string, handler handleFunc, headers map[string]string) int {
				req := httptest.NewRequest(method, path, nil)
				req.Header.Set("X-Auth", signToken(t, perm, key))
				for k, v := range headers {
					req.Header.Set(k, v)
				}
				rec := httptest.NewRecorder()
				handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
				return rec.Code
			}
			if status := request(http.MethodPost, "/dir/partial", tusPostHandler(cache), map[string]string{"Upload-Length": "8"}); status != http.StatusCreated {
				t.Fatalf("create = %d", status)
			}
			remove := cache.removal()
			registeredKeys := memory.cache.Keys()
			if len(registeredKeys) != 1 {
				t.Fatalf("cache keys = %v", registeredKeys)
			}
			registeredKey := registeredKeys[0]
			if length, err := memory.GetLength(context.Background(), registeredKey); err != nil || length != 8 {
				t.Fatalf("descendant upload was not active: length=%d err=%v", length, err)
			}
			var status int
			switch action {
			case "delete":
				status = request(http.MethodDelete, "/dir", resourceDeleteHandler(diskcache.NewNoOp()), nil)
			case "rename":
				status = request(http.MethodPatch, "/dir?action=rename&destination=/renamed", resourcePatchHandler(diskcache.NewNoOp()), nil)
			case "copy":
				if err := os.Mkdir(filepath.Join(scope, "source"), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(scope, "source", "partial"), []byte("copy"), 0o644); err != nil {
					t.Fatal(err)
				}
				status = request(http.MethodPatch, "/source?action=copy&destination=/dir&override=true", resourcePatchHandler(diskcache.NewNoOp()), nil)
			}
			if status != http.StatusOK && status != http.StatusNoContent {
				t.Fatalf("mutation = %d", status)
			}
			if _, err := memory.GetLength(context.Background(), registeredKey); err == nil {
				t.Fatal("descendant upload remained active after mutation")
			}
			if err := os.MkdirAll(filepath.Join(scope, "dir"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(scope, "dir", "partial"), []byte("saved"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := remove(); err != nil {
				t.Fatal(err)
			}
			content, err := os.ReadFile(filepath.Join(scope, "dir", "partial"))
			if err != nil || string(content) != "saved" {
				t.Fatalf("replacement = %q, %v", content, err)
			}
		})
	}
}

func TestDirectoryCopyRetiresUploadsThroughDestinationHardlinks(t *testing.T) {
	scope := t.TempDir()
	key := []byte("copy-hardlink")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	memory := newMemoryUploadCache()
	t.Cleanup(memory.Close)
	cache := &capturedUploadCache{UploadCache: memory}
	request := func(method, path string, handler handleFunc) int {
		req := httptest.NewRequest(method, path, nil)
		req.Header.Set("X-Auth", signToken(t, perm, key))
		req.Header.Set("Upload-Length", "8")
		rec := httptest.NewRecorder()
		handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
		return rec.Code
	}
	if status := request(http.MethodPost, "/outside/upload.txt", tusPostHandler(cache)); status != http.StatusCreated {
		t.Fatalf("create = %d", status)
	}
	remove := cache.removal()
	for _, dir := range []string{"source", "dest"} {
		if err := os.Mkdir(filepath.Join(scope, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(scope, "source", "alias.txt"), []byte("copied"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(scope, "outside", "upload.txt"), filepath.Join(scope, "dest", "alias.txt")); err != nil {
		t.Skip(err)
	}
	if status := request(http.MethodPatch, "/source?action=copy&destination=/dest&override=true", resourcePatchHandler(diskcache.NewNoOp())); status != http.StatusOK {
		t.Fatalf("copy = %d", status)
	}
	if err := remove(); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"outside/upload.txt", "dest/alias.txt"} {
		content, err := os.ReadFile(filepath.Join(scope, path))
		if err != nil || string(content) != "copied" {
			t.Fatalf("%s = %q, %v", path, content, err)
		}
	}
}

func TestDirectoryCopyPreservesUnmatchedUploadAndSymlink(t *testing.T) {
	scope := t.TempDir()
	key := []byte("copy-merge")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	memory := newMemoryUploadCache()
	t.Cleanup(memory.Close)
	cache := &capturedUploadCache{UploadCache: memory}
	request := func(method, path string, body []byte, headers map[string]string, handler handleFunc) int {
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		req.Header.Set("X-Auth", signToken(t, perm, key))
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
		return rec.Code
	}
	if status := request(http.MethodPost, "/dest/unrelated", nil, map[string]string{"Upload-Length": "8"}, tusPostHandler(cache)); status != http.StatusCreated {
		t.Fatalf("create = %d", status)
	}
	remove := cache.removal()
	if err := os.Mkdir(filepath.Join(scope, "source"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scope, "source", "copied"), []byte("saved"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(t.TempDir(), "outside"), filepath.Join(scope, "dest", "untouched")); err != nil {
		t.Skip(err)
	}
	if status := request(http.MethodPatch, "/source?action=copy&destination=/dest&override=true", nil, nil, resourcePatchHandler(diskcache.NewNoOp())); status != http.StatusOK {
		t.Fatalf("copy = %d", status)
	}
	if status := request(http.MethodPatch, "/dest/unrelated", []byte("part"), map[string]string{"Content-Type": "application/offset+octet-stream", "Upload-Offset": "0"}, tusPatchHandler(cache)); status != http.StatusNoContent {
		t.Fatalf("unrelated upload no longer resumable: %d", status)
	}
	if err := remove(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(scope, "dest", "unrelated")); !os.IsNotExist(err) {
		t.Fatalf("unrelated abandoned partial lost ownership: %v", err)
	}
	content, err := os.ReadFile(filepath.Join(scope, "dest", "copied"))
	if err != nil || string(content) != "saved" {
		t.Fatalf("copied content = %q, %v", content, err)
	}
	if _, err := os.Lstat(filepath.Join(scope, "dest", "untouched")); err != nil {
		t.Fatalf("untouched symlink changed: %v", err)
	}
}

// Run by the commands runner in a child test process, with a bounded HTTP
// timeout so a regression reports a failure instead of hanging the suite.
func TestUploadReentrantHookHelper(t *testing.T) {
	if len(os.Args) >= 4 && os.Args[len(os.Args)-3] == "hardlink" {
		if err := os.Link(os.Args[len(os.Args)-2], os.Args[len(os.Args)-1]); err != nil {
			t.Fatal(err)
		}
		return
	}

	if len(os.Args) < 3 || !strings.HasPrefix(os.Args[len(os.Args)-2], "http://") {
		return
	}
	req, err := http.NewRequest(http.MethodPut, os.Args[len(os.Args)-2], strings.NewReader("hook"))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Auth", os.Args[len(os.Args)-1])
	client := &http.Client{Timeout: 2 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = res.Body.Close() }()
	_, _ = io.Copy(io.Discard, res.Body)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("nested save = %d", res.StatusCode)
	}
}

func TestUploadHooksCanReenterResourceMutations(t *testing.T) {
	scope := t.TempDir()
	key := []byte("reentrant-hook")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	if err := os.WriteFile(filepath.Join(scope, "file"), []byte("initial"), 0o644); err != nil {
		t.Fatal(err)
	}
	nested := httptest.NewServer(handle(resourcePutHandler, "", st, &settings.Server{}))
	t.Cleanup(nested.Close)
	token := signToken(t, perm, key)
	command := fmt.Sprintf("%q -test.run=^TestUploadReentrantHookHelper$ -- %q %q", os.Args[0], nested.URL+"/file", token)
	if err := st.Settings.Save(&settings.Settings{Key: key, Commands: map[string][]string{"before_save": {command}, "after_copy": {command}}}); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPut, "/file", strings.NewReader("saved"))
	req.Header.Set("X-Auth", token)
	rec := httptest.NewRecorder()
	handle(resourcePutHandler, "", st, &settings.Server{EnableExec: true}).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("save with reentrant before hook = %d: %s", rec.Code, rec.Body.String())
	}
	copyReq := httptest.NewRequest(http.MethodPatch, "/file?action=copy&destination=/copy", nil)
	copyReq.Header.Set("X-Auth", token)
	copyRec := httptest.NewRecorder()
	handle(resourcePatchHandler(diskcache.NewNoOp()), "", st, &settings.Server{EnableExec: true}).ServeHTTP(copyRec, copyReq)
	if copyRec.Code != http.StatusOK {
		t.Fatalf("copy with reentrant after hook = %d: %s", copyRec.Code, copyRec.Body.String())
	}
	content, err := os.ReadFile(filepath.Join(scope, "copy"))
	if err != nil || string(content) != "saved" {
		t.Fatalf("copy = %q, %v", content, err)
	}
}

func TestUploadCacheCloseForgetsGeneration(t *testing.T) {
	scope := t.TempDir()
	key := []byte("close-generation")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	cache := newMemoryUploadCache()
	req := httptest.NewRequest(http.MethodPost, "/partial", nil)
	req.Header.Set("X-Auth", signToken(t, perm, key))
	req.Header.Set("Upload-Length", "8")
	rec := httptest.NewRecorder()
	handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		cache.Close()
		t.Fatalf("create = %d", rec.Code)
	}
	remove := cache.cache.Get(cache.cache.Keys()[0]).Value().remove
	cache.Close()
	uploadMutations.entries.Range(func(_, value any) bool {
		if value.(*uploadGeneration).owner == cache {
			t.Error("closed cache generation retained")
		}
		return true
	})
	if err := remove(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(scope, "partial")); err != nil {
		t.Fatalf("Close deleted file: %v", err)
	}
}

func TestUploadCleanupRejectsAncestorSymlinkScopeEscape(t *testing.T) {
	scope := t.TempDir()
	outside := t.TempDir()
	key := []byte("cleanup-scope")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	st.Users.(*customFSUser).fs = files.NewScopedFs(afero.NewOsFs(), scope)
	memory := newMemoryUploadCache()
	t.Cleanup(memory.Close)
	cache := &capturedUploadCache{UploadCache: memory}
	req := httptest.NewRequest(http.MethodPost, "/dir/partial", nil)
	req.Header.Set("X-Auth", signToken(t, perm, key))
	req.Header.Set("Upload-Length", "8")
	rec := httptest.NewRecorder()
	handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d", rec.Code)
	}
	remove := cache.removal()
	// Match the owned inode outside scope too, so identity checks alone cannot
	// mask a regression that follows the swapped ancestor out of scope.
	if err := os.Link(filepath.Join(scope, "dir", "partial"), filepath.Join(outside, "partial")); err != nil {
		t.Skip(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "partial"), []byte("victim"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(scope, "dir"), filepath.Join(scope, "owned")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(scope, "dir")); err != nil {
		t.Skip(err)
	}
	if err := remove(); err == nil {
		t.Fatal("cleanup accepted an out-of-scope ancestor")
	}
	content, err := os.ReadFile(filepath.Join(outside, "partial"))
	if err != nil || string(content) != "victim" {
		t.Fatalf("outside file changed: %q, %v", content, err)
	}
}

func TestCopyHookAliasRecheckReturnsBadRequest(t *testing.T) {
	scope := t.TempDir()
	key := []byte("copy-hook-alias")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	source := filepath.Join(scope, "source")
	destination := filepath.Join(scope, "alias")
	if err := os.WriteFile(source, []byte("preserved"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Preflight hardlink support before using it from the commands subprocess.
	if err := os.Link(source, destination); err != nil {
		t.Skip(err)
	}
	if err := os.Remove(destination); err != nil {
		t.Fatal(err)
	}
	command := fmt.Sprintf("%q -test.run=^TestUploadReentrantHookHelper$ -- hardlink %q %q", os.Args[0], source, destination)
	if err := st.Settings.Save(&settings.Settings{Key: key, Commands: map[string][]string{"before_copy": {command}}}); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPatch, "/source?action=copy&destination=/alias&override=true", nil)
	req.Header.Set("X-Auth", signToken(t, perm, key))
	rec := httptest.NewRecorder()
	handle(resourcePatchHandler(diskcache.NewNoOp()), "", st, &settings.Server{EnableExec: true}).ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("copy after alias hook = %d: %s", rec.Code, rec.Body.String())
	}
	content, err := os.ReadFile(source)
	if err != nil || string(content) != "preserved" {
		t.Fatalf("source = %q, %v", content, err)
	}
}

// heldCopyFs blocks an actual copy destination while its handler owns the
// exclusive mutation barrier, without blocking unrelated upload inspection.
type heldCopyFs struct {
	afero.Fs
	target  string
	entered chan struct{}
	release chan struct{}
}

func (f heldCopyFs) OpenFile(path string, flag int, mode os.FileMode) (afero.File, error) {
	if path == f.target {
		close(f.entered)
		<-f.release
	}
	return f.Fs.OpenFile(path, flag, mode)
}

type touchedUploadCache struct {
	*memoryUploadCache
	touched chan string
}

func (c *touchedUploadCache) Touch(ctx context.Context, key string) {
	c.memoryUploadCache.Touch(ctx, key)
	select {
	case c.touched <- key:
	default:
	}
}

func TestPatchKeepsUploadActiveWhileDirectoryCopyWaits(t *testing.T) {
	for _, alias := range []string{"direct", "hardlink", "symlink"} {
		t.Run(alias, func(t *testing.T) {
			scope := t.TempDir()
			key := []byte("waiting-upload")
			perm := users.Permissions{Create: true, Modify: true}
			st := scopedUserStorage(t, scope, perm, key)
			entered, release := make(chan struct{}), make(chan struct{})
			var releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(release) }) }
			defer unblock()
			st.Users.(*customFSUser).fs = afero.NewBasePathFs(heldCopyFs{Fs: afero.NewOsFs(), target: filepath.Join(scope, "dest", "held"), entered: entered, release: release}, scope)
			memory := newMemoryUploadCache()
			t.Cleanup(memory.Close)
			cache := &touchedUploadCache{memoryUploadCache: memory, touched: make(chan string, 16)}
			request := func(method, path string, body []byte, handler handleFunc) *httptest.ResponseRecorder {
				req := httptest.NewRequest(method, path, bytes.NewReader(body))
				req.Header.Set("X-Auth", signToken(t, perm, key))
				req.Header.Set("Upload-Length", "8")
				req.Header.Set("Upload-Offset", "0")
				req.Header.Set("Content-Type", "application/offset+octet-stream")
				rec := httptest.NewRecorder()
				handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
				return rec
			}
			if rec := request(http.MethodPost, "/partial", nil, tusPostHandler(cache)); rec.Code != http.StatusCreated {
				t.Fatalf("create = %d", rec.Code)
			}
			path := "/partial"
			if alias != "direct" {
				var err error
				if alias == "hardlink" {
					err = os.Link(filepath.Join(scope, "partial"), filepath.Join(scope, "alias"))
				} else {
					err = os.Symlink("partial", filepath.Join(scope, "alias"))
				}
				if err != nil {
					t.Skip(err)
				}
				path = "/alias"
			}
			cacheKey := memory.cache.Keys()[0]
			item := memory.cache.Get(cacheKey)
			memory.cache.Set(cacheKey, item.Value(), 3*time.Second)
			if err := os.Mkdir(filepath.Join(scope, "source"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(scope, "source", "held"), []byte("copy"), 0o644); err != nil {
				t.Fatal(err)
			}
			copyDone := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				copyDone <- request(http.MethodPatch, "/source?action=copy&destination=/dest", nil, resourcePatchHandler(diskcache.NewNoOp()))
			}()
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("directory copy did not acquire barrier")
			}
			patchDone := make(chan *httptest.ResponseRecorder, 1)
			go func() { patchDone <- request(http.MethodPatch, path, []byte("part"), tusPatchHandler(cache)) }()
			select {
			case touched := <-cache.touched:
				if touched != cacheKey {
					t.Fatalf("touch key = %q, registered %q", touched, cacheKey)
				}
			case <-time.After(time.Second):
				t.Fatal("PATCH did not refresh before waiting")
			}
			// Longer than the entry's TTL, with no cache reads that refresh it.
			select {
			case rec := <-patchDone:
				t.Fatalf("PATCH escaped held copy: %d", rec.Code)
			case <-time.After(4 * time.Second):
			}
			if memory.cache.Get(cacheKey, ttlcache.WithDisableTouchOnHit[string, memoryUploadEntry]()) == nil {
				t.Fatal("admitted waiting upload expired")
			}
			unblock()
			if rec := <-copyDone; rec.Code != http.StatusOK {
				t.Fatalf("copy = %d: %s", rec.Code, rec.Body.String())
			}
			if rec := <-patchDone; rec.Code != http.StatusNoContent {
				t.Fatalf("PATCH = %d: %s", rec.Code, rec.Body.String())
			}
			content, err := os.ReadFile(filepath.Join(scope, "partial"))
			if err != nil || string(content) != "part" {
				t.Fatalf("resumed partial = %q, %v", content, err)
			}
		})
	}
}

func TestUploadKeepaliveStopsOnCancellationOrRetirement(t *testing.T) {
	for _, reason := range []string{"cancel", "retire"} {
		t.Run(reason, func(t *testing.T) {
			memory := newMemoryUploadCache()
			t.Cleanup(memory.Close)
			cache := &touchedUploadCache{memoryUploadCache: memory, touched: make(chan string, 16)}
			key := filepath.Join(t.TempDir(), "upload")
			generation := &uploadGeneration{cache: cache, cacheKey: key, owner: memory}
			uploadMutations.entries.Store(key, generation)
			memory.Register(context.Background(), key, 8, nil)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			stop := keepUploadActive(ctx, cache, key, key, generation)
			defer stop()
			<-cache.touched // synchronous initial refresh
			if reason == "cancel" {
				cancel()
			} else {
				uploadMutations.entries.Delete(key)
			}
			// Neither cancellation nor retirement may refresh a later entry.
			memory.Register(context.Background(), key, 9, nil)
			select {
			case <-cache.touched:
				t.Fatal("stopped upload worker touched cache")
			case <-time.After(2200 * time.Millisecond):
			}
		})
	}
}

func TestInvalidPatchDoesNotStartKeepalive(t *testing.T) {
	for _, kind := range []string{"permission", "content-type", "offset-header", "offset-exceeds-length", "offset-conflict", "absent"} {
		t.Run(kind, func(t *testing.T) {
			scope := t.TempDir()
			key := []byte("invalid-waiting-patch")
			perm := users.Permissions{Create: true, Modify: true}
			st := scopedUserStorage(t, scope, perm, key)
			memory := newMemoryUploadCache()
			t.Cleanup(memory.Close)
			cache := &touchedUploadCache{memoryUploadCache: memory, touched: make(chan string, 16)}
			post := httptest.NewRequest(http.MethodPost, "/partial", nil)
			post.Header.Set("X-Auth", signToken(t, perm, key))
			post.Header.Set("Upload-Length", "8")
			rec := httptest.NewRecorder()
			handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, post)
			if rec.Code != http.StatusCreated {
				t.Fatalf("create = %d", rec.Code)
			}
			patch := httptest.NewRequest(http.MethodPatch, "/partial", strings.NewReader("part"))
			patch.Header.Set("Content-Type", "application/offset+octet-stream")
			patch.Header.Set("Upload-Offset", "0")
			want := http.StatusBadRequest
			switch kind {
			case "permission":
				user, err := st.Users.Get("", false, uint(1))
				if err != nil {
					t.Fatal(err)
				}
				user.Perm.Create = false
				if err := st.Users.Save(user); err != nil {
					t.Fatal(err)
				}
				perm.Create = false
				want = http.StatusForbidden
			case "content-type":
				patch.Header.Set("Content-Type", "text/plain")
				want = http.StatusUnsupportedMediaType
			case "offset-header":
				patch.Header.Set("Upload-Offset", "bad")
			case "offset-exceeds-length":
				patch.Header.Set("Upload-Offset", "9")
			case "offset-conflict":
				patch.Header.Set("Upload-Offset", "1")
				want = http.StatusConflict
			case "absent":
				memory.Complete(context.Background(), memory.cache.Keys()[0])
				want = http.StatusNotFound
			}
			patch.Header.Set("X-Auth", signToken(t, perm, key))
			rec = httptest.NewRecorder()
			handle(tusPatchHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, patch)
			if rec.Code != want {
				t.Fatalf("PATCH = %d, want %d: %s", rec.Code, want, rec.Body.String())
			}
			select {
			case touched := <-cache.touched:
				t.Fatalf("invalid PATCH started keepalive for %q", touched)
			default:
			}
		})
	}
}

// pausedPatchCache exposes the two pre-lock windows without depending on
// scheduler ordering or an upload expiry timer.
type pausedPatchCache struct {
	*memoryUploadCache
	phase            string
	entered, release chan struct{}
	once             sync.Once
}

func (c *pausedPatchCache) pause(phase string) {
	if c.phase == phase {
		c.once.Do(func() { close(c.entered); <-c.release })
	}
}

func (c *pausedPatchCache) GetLength(ctx context.Context, key string) (int64, error) {
	length, err := c.memoryUploadCache.GetLength(ctx, key)
	c.pause("validation")
	return length, err
}

func (c *pausedPatchCache) Touch(ctx context.Context, key string) {
	c.pause("keepalive")
	c.memoryUploadCache.Touch(ctx, key)
}

func TestPatchPinsAdmittedGeneration(t *testing.T) {
	for _, phase := range []string{"validation", "keepalive"} {
		for _, alias := range []string{"direct", "hardlink", "symlink"} {
			for _, mutation := range []string{"replacement", "save", "delete", "unchanged"} {
				t.Run(phase+"/"+alias+"/"+mutation, func(t *testing.T) {
					scope := t.TempDir()
					key := []byte("pinned-upload")
					perm := users.Permissions{Create: true, Modify: true, Delete: true}
					st := scopedUserStorage(t, scope, perm, key)
					memory := newMemoryUploadCache()
					t.Cleanup(memory.Close)
					cache := &pausedPatchCache{memoryUploadCache: memory, phase: phase, entered: make(chan struct{}), release: make(chan struct{})}
					var releaseOnce sync.Once
					unblock := func() { releaseOnce.Do(func() { close(cache.release) }) }
					defer unblock()
					request := func(method, path string, body []byte, handler handleFunc) *httptest.ResponseRecorder {
						req := httptest.NewRequest(method, path, bytes.NewReader(body))
						req.Header.Set("X-Auth", signToken(t, perm, key))
						req.Header.Set("Upload-Length", "8")
						req.Header.Set("Upload-Offset", "0")
						req.Header.Set("Content-Type", "application/offset+octet-stream")
						rec := httptest.NewRecorder()
						handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
						return rec
					}
					if rec := request(http.MethodPost, "/partial", nil, tusPostHandler(cache)); rec.Code != http.StatusCreated {
						t.Fatalf("create = %d", rec.Code)
					}
					cacheKey := memory.cache.Keys()[0]
					path := "/partial"
					if alias != "direct" {
						var err error
						if alias == "hardlink" {
							err = os.Link(filepath.Join(scope, "partial"), filepath.Join(scope, "alias"))
						} else {
							err = os.Symlink("partial", filepath.Join(scope, "alias"))
						}
						if err != nil {
							t.Skip(err)
						}
						path = "/alias"
					}
					done := make(chan *httptest.ResponseRecorder, 1)
					go func() { done <- request(http.MethodPatch, path, []byte("old!"), tusPatchHandler(cache)) }()
					select {
					case <-cache.entered:
					case <-time.After(3 * time.Second):
						t.Fatal("PATCH did not reach pre-lock pause")
					}
					wantContent := ""
					switch mutation {
					case "replacement":
						if rec := request(http.MethodPost, "/partial?override=true", nil, tusPostHandler(cache)); rec.Code != http.StatusCreated {
							t.Fatalf("replacement = %d", rec.Code)
						}
					case "save":
						wantContent = "saved"
						if rec := request(http.MethodPut, "/partial", []byte(wantContent), resourcePutHandler); rec.Code != http.StatusOK {
							t.Fatalf("save = %d: %s", rec.Code, rec.Body.String())
						}
					case "delete":
						// Use the ordinary delete handler, which does not inspect this cache.
						if rec := request(http.MethodDelete, "/partial", nil, resourceDeleteHandler(diskcache.NewNoOp())); rec.Code != http.StatusNoContent {
							t.Fatalf("delete = %d: %s", rec.Code, rec.Body.String())
						}
					case "unchanged":
						wantContent = "old!"
					}
					unblock()
					var rec *httptest.ResponseRecorder
					select {
					case rec = <-done:
					case <-time.After(3 * time.Second):
						t.Fatal("PATCH did not finish")
					}
					wantStatus := http.StatusNotFound
					if mutation == "unchanged" {
						wantStatus = http.StatusNoContent
					}
					if rec.Code != wantStatus {
						t.Fatalf("PATCH = %d, want %d: %s", rec.Code, wantStatus, rec.Body.String())
					}
					content, err := os.ReadFile(filepath.Join(scope, "partial"))
					if mutation == "delete" {
						if !os.IsNotExist(err) {
							t.Fatalf("deleted file = %q, %v", content, err)
						}
					} else if err != nil || string(content) != wantContent {
						t.Fatalf("file = %q, %v; want %q", content, err, wantContent)
					}
					if mutation == "replacement" {
						// The rejected PATCH must not complete or invalidate the fresh entry.
						if length, err := memory.GetLength(context.Background(), cacheKey); err != nil || length != 8 {
							t.Fatalf("replacement upload = %d, %v", length, err)
						}
					}
				})
			}
		}
	}
}

// replacingAppendFs swaps the path only when PATCH opens its final write handle,
// after both metadata inspections have succeeded.
type replacingAppendFs struct {
	afero.Fs
	replace func() error
}

func (f *replacingAppendFs) OpenFile(path string, flag int, mode os.FileMode) (afero.File, error) {
	if flag&os.O_APPEND != 0 && f.replace != nil {
		if err := f.replace(); err != nil {
			return nil, err
		}
	}
	return f.Fs.OpenFile(path, flag, mode)
}

func TestPatchRequiresOwnedFileIdentity(t *testing.T) {
	for _, alias := range []string{"direct", "symlink", "hardlink"} {
		for _, mutation := range []string{"native rename", "external replacement", "replacement at open", "unchanged"} {
			t.Run(alias+"/"+mutation, func(t *testing.T) {
				scope := t.TempDir()
				key := []byte("owned-file-identity")
				perm := users.Permissions{Create: true, Modify: true, Rename: true}
				st := scopedUserStorage(t, scope, perm, key)
				fs := &replacingAppendFs{Fs: afero.NewOsFs()}
				st.Users.(*customFSUser).fs = afero.NewBasePathFs(fs, scope)
				memory := newMemoryUploadCache()
				t.Cleanup(memory.Close)
				cache := &capturedUploadCache{UploadCache: memory}
				request := func(method, path string, body []byte, handler handleFunc) int {
					t.Helper()
					req := httptest.NewRequest(method, path, bytes.NewReader(body))
					req.Header.Set("X-Auth", signToken(t, perm, key))
					req.Header.Set("Upload-Length", "8")
					req.Header.Set("Upload-Offset", "0")
					req.Header.Set("Content-Type", "application/offset+octet-stream")
					rec := httptest.NewRecorder()
					handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
					return rec.Code
				}
				target := filepath.Join(scope, "target")
				if err := os.WriteFile(target, nil, 0o600); err != nil {
					t.Fatal(err)
				}
				path := "/target"
				if alias != "direct" {
					var err error
					if alias == "symlink" {
						err = os.Symlink("target", filepath.Join(scope, "alias"))
					} else {
						err = os.Link(target, filepath.Join(scope, "alias"))
					}
					if err != nil {
						t.Skip(err)
					}
					path = "/alias"
				}
				if status := request(http.MethodPost, path+"?override=true", nil, tusPostHandler(cache)); status != http.StatusCreated {
					t.Fatalf("create upload = %d", status)
				}
				remove := cache.removal()
				if err := os.WriteFile(filepath.Join(scope, "source"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
				wantStatus := http.StatusNotFound
				savedPath := target
				switch mutation {
				case "native rename":
					if status := request(http.MethodPatch, "/source?action=rename&destination=/target&override=true", nil, resourcePatchHandler(diskcache.NewNoOp())); status != http.StatusOK {
						t.Fatalf("rename = %d", status)
					}
				case "external replacement":
					if err := os.Rename(filepath.Join(scope, "source"), target); err != nil {
						t.Fatal(err)
					}
				case "replacement at open":
					if alias == "hardlink" {
						savedPath = filepath.Join(scope, "alias")
					}
					fs.replace = func() error { return os.Rename(filepath.Join(scope, "source"), savedPath) }
				case "unchanged":
					wantStatus = http.StatusNoContent
				}
				// Replacing target unlinks only one hardlink: an upload through the
				// other link still owns its original inode and must remain resumable.
				if alias == "hardlink" && mutation != "replacement at open" {
					wantStatus = http.StatusNoContent
				}
				if status := request(http.MethodPatch, path, []byte("old!"), tusPatchHandler(cache)); status != wantStatus {
					t.Fatalf("PATCH = %d, want %d", status, wantStatus)
				}
				content, err := os.ReadFile(filepath.Join(scope, path))
				wantContent := ""
				if wantStatus == http.StatusNoContent {
					wantContent = "old!"
				}
				if err != nil || string(content) != wantContent {
					t.Fatalf("PATCH path = %q, %v; want %q", content, err, wantContent)
				}
				if mutation != "unchanged" {
					if err := remove(); err != nil {
						t.Fatal(err)
					}
					content, err = os.ReadFile(savedPath)
					if err != nil || len(content) != 0 {
						t.Fatalf("saved replacement after stale cleanup = %q, %v", content, err)
					}
				}
			})
		}
	}
}

func TestPatchPreservesVirtualFilesystemUploads(t *testing.T) {
	key := []byte("virtual-upload")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, t.TempDir(), perm, key)
	fs := afero.NewMemMapFs()
	st.Users.(*customFSUser).fs = fs
	cache := newMemoryUploadCache()
	t.Cleanup(cache.Close)
	request := func(method, body, offset string, handler handleFunc) int {
		t.Helper()
		req := httptest.NewRequest(method, "/partial", strings.NewReader(body))
		req.Header.Set("X-Auth", signToken(t, perm, key))
		req.Header.Set("Upload-Length", "8")
		req.Header.Set("Upload-Offset", offset)
		req.Header.Set("Content-Type", "application/offset+octet-stream")
		rec := httptest.NewRecorder()
		handle(handler, "", st, &settings.Server{}).ServeHTTP(rec, req)
		return rec.Code
	}
	if status := request(http.MethodPost, "", "0", tusPostHandler(cache)); status != http.StatusCreated {
		t.Fatalf("create upload = %d", status)
	}
	info, err := fs.Stat("/partial")
	if err != nil {
		t.Fatal(err)
	}
	if os.SameFile(info, info) {
		t.Fatal("virtual filesystem unexpectedly supports stable file identity")
	}
	for _, chunk := range []struct{ body, offset string }{{"part", "0"}, {"rest", "4"}} {
		if status := request(http.MethodPatch, chunk.body, chunk.offset, tusPatchHandler(cache)); status != http.StatusNoContent {
			t.Fatalf("PATCH offset %s = %d", chunk.offset, status)
		}
	}
	content, err := afero.ReadFile(fs, "/partial")
	if err != nil || string(content) != "partrest" {
		t.Fatalf("virtual upload = %q, %v", content, err)
	}
	if keys := cache.cache.Keys(); len(keys) != 0 {
		t.Fatalf("completed upload still registered: %v", keys)
	}
}
