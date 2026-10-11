package fileutils

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/spf13/afero"
)

type failingRenameFs struct{ afero.Fs }

func (f failingRenameFs) Rename(_, _ string) error { return os.ErrInvalid }

// aliasOnOpenFs replaces a distinct destination after any path identity check.
// The copy must check the opened handles before truncating either file.
type aliasOnOpenFs struct {
	afero.Fs
	source, dest string
}

func (f aliasOnOpenFs) OpenFile(name string, flag int, mode os.FileMode) (afero.File, error) {
	if name == f.dest {
		if err := os.Remove(f.dest); err != nil {
			return nil, err
		}
		if err := os.Link(f.source, f.dest); err != nil {
			return nil, err
		}
	}
	return f.Fs.OpenFile(name, flag, mode)
}

func TestCopyFileRejectsSameFile(t *testing.T) {
	for _, kind := range []string{"identical", "symlink", "hardlink", "replaced on open"} {
		t.Run(kind, func(t *testing.T) {
			scope := t.TempDir()
			source := filepath.Join(scope, "source.txt")
			dest := filepath.Join(scope, "alias.txt")
			if err := os.WriteFile(source, []byte("keep this content"), 0o640); err != nil {
				t.Fatal(err)
			}
			afs := afero.Fs(files.NewScopedFs(afero.NewOsFs(), scope))
			switch kind {
			case "identical":
				dest = source
			case "symlink":
				if err := os.Symlink(source, dest); err != nil {
					t.Fatal(err)
				}
			case "hardlink":
				if err := os.Link(source, dest); err != nil {
					t.Fatal(err)
				}
			case "replaced on open":
				if err := os.WriteFile(dest, []byte("distinct"), 0o600); err != nil {
					t.Fatal(err)
				}
				afs = aliasOnOpenFs{Fs: afero.NewOsFs(), source: source, dest: dest}
			}
			srcName, dstName := "/source.txt", "/alias.txt"
			if kind == "identical" {
				dstName = srcName
			}
			if kind == "replaced on open" {
				srcName, dstName = source, dest
			}
			if err := CopyFile(afs, srcName, dstName, 0o600, 0o755); !errors.Is(err, ErrSameFile) {
				t.Fatalf("expected same-file error, got %v", err)
			}
			for _, name := range []string{source, dest} {
				data, err := os.ReadFile(name)
				if err != nil || string(data) != "keep this content" {
					t.Fatalf("%s changed: content=%q err=%v", name, data, err)
				}
			}
		})
	}
}

func TestMoveFileFallbackRejectsSameFile(t *testing.T) {
	for _, kind := range []string{"identical", "symlink", "hardlink", "replaced on open"} {
		t.Run(kind, func(t *testing.T) {
			scope := t.TempDir()
			source, dest := filepath.Join(scope, "source.txt"), filepath.Join(scope, "alias.txt")
			if err := os.WriteFile(source, []byte("keep"), 0o600); err != nil {
				t.Fatal(err)
			}
			afs := afero.Fs(files.NewScopedFs(afero.NewOsFs(), scope))
			srcName, dstName := "/source.txt", "/alias.txt"
			switch kind {
			case "identical":
				dest, dstName = source, srcName
			case "symlink":
				if err := os.Symlink(source, dest); err != nil {
					t.Fatal(err)
				}
			case "hardlink":
				if err := os.Link(source, dest); err != nil {
					t.Fatal(err)
				}
			case "replaced on open":
				if err := os.WriteFile(dest, []byte("old"), 0o600); err != nil {
					t.Fatal(err)
				}
				afs = aliasOnOpenFs{Fs: afero.NewOsFs(), source: source, dest: dest}
				srcName, dstName = source, dest
			}
			afs = failingRenameFs{Fs: afs}
			if err := MoveFile(afs, srcName, dstName, 0o600, 0o755); !errors.Is(err, ErrSameFile) {
				t.Fatalf("expected same-file error, got %v", err)
			}
			for _, name := range []string{source, dest} {
				data, err := os.ReadFile(name)
				if err != nil || string(data) != "keep" {
					t.Fatalf("%s changed or removed: content=%q err=%v", name, data, err)
				}
			}
		})
	}
}

