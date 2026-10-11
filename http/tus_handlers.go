package fbhttp

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/spf13/afero"
)

// maxPatchDrainBytes bounds how much of a rejected PATCH body is discarded to
// keep the connection reusable. It comfortably covers a default-sized chunk;
// beyond that the body is not worth reading just to throw away.
const maxPatchDrainBytes = 32 << 20 // 32MB

// drainRequestBody discards what the client already put on the wire for a
// request the handler answered without reading. net/http only drains 256KiB on
// its own before giving up and closing the connection, and a connection closed
// while the client is still streaming a chunk reaches the browser as a transport
// error instead of the status we replied with. The client then cannot tell a
// conflict from a network fault, retries blindly, and the upload stalls.
func drainRequestBody(r *http.Request) {
	if r.Body == nil {
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, maxPatchDrainBytes))
}

// keepUploadActive refreshes an admitted upload while waiting for a mutation
// lock and transferring data. Retirement and cancellation stop the worker even
// if the handler is still waiting for the lock.
func keepUploadActive(ctx context.Context, cache UploadCache, cacheKey, key string, generation *uploadGeneration) func() {
	if _, local := cache.(interface{ uploadCacheOwner() *memoryUploadCache }); local && generation == nil {
		return func() {}
	}
	stop := make(chan struct{})
	touch := func() bool {
		if ctx.Err() != nil {
			return false
		}
		if !patchGenerationCurrent(key, generation) {
			return false
		}
		cache.Touch(cacheKey)
		return true
	}
	// Refresh before blocking, rather than waiting for the first tick.
	if !touch() {
		return func() {}
	}
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-stop:
				return
			case <-ticker.C:
				if !touch() {
					return
				}
			}
		}
	}()
	return func() { close(stop) }
}

// tusPatchesInFlight holds the uploads that currently have a PATCH being
// written, keyed by the on-disk path of the upload.
//
// A PATCH checks that its offset matches the file size and then appends. Those
// two steps are not atomic, so several concurrent PATCHes at the same offset
// would all pass the check and all append, writing a multiple of the declared
// Upload-Length. Admitting one PATCH per upload at a time closes that window.
//
// The set is per process. Replicas sharing storage behind a Redis upload cache
// would each hold their own, so this does not serialize across replicas.
var tusPatchesInFlight sync.Map

// lockUpload claims the upload at key for one PATCH. It reports false, without
// waiting, when another PATCH already holds it: the TUS protocol has the client
// retry, re-reading the offset first. On success the returned function releases
// the claim.
func lockUpload(key string) (unlock func(), ok bool) {
	if _, busy := tusPatchesInFlight.LoadOrStore(key, struct{}{}); busy {
		return nil, false
	}
	return func() { tusPatchesInFlight.Delete(key) }, true
}

