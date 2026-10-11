package fbhttp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

type shortLivedUploadCache struct {
	*memoryUploadCache
	mu       sync.Mutex
	removals []func() error
	expired  chan struct{}
}

func (c *shortLivedUploadCache) Register(_ context.Context, key string, size int64, remove func() error) {
	c.mu.Lock()
	c.removals = append(c.removals, remove)
	c.mu.Unlock()
	c.cache.Set(key, memoryUploadEntry{size: size, remove: func() error {
		err := remove()
		if filepath.Base(key) == "partial" {
			c.expired <- struct{}{}
		}
		return err
	}}, 40*time.Millisecond)
}

func TestTusZeroLengthCreationSurvivesExpiry(t *testing.T) {
	scope := t.TempDir()
	key := []byte("empty-upload")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	cache := &shortLivedUploadCache{memoryUploadCache: newMemoryUploadCache(), expired: make(chan struct{}, 8)}
	t.Cleanup(cache.Close)
	server := &settings.Server{BaseURL: "/base/"}
	post := handle(tusPostHandler(cache), "/base/api/tus", st, server)
	head := handle(tusHeadHandler(cache), "/base/api/tus", st, server)
	patch := handle(tusPatchHandler(cache), "/base/api/tus", st, server)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			post.ServeHTTP(w, r)
		case http.MethodHead:
			head.ServeHTTP(w, r)
		case http.MethodPatch:
			patch.ServeHTTP(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	token := signToken(t, perm, key)
	request := func(method, path, length string) *http.Response {
		t.Helper()
		req, err := http.NewRequest(method, srv.URL+path, http.NoBody)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("X-Auth", token)
		req.Header.Set("Upload-Length", length)
		req.Header.Set("Upload-Offset", "0")
		req.Header.Set("Content-Type", "application/offset+octet-stream")
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
		return res
	}
	// Retain an already-dispatched callback from a prior upload at this path.
	path := "/base/api/tus/new/empty%20file.txt"
	if res := request(http.MethodPost, path, "5"); res.StatusCode != http.StatusCreated {
		t.Fatalf("initial POST = %d", res.StatusCode)
	}
	cache.mu.Lock()
	staleRemove := cache.removals[0]
	cache.mu.Unlock()
	res := request(http.MethodPost, path+"?override=true", "0")
	if res.StatusCode != http.StatusCreated || res.Header.Get("Location") != path {
		t.Fatalf("empty POST = %d, Location %q", res.StatusCode, res.Header.Get("Location"))
	}
	cache.mu.Lock()
	registered := len(cache.removals)
	cache.mu.Unlock()
	if registered != 1 || len(cache.cache.Items()) != 0 {
		t.Fatal("empty upload registered eviction ownership")
	}
	if err := staleRemove(); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{http.MethodHead, http.MethodPatch} {
		if res := request(method, path, ""); res.StatusCode != http.StatusNotFound {
			t.Fatalf("completed %s = %d", method, res.StatusCode)
		}
	}
	// A real expired incomplete upload establishes that the production eviction
	// worker has run; the finished empty file must survive the same interval.
	if res := request(http.MethodPost, "/base/api/tus/partial", "1"); res.StatusCode != http.StatusCreated {
		t.Fatalf("partial POST = %d", res.StatusCode)
	}
	select {
	case <-cache.expired:
	case <-time.After(2 * time.Second):
		t.Fatal("partial upload did not expire")
	}
	if _, err := os.Stat(filepath.Join(scope, "partial")); !os.IsNotExist(err) {
		t.Fatalf("expired partial upload retained: %v", err)
	}
	info, err := os.Stat(filepath.Join(scope, "new", "empty file.txt"))
	if err != nil || info.Size() != 0 {
		t.Fatalf("completed empty file: %v, %v", info, err)
	}
}

func TestTusZeroLengthCreationPermissions(t *testing.T) {
	for _, tc := range []struct {
		name     string
		perm     users.Permissions
		override bool
		want     int
	}{
		{"conflict", users.Permissions{Create: true, Modify: true}, false, http.StatusConflict},
		{"no modify", users.Permissions{Create: true}, true, http.StatusForbidden},
		{"no create", users.Permissions{Modify: true}, true, http.StatusForbidden},
		{"override", users.Permissions{Create: true, Modify: true}, true, http.StatusCreated},
	} {
		t.Run(tc.name, func(t *testing.T) {
			scope := t.TempDir()
			name := filepath.Join(scope, "file")
			if err := os.WriteFile(name, []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
			key := []byte("empty-permission")
			st := scopedUserStorage(t, scope, tc.perm, key)
			cache := newMemoryUploadCache()
			t.Cleanup(cache.Close)
			req := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/file?override=%t", tc.override), http.NoBody)
			req.Header.Set("X-Auth", signToken(t, tc.perm, key))
			req.Header.Set("Upload-Length", "0")
			rec := httptest.NewRecorder()
			handle(tusPostHandler(cache), "", st, &settings.Server{}).ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
			}
			got, err := os.ReadFile(name)
			want := "keep"
			if tc.want == http.StatusCreated {
				want = ""
			}
			if err != nil || string(got) != want {
				t.Fatalf("file = %q, %v", got, err)
			}
			if len(cache.cache.Items()) != 0 {
				t.Fatal("empty or rejected upload registered")
			}
		})
	}
}

func TestTusZeroLengthHookHelper(t *testing.T) {
	if len(os.Args) < 5 || os.Args[len(os.Args)-4] != "empty-hook" {
		return
	}
	req, err := http.NewRequest(http.MethodPut, os.Args[len(os.Args)-3], strings.NewReader("hook"))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Auth", os.Args[len(os.Args)-2])
	client := &http.Client{Timeout: 2 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, res.Body)
	_ = res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("nested API mutation = %d", res.StatusCode)
	}
	file, err := os.OpenFile(os.Args[len(os.Args)-1], os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer func(closeResource func() error) { _ = closeResource() }(file.Close)
	if _, err := file.WriteString("hook\n"); err != nil {
		t.Fatal(err)
	}
}

func TestTusZeroLengthHookCompletesOnceOutsideMutationLock(t *testing.T) {
	scope := t.TempDir()
	key := []byte("empty-hook")
	perm := users.Permissions{Create: true, Modify: true}
	st := scopedUserStorage(t, scope, perm, key)
	if err := os.WriteFile(filepath.Join(scope, "nested"), []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	nested := httptest.NewServer(handle(resourcePutHandler, "", st, &settings.Server{}))
	t.Cleanup(nested.Close)
	token := signToken(t, perm, key)
	marker := filepath.Join(t.TempDir(), "hook-count")
	command := fmt.Sprintf("%q -test.run=^TestTusZeroLengthHookHelper$ -- empty-hook %q %q %q", os.Args[0], nested.URL+"/nested", token, marker)
	if err := st.Settings.Save(&settings.Settings{Key: key, Commands: map[string][]string{"after_upload": {command}}}); err != nil {
		t.Fatal(err)
	}
	cache := newMemoryUploadCache()
	t.Cleanup(cache.Close)
	for _, tc := range []struct {
		method string
		want   int
	}{
		{http.MethodPost, http.StatusCreated},
		{http.MethodHead, http.StatusNotFound},
		{http.MethodPatch, http.StatusNotFound},
		{http.MethodPost, http.StatusConflict},
	} {
		req := httptest.NewRequest(tc.method, "/empty", http.NoBody)
		req.Header.Set("X-Auth", token)
		req.Header.Set("Upload-Length", "0")
		req.Header.Set("Upload-Offset", "0")
		req.Header.Set("Content-Type", "application/offset+octet-stream")
		rec := httptest.NewRecorder()
		handler := tusPostHandler(cache)
		switch tc.method {
		case http.MethodHead:
			handler = tusHeadHandler(cache)
		case http.MethodPatch:
			handler = tusPatchHandler(cache)
		}
		handle(handler, "", st, &settings.Server{EnableExec: true}).ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Fatalf("%s = %d: %s", tc.method, rec.Code, rec.Body.String())
		}
	}
	if got, err := os.ReadFile(marker); err != nil || string(got) != "hook\n" {
		t.Fatalf("hook calls = %q, %v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(scope, "nested")); err != nil || string(got) != "hook" {
		t.Fatalf("nested mutation = %q, %v", got, err)
	}
}
