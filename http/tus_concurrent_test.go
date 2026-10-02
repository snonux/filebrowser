package fbhttp

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Regression for GHSA-4r8p-gqj2-mwgm: concurrent PATCHes at the same offset all
// passed the offset check before any of them wrote, and every body was
// appended, so the stored file exceeded its declared Upload-Length.
func TestTusConcurrentPatchesCannotExceedUploadLength(t *testing.T) {
	const size = 64 << 10
	const racers = 8

	f := newTusTestFixture(t)
	payload := testPayload(size)
	url := f.create(t, "race.bin", size)

	// The handler checks the offset when the request headers arrive and only
	// then reads the body. Holding every body back until all requests are in
	// the handler makes the race deterministic: unserialized, each of them has
	// seen an empty file by the time any byte is written.
	release := make(chan struct{})
	statuses := make(chan int, racers)
	var wg sync.WaitGroup
	for range racers {
		body, bodyWriter := io.Pipe()
		go func() {
			<-release
			// Fails harmlessly for a request that was answered before its body
			// was sent, which closes the pipe.
			_, _ = bodyWriter.Write(payload)
			_ = bodyWriter.Close()
		}()

		req, err := http.NewRequest(http.MethodPatch, url, body)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("X-Auth", f.token)
		req.Header.Set("Content-Type", "application/offset+octet-stream")
		req.Header.Set("Upload-Offset", "0")

		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := f.client.Do(req)
			if err != nil {
				t.Errorf("PATCH: %v", err)
				return
			}
			_, _ = io.Copy(io.Discard, res.Body)
			res.Body.Close()
			statuses <- res.StatusCode
		}()
	}

	time.Sleep(300 * time.Millisecond)
	close(release)
	wg.Wait()
	close(statuses)

	accepted := 0
	for status := range statuses {
		switch status {
		case http.StatusNoContent:
			accepted++
		case http.StatusLocked:
			// Another chunk was being written.
		default:
			t.Errorf("unexpected PATCH status %d", status)
		}
	}
	if accepted != 1 {
		t.Errorf("VULNERABLE: %d PATCHes at offset 0 were accepted, want exactly 1", accepted)
	}

	stored, err := os.ReadFile(filepath.Join(f.scope, "race.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if len(stored) != size {
		t.Fatalf("VULNERABLE: stored %d bytes for a declared length of %d", len(stored), size)
	}
	if !bytes.Equal(stored, payload) {
		t.Fatal("stored content differs from the uploaded payload")
	}
}

// The lock is released when a PATCH ends, whatever its outcome, so a rejected
// chunk does not leave the upload stuck.
func TestTusPatchLockIsReleased(t *testing.T) {
	f := newTusTestFixture(t)
	payload := testPayload(1024)
	url := f.create(t, "seq.bin", len(payload))

	// A chunk at the wrong offset is rejected...
	res, _ := f.patch(t, url, 512, payload[512:])
	res.Body.Close()
	if res.StatusCode != http.StatusConflict {
		t.Fatalf("PATCH at a wrong offset = %d, want 409", res.StatusCode)
	}

	// ...and the upload can still be written afterwards.
	res, _ = f.patch(t, url, 0, payload)
	res.Body.Close()
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("PATCH after a rejected one = %d, want 204", res.StatusCode)
	}
}