func tusPostHandler(cache UploadCache) handleFunc {
	return withUser(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
		if !d.user.Perm.Create || !d.Check(r.URL.Path) {
			return http.StatusForbidden, nil
		}

		uploadLength, err := getUploadLength(r)
		if err != nil {
			return http.StatusBadRequest, err
		}
		if uploadLength < 0 {
			return http.StatusBadRequest, fmt.Errorf("upload length must not be negative")
		}

		uploadMutations.barrier.Lock()
		defer uploadMutations.barrier.Unlock()
		key := uploadLockKey(d, r.URL.Path)

		file, err := files.NewFileInfo(&files.FileOptions{
			Fs:         d.user.Fs,
			Path:       r.URL.Path,
			Modify:     d.user.Perm.Modify,
			Expand:     false,
			ReadHeader: d.server.TypeDetectionByHeader,
			Checker:    d,
		})
		switch {
		case errors.Is(err, afero.ErrFileNotFound):
			dirPath := filepath.Dir(r.URL.Path)
			if _, statErr := d.user.Fs.Stat(dirPath); os.IsNotExist(statErr) {
				if mkdirErr := d.user.Fs.MkdirAll(dirPath, d.settings.DirMode); mkdirErr != nil {
					return http.StatusInternalServerError, mkdirErr
				}
			}
		case err != nil:
			return errToStatus(err), err
		}

		fileFlags := os.O_CREATE | os.O_WRONLY

		// if file exists
		if file != nil {
			if file.IsDir {
				return http.StatusBadRequest, fmt.Errorf("cannot upload to a directory %s", file.RealPath())
			}

			// Existing files will remain untouched unless explicitly instructed to override
			if r.URL.Query().Get("override") != "true" {
				return http.StatusConflict, nil
			}

			// Permission for overwriting the file
			if !d.user.Perm.Modify {
				return http.StatusForbidden, nil
			}

			fileFlags |= os.O_TRUNC
		}

		retireUpload(key)
		openFile, err := d.user.Fs.OpenFile(r.URL.Path, fileFlags, d.settings.FileMode)
		if err != nil {
			return errToStatus(err), err
		}
		defer openFile.Close()

		file, err = files.NewFileInfo(&files.FileOptions{
			Fs:         d.user.Fs,
			Path:       r.URL.Path,
			Modify:     d.user.Perm.Modify,
			Expand:     false,
			ReadHeader: false,
			Checker:    d,
			Content:    false,
		})
		if err != nil {
			return errToStatus(err), err
		}

		owned, err := openFile.Stat()
		if err != nil {
			return errToStatus(err), err
		}
		registerOwnedUpload(cache, key, uploadPathKey(d, r.URL.Path), file.RealPath(), uploadLength, d.user.Fs, r.URL.Path, owned)

		basePath := "/" + strings.Trim(strings.TrimSpace(d.server.BaseURL), "/")
		if basePath == "/" {
			basePath = ""
		}

		w.Header().Set("Location", basePath+"/api/tus"+r.URL.EscapedPath())
		return http.StatusCreated, nil
	})
}

func tusHeadHandler(cache UploadCache) handleFunc {
	return withUser(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
		w.Header().Set("Cache-Control", "no-store")
		if !d.user.Perm.Create || !d.Check(r.URL.Path) {
			return http.StatusForbidden, nil
		}

		file, err := files.NewFileInfo(&files.FileOptions{
			Fs:         d.user.Fs,
			Path:       r.URL.Path,
			Modify:     d.user.Perm.Modify,
			Expand:     false,
			ReadHeader: d.server.TypeDetectionByHeader,
			Checker:    d,
		})
		if err != nil {
			return errToStatus(err), err
		}

		uploadLength, err := cache.GetLength(file.RealPath())
		if err != nil {
			return http.StatusNotFound, err
		}

		w.Header().Set("Upload-Offset", strconv.FormatInt(file.Size, 10))
		w.Header().Set("Upload-Length", strconv.FormatInt(uploadLength, 10))

		return http.StatusOK, nil
	})
}

func tusPatchHandler(cache UploadCache) handleFunc {
	return withUser(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
		status, err := tusPatchUpload(w, r, d, cache)
		// A rejected chunk is still a chunk the client is streaming: read what is
		// left of it so the answer reaches the client on a connection that stays
		// usable, instead of being lost to a reset.
		if status >= 400 {
			drainRequestBody(r)
		}
		return status, err
	})
}

