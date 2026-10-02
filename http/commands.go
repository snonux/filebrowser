package fbhttp

import (
	"bufio"
	"io"
	"log"
	"net/http"
	"os/exec"
	"slices"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"github.com/filebrowser/filebrowser/v2/runner"
)

const (
	WSWriteDeadline = 10 * time.Second

	// maxCommandMessageSize bounds a single WebSocket message. gorilla/websocket
	// applies no limit of its own, so without one a client can make the server
	// buffer a message of any size. A command line is tiny; 64KiB is generous.
	maxCommandMessageSize = 64 << 10
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
}

var (
	cmdNotAllowed = []byte("Command not allowed.")
)

func wsErr(ws *websocket.Conn, r *http.Request, status int, err error) {
	txt := http.StatusText(status)
	if err != nil || status >= 400 {
		log.Printf("%s: %v %s %v", r.URL.Path, status, r.RemoteAddr, err)
	}
	if err := ws.WriteControl(websocket.CloseInternalServerErr, []byte(txt), time.Now().Add(WSWriteDeadline)); err != nil {
		log.Print(err)
	}
}

var commandsHandler = withUser(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return http.StatusInternalServerError, err
	}
	defer conn.Close()

	// Refuse before reading anything: the route is registered even when command
	// execution is disabled, so a user who may not run commands must not be able
	// to make the server read (and buffer) a message first.
	if !d.server.EnableExec || !d.user.Perm.Execute {
		if err := conn.WriteMessage(websocket.TextMessage, cmdNotAllowed); err != nil {
			wsErr(conn, r, http.StatusInternalServerError, err)
		}

		return 0, nil
	}

	conn.SetReadLimit(maxCommandMessageSize)

	var raw string

	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			wsErr(conn, r, http.StatusInternalServerError, err)
			return 0, nil
		}

		raw = strings.TrimSpace(string(msg))
		if raw != "" {
			break
		}
	}

	command, name, err := runner.ParseCommand(d.settings, raw)
	if err != nil {
		if err := conn.WriteMessage(websocket.TextMessage, []byte(err.Error())); err != nil {
			wsErr(conn, r, http.StatusInternalServerError, err)
		}
		return 0, nil
	}

	if !slices.Contains(d.user.Commands, name) {
		if err := conn.WriteMessage(websocket.TextMessage, cmdNotAllowed); err != nil {
			wsErr(conn, r, http.StatusInternalServerError, err)
		}

		return 0, nil
	}

	cmd := exec.Command(command[0], command[1:]...)
	cmd.Dir = d.user.FullPath(r.URL.Path)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		wsErr(conn, r, http.StatusInternalServerError, err)
		return 0, nil
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		wsErr(conn, r, http.StatusInternalServerError, err)
		return 0, nil
	}

	if err := cmd.Start(); err != nil {
		wsErr(conn, r, http.StatusInternalServerError, err)
		return 0, nil
	}

	s := bufio.NewScanner(io.MultiReader(stdout, stderr))
	for s.Scan() {
		if err := conn.WriteMessage(websocket.TextMessage, s.Bytes()); err != nil {
			log.Print(err)
		}
	}

	if err := cmd.Wait(); err != nil {
		wsErr(conn, r, http.StatusInternalServerError, err)
	}

	return 0, nil
})
