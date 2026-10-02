package fbhttp

import (
	"bytes"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

// dialCommand opens the command WebSocket as a user holding perm, against a
// server whose command execution is switched by enableExec.
func dialCommand(t *testing.T, perm users.Permissions, enableExec bool) *websocket.Conn {
	t.Helper()

	key := []byte("test-signing-key")
	st := scopedUserStorage(t, t.TempDir(), perm, key)

	srv := httptest.NewServer(handle(commandsHandler, "/api/command", st, &settings.Server{EnableExec: enableExec}))
	t.Cleanup(srv.Close)

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/command/"
	header := map[string][]string{"X-Auth": {signToken(t, perm, key)}}
	conn, res, err := websocket.DefaultDialer.Dial(url, header)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	_ = res.Body.Close()

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	return conn
}

// Regression for GHSA-39cx-23x9-5c8p: a user who may not run commands is
// refused before the server reads a message, so nothing they send is buffered.
func TestCommandRefusedBeforeReadingMessage(t *testing.T) {
	for name, enableExec := range map[string]bool{"exec disabled": false, "no execute permission": true} {
		t.Run(name, func(t *testing.T) {
			conn := dialCommand(t, users.Permissions{}, enableExec)

			// Nothing is sent: the refusal must not depend on a client message.
			_, msg, err := conn.ReadMessage()
			if err != nil {
				t.Fatalf("VULNERABLE: no refusal without a client message: %v", err)
			}
			if !bytes.Equal(msg, cmdNotAllowed) {
				t.Fatalf("message = %q, want %q", msg, cmdNotAllowed)
			}
		})
	}
}

// Regression for GHSA-39cx-23x9-5c8p: even a user who may run commands cannot
// make the server buffer an arbitrarily large message.
func TestCommandMessageSizeIsBounded(t *testing.T) {
	conn := dialCommand(t, users.Permissions{Execute: true}, true)

	payload := bytes.Repeat([]byte("A"), maxCommandMessageSize+1)
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	// An over-limit message makes the server drop the connection instead of
	// answering it; a reply would mean the whole message was read.
	if _, msg, err := conn.ReadMessage(); err == nil {
		t.Fatalf("VULNERABLE: oversized message was read and answered with %q", msg)
	}
}

// The legitimate path still works: an in-limit command from an allowed user is
// read and reaches the allowlist check.
func TestCommandWithinLimitIsRead(t *testing.T) {
	conn := dialCommand(t, users.Permissions{Execute: true}, true)

	if err := conn.WriteMessage(websocket.TextMessage, []byte("ls")); err != nil {
		t.Fatalf("write: %v", err)
	}

	_, msg, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	// The test user has no allowed commands, so the answer is the allowlist
	// refusal, proving the message was read and parsed.
	if !bytes.Equal(msg, cmdNotAllowed) {
		t.Fatalf("message = %q, want %q", msg, cmdNotAllowed)
	}
}