func tusPatchUpload(w http.ResponseWriter, r *http.Request, d *data, cache UploadCache) (int, error) {
	if !d.user.Perm.Create || !d.Check(r.URL.Path) {
		return http.StatusForbidden, nil
	}
	if r.Header.Get("Content-Type") != "application/offset+octet-stream" {
		return http.StatusUnsupportedMediaType, nil
	}

	uploadOffset, err := getUploadOffset(r)
	if err != nil {
		return http.StatusBadRequest, fmt.Errorf("invalid upload offset")
	}

	// Admit one PATCH before inspecting the upload. The mutation lock below
	// protects the final offset check and append from other file operations.
	originalKey := uploadLockKey(d, r.URL.Path)
	unlock, ok := lockUpload(originalKey)
	if !ok {
		return http.StatusLocked, fmt.Errorf("another chunk of %s is being written", r.URL.Path)
	}
	defer unlock()
	// Pin the generation before reading file/cache state. Loading it after
	// validation could adopt a replacement whose offset happens to match.
	var generation *uploadGeneration
	if value, ok := uploadMutations.entries.Load(originalKey); ok {
		generation = value.(*uploadGeneration)
	}
	uploadLength, cacheKey, status, err := inspectPatchUpload(d, r.URL.Path, cache, uploadOffset, generation)
	if status != 0 {
		return status, err
	}
	if _, local := cache.(interface{ uploadCacheOwner() *memoryUploadCache }); local && generation == nil {
		return http.StatusNotFound, nil
	}
	if !patchGenerationCurrent(originalKey, generation) {
		return http.StatusNotFound, nil
	}
	stop := keepUploadActive(r.Context(), cache, cacheKey, originalKey, generation)
	defer stop()

	key, unlockMutation := lockFileUploadMutation(d, r.URL.Path)
	defer func() {
		if unlockMutation != nil {
			unlockMutation()
		}
	}()
	if err := r.Context().Err(); err != nil {
		return http.StatusRequestTimeout, err
	}
	if key != originalKey || !patchGenerationCurrent(key, generation) {
		return http.StatusNotFound, nil
	}
	// The directory operation may have replaced or retired the file while we
	// waited. Recheck the original request offset under the mutation lock.
	uploadLength, cacheKey, status, err = inspectPatchUpload(d, r.URL.Path, cache, uploadOffset, generation)
	if status != 0 {
		return status, err
	}

	openFile, err := d.user.Fs.OpenFile(r.URL.Path, os.O_WRONLY|os.O_APPEND, d.settings.FileMode)
	if err != nil {
		return http.StatusInternalServerError, fmt.Errorf("could not open file: %w", err)
	}
	defer openFile.Close()
	// A path may have been replaced after inspection, including by a native
	// rename through a symlink target. Verify the handle we will actually write.
	openedInfo, err := openFile.Stat()
	if err != nil {
		return http.StatusInternalServerError, fmt.Errorf("could not stat opened upload: %w", err)
	}
	if !patchGenerationOwnsFile(generation, openedInfo) {
		return http.StatusNotFound, nil
	}

	_, err = openFile.Seek(uploadOffset, 0)
	if err != nil {
		return http.StatusInternalServerError, fmt.Errorf("could not seek file: %w", err)
	}

	// The server closes the request body once the handler returns; closing it
	// here would run before the caller gets to drain a rejected chunk, so every
	// status raised below this point would still cost the connection.
	//
	// Enforce the declared Upload-Length: never write more than the bytes
	// still expected for this upload. Reading one byte past the remainder
	// lets an over-length body be detected and rejected. Without this bound a
	// PATCH could stream arbitrary data to disk regardless of the length the
	// client declared when the upload was created.
	remaining := uploadLength - uploadOffset
	bytesWritten, err := io.Copy(openFile, io.LimitReader(r.Body, remaining+1))
	if err != nil {
		return http.StatusInternalServerError, fmt.Errorf("could not write to file: %w", err)
	}
	if bytesWritten > remaining {
		// The client sent more than it declared; roll this chunk back so the
		// file stays consistent with the tracked offset, and reject it.
		if truncErr := openFile.Truncate(uploadOffset); truncErr != nil {
			return http.StatusInternalServerError, fmt.Errorf("could not truncate file: %w", truncErr)
		}
		return http.StatusRequestEntityTooLarge, fmt.Errorf("upload exceeds declared length of %d bytes", uploadLength)
	}

	// Sync the file to ensure all data is written to storage
	// to prevent file corruption.
	if err := openFile.Sync(); err != nil {
		return http.StatusInternalServerError, fmt.Errorf("could not sync file: %w", err)
	}

	newOffset := uploadOffset + bytesWritten
	w.Header().Set("Upload-Offset", strconv.FormatInt(newOffset, 10))

	if newOffset >= uploadLength {
		retireUpload(key)
		cache.Complete(cacheKey)
		unlockMutation()
		unlockMutation = nil
		_ = d.RunHook(func() error { return nil }, "upload", r.URL.Path, "", d.user)
	}

	return http.StatusNoContent, nil
}

