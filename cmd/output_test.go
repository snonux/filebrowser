package cmd

import (
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/filebrowser/filebrowser/v2/auth"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

type failedOutput struct{ err error }

func (w failedOutput) Write([]byte) (int, error) { return 0, w.err }

type shortOutput struct{}

func (shortOutput) Write(p []byte) (int, error) { return len(p) - 1, nil }

func TestCommandOutputErrors(t *testing.T) {
	failure := errors.New("output unavailable")
	for name, render := range map[string]func(io.Writer) error{
		"users": func(w io.Writer) error { return printUsersTo(w, []*users.User{{Username: "alice", Scope: "/files"}}) },
		"settings": func(w io.Writer) error {
			return printSettingsTo(w, &settings.Server{Root: "/files"}, &settings.Settings{}, &auth.JSONAuth{})
		},
	} {
		t.Run(name, func(t *testing.T) {
			var output strings.Builder
			if err := render(&output); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(output.String(), "/files") {
				t.Fatalf("missing table value: %q", output.String())
			}
			if err := render(failedOutput{failure}); !errors.Is(err, failure) {
				t.Fatalf("lost output failure: %v", err)
			}
			if err := render(shortOutput{}); !errors.Is(err, io.ErrShortWrite) {
				t.Fatalf("lost short write: %v", err)
			}
		})
	}
}
