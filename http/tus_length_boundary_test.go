package fbhttp

import (
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestTusPatchLengthBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name       string
		length     int64
		prefix     string
		chunk      string
		wantStatus int
		wantOffset string
		wantFile   string
		retry      string
	}{
		{"max-int64", math.MaxInt64, "", "x", http.StatusNoContent, "1", "x", ""},
		{"overlong-after-prefix", 4, "ab", "cde", http.StatusRequestEntityTooLarge, "", "ab", "cd"},
		{"zero-remaining-overlong", 2, "ab", "x", http.StatusRequestEntityTooLarge, "", "ab", ""},
		{"zero-remaining-empty", 2, "ab", "", http.StatusNoContent, "2", "ab", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newTusTestFixture(t)
			url := f.srv.URL + "/api/tus/boundary"
			req, err := http.NewRequest(http.MethodPost, url, http.NoBody)
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("X-Auth", f.token)
			req.Header.Set("Upload-Length", strconv.FormatInt(tc.length, 10))
			res, err := f.client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			checkTusBoundaryResponse(t, res, http.StatusCreated, "")

			path := filepath.Join(f.scope, "boundary")
			if tc.prefix != "" {
				if int64(len(tc.prefix)) < tc.length {
					res, _ = f.patch(t, url, 0, []byte(tc.prefix))
					checkTusBoundaryResponse(t, res, http.StatusNoContent, strconv.Itoa(len(tc.prefix)))
				} else {
					// Keep the POST's active generation while placing its owned
					// inode at the declared length, to exercise zero remainder.
					if err := os.WriteFile(path, []byte(tc.prefix), 0o600); err != nil {
						t.Fatal(err)
					}
				}
			}

			res, _ = f.patch(t, url, len(tc.prefix), []byte(tc.chunk))
			content, err := os.ReadFile(path)
			if err != nil || string(content) != tc.wantFile {
				t.Errorf("file = %q, %v; want %q", content, err, tc.wantFile)
			}
			checkTusBoundaryResponse(t, res, tc.wantStatus, tc.wantOffset)
			if tc.wantStatus == http.StatusRequestEntityTooLarge {
				// The rejected chunk must leave the upload resumable at the
				// exact previous offset, including when no bytes remain.
				req, err := http.NewRequest(http.MethodHead, url, http.NoBody)
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("X-Auth", f.token)
				res, err = f.client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				checkTusBoundaryResponse(t, res, http.StatusOK, strconv.Itoa(len(tc.prefix)))
				res, _ = f.patch(t, url, len(tc.prefix), []byte(tc.retry))
				checkTusBoundaryResponse(t, res, http.StatusNoContent, strconv.FormatInt(tc.length, 10))
				content, err = os.ReadFile(path)
				if err != nil || string(content) != tc.prefix+tc.retry {
					t.Fatalf("file after retry = %q, %v", content, err)
				}
			}
		})
	}
}

func checkTusBoundaryResponse(t *testing.T, res *http.Response, status int, offset string) {
	t.Helper()
	defer func() { _ = res.Body.Close() }()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != status || res.Header.Get("Upload-Offset") != offset {
		t.Fatalf("response = %d, offset %q, body %q; want %d, offset %q", res.StatusCode, res.Header.Get("Upload-Offset"), body, status, offset)
	}
}