// inspectPatchUpload rejects invalid chunks before starting their keepalive.
// Call it again under the mutation lock before opening the file for writing.
func inspectPatchUpload(d *data, path string, cache UploadCache, offset int64, generation *uploadGeneration) (int64, string, int, error) {
	file, err := files.NewFileInfo(&files.FileOptions{
		Fs:         d.user.Fs,
		Path:       path,
		Modify:     d.user.Perm.Modify,
		Expand:     false,
		ReadHeader: d.server.TypeDetectionByHeader,
		Checker:    d,
	})
	if errors.Is(err, afero.ErrFileNotFound) {
		return 0, "", http.StatusNotFound, nil
	}
	if err != nil {
		return 0, "", errToStatus(err), err
	}
	if generation != nil && os.SameFile(generation.owned, generation.owned) {
		info, err := d.user.Fs.Stat(path)
		if err != nil {
			return 0, "", errToStatus(err), err
		}
		if !patchGenerationOwnsFile(generation, info) {
			return 0, "", http.StatusNotFound, nil
		}
	}
	cacheKey := file.RealPath()
	if generation != nil {
		cacheKey = generation.cacheKey
	}
	length, err := cache.GetLength(cacheKey)
	if err != nil {
		return 0, "", http.StatusNotFound, err
	}
	if offset > length {
		return 0, "", http.StatusBadRequest, fmt.Errorf("upload offset %d exceeds declared length %d", offset, length)
	}
	if file.IsDir {
		return 0, "", http.StatusBadRequest, fmt.Errorf("cannot upload to a directory %s", file.RealPath())
	}
	if file.Size != offset {
		return 0, "", http.StatusConflict, fmt.Errorf("%s file size doesn't match the provided offset: %d", file.RealPath(), offset)
	}
	return length, cacheKey, 0, nil
}

func patchGenerationCurrent(key string, generation *uploadGeneration) bool {
	current, ok := uploadMutations.entries.Load(key)
	if generation == nil {
		return !ok
	}
	return ok && current == generation
}

// Virtual filesystems may not expose stable identity. Preserve their existing
// PATCH behavior while enforcing inode ownership wherever SameFile supports it.
func patchGenerationOwnsFile(generation *uploadGeneration, info os.FileInfo) bool {
	return generation == nil || !os.SameFile(generation.owned, generation.owned) || os.SameFile(generation.owned, info)
}

func tusDeleteHandler(cache UploadCache) handleFunc {
	return withUser(func(_ http.ResponseWriter, r *http.Request, d *data) (int, error) {
		if r.URL.Path == "/" || !d.user.Perm.Delete {
			return http.StatusForbidden, nil
		}

		key, unlock := lockFileUploadMutation(d, r.URL.Path)
		defer unlock()

		file, err := files.NewFileInfo(&files.FileOptions{
			Fs:         d.user.Fs,
			Path:       r.URL.Path,
			Modify:     d.user.Perm.Modify,
			Expand:     false,
			ReadHeader: d.server.TypeDetectionByHeader,
			Checker:    d,
		})
		if err != nil {
			return errToStatus(err), err
		}

		_, err = cache.GetLength(file.RealPath())
		if err != nil {
			return http.StatusNotFound, err
		}

		retireUpload(key)
		err = d.user.Fs.Remove(r.URL.Path)
		if err != nil {
			return errToStatus(err), err
		}

		cache.Complete(file.RealPath())

		return http.StatusNoContent, nil
	})
}

// uploadLockKey identifies an upload across requests and users: the on-disk
// path, so two users whose scopes reach the same file contend for one lock. A
// filesystem that is not disk-backed has no such path; the virtual one is then
// unique within it.
func uploadLockKey(d *data, path string) string {
	return uploadIdentityKey(d.user.Fs, path, uploadPathKey(d, path))
}

func uploadPathKey(d *data, path string) string {
	if files.BasePath(d.user.Fs) == nil {
		return path
	}
	return filepath.Clean(d.user.FullPath(path))
}

func getUploadLength(r *http.Request) (int64, error) {
	uploadOffset, err := strconv.ParseInt(r.Header.Get("Upload-Length"), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid upload length: %w", err)
	}
	return uploadOffset, nil
}

func getUploadOffset(r *http.Request) (int64, error) {
	uploadOffset, err := strconv.ParseInt(r.Header.Get("Upload-Offset"), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid upload offset: %w", err)
	}
	return uploadOffset, nil
}