func TestCopyFileDistinctAndErrors(t *testing.T) {
	for _, kind := range []string{"new", "overwrite", "missing source", "directory destination"} {
		t.Run(kind, func(t *testing.T) {
			scope := t.TempDir()
			afs := files.NewScopedFs(afero.NewOsFs(), scope)
			if err := afero.WriteFile(afs, "/source.txt", []byte("new"), 0o640); err != nil {
				t.Fatal(err)
			}
			source := "/source.txt"
			switch kind {
			case "overwrite":
				if err := afero.WriteFile(afs, "/dest.txt", []byte("long stale tail"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "missing source":
				source = "/missing.txt"
			case "directory destination":
				if err := afs.Mkdir("/dest.txt", 0o755); err != nil {
					t.Fatal(err)
				}
			}
			err := CopyFile(afs, source, "/dest.txt", 0o600, 0o755)
			if kind == "missing source" || kind == "directory destination" {
				if err == nil {
					t.Fatal("expected failure")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				data, err := afero.ReadFile(afs, "/dest.txt")
				if err != nil || string(data) != "new" {
					t.Fatalf("unexpected copy: %q, %v", data, err)
				}
				info, err := afs.Stat("/dest.txt")
				if err != nil || info.Mode().Perm() != 0o640 {
					t.Fatalf("source mode was not copied: %v, %v", info, err)
				}
			}
			data, err := afero.ReadFile(afs, "/source.txt")
			if err != nil || string(data) != "new" {
				t.Fatalf("source changed: %q, %v", data, err)
			}
		})
	}
}

func TestMoveFileFallbackCopiesDistinctFile(t *testing.T) {
	afs := failingRenameFs{Fs: files.NewScopedFs(afero.NewOsFs(), t.TempDir())}
	if err := afero.WriteFile(afs, "/source", []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := MoveFile(afs, "/source", "/dest", 0o600, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := afero.ReadFile(afs, "/dest")
	if err != nil || string(data) != "keep" {
		t.Fatalf("unexpected destination: %q, %v", data, err)
	}
	if _, err := afs.Stat("/source"); !os.IsNotExist(err) {
		t.Fatalf("source not removed: %v", err)
	}
}

func TestMoveFileFallbackCallback(t *testing.T) {
	for _, kind := range []string{"native", "fallback", "callback error", "same file"} {
		t.Run(kind, func(t *testing.T) {
			afs := afero.Fs(files.NewScopedFs(afero.NewOsFs(), t.TempDir()))
			if err := afero.WriteFile(afs, "/source", []byte("saved"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := afero.WriteFile(afs, "/dest", []byte("original"), 0o600); err != nil {
				t.Fatal(err)
			}
			if kind != "native" {
				afs = failingRenameFs{Fs: afs}
			}
			dest := "/dest"
			if kind == "same file" {
				dest = "/source"
			}
			called := false
			callbackErr := errors.New("abort copy")
			err := MoveFileWithFallback(afs, "/source", dest, 0o600, 0o755, func() error {
				called = true
				// The callback runs before destination truncation or source removal.
				for path, want := range map[string]string{"/source": "saved", "/dest": "original"} {
					content, err := afero.ReadFile(afs, path)
					if err != nil || string(content) != want {
						t.Fatalf("callback saw changed %s: %q, %v", path, content, err)
					}
				}
				if kind == "callback error" {
					return callbackErr
				}
				return nil
			})
			if called != (kind == "fallback" || kind == "callback error") {
				t.Fatalf("callback called = %v", called)
			}
			if kind == "callback error" || kind == "same file" {
				wantErr := callbackErr
				if kind == "same file" {
					wantErr = ErrSameFile
				}
				if !errors.Is(err, wantErr) {
					t.Fatalf("move = %v, want %v", err, wantErr)
				}
				for path, want := range map[string]string{"/source": "saved", "/dest": "original"} {
					content, err := afero.ReadFile(afs, path)
					if err != nil || string(content) != want {
						t.Fatalf("failed move changed %s: %q, %v", path, content, err)
					}
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			content, err := afero.ReadFile(afs, "/dest")
			if err != nil || string(content) != "saved" {
				t.Fatalf("move destination = %q, %v", content, err)
			}
			if _, err := afs.Stat("/source"); !os.IsNotExist(err) {
				t.Fatalf("move source retained: %v", err)
			}
		})
	}
}

func TestCommonPrefix(t *testing.T) {
	testCases := map[string]struct {
		paths []string
		want  string
	}{
		"same lvl": {
			paths: []string{
				"/home/user/file1",
				"/home/user/file2",
			},
			want: "/home/user",
		},
		"sub folder": {
			paths: []string{
				"/home/user/folder",
				"/home/user/folder/file",
			},
			want: "/home/user/folder",
		},
		"relative path": {
			paths: []string{
				"/home/user/folder",
				"/home/user/folder/../folder2",
			},
			want: "/home/user",
		},
		"no common path": {
			paths: []string{
				"/home/user/folder",
				"/etc/file",
			},
			want: "",
		},
	}
	for name, tt := range testCases {
		t.Run(name, func(t *testing.T) {
			if got := CommonPrefix('/', tt.paths...); got != tt.want {
				t.Errorf("CommonPrefix() = %v, want %v", got, tt.want)
			}
		})
	}
}
