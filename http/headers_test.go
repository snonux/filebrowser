//go:build !dev

package fbhttp

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

// Every response, the index page included, must forbid cross-origin framing so
// the interface cannot be overlaid by another site (clickjacking).
func TestResponsesForbidCrossOriginFraming(t *testing.T) {
	st := scopedUserStorage(t, t.TempDir(), users.Permissions{}, []byte("test-signing-key"))
	handler := handle(func(http.ResponseWriter, *http.Request, *data) (int, error) {
		return 0, nil
	}, "", st, &settings.Server{})

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", http.NoBody))

	if got := rec.Header().Get("X-Frame-Options"); got != "SAMEORIGIN" {
		t.Fatalf("X-Frame-Options = %q, want SAMEORIGIN", got)
	}
}
