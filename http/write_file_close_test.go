package fbhttp

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/spf13/afero"
)

type closeErrorFs struct {
	afero.Fs
	closeErr error
}
type closeErrorFile struct {
	afero.File
	closeErr error
}

func (f closeErrorFs) OpenFile(name string, flag int, mode os.FileMode) (afero.File, error) {
	file, err := f.Fs.OpenFile(name, flag, mode)
	if err != nil {
		return nil, err
	}
	return closeErrorFile{file, f.closeErr}, nil
}
func (f closeErrorFile) Close() error { return errors.Join(f.File.Close(), f.closeErr) }

type failedUploadReader struct{ err error }

func (r failedUploadReader) Read([]byte) (int, error) { return 0, r.err }

func TestWriteFileReturnsCloseErrors(t *testing.T) {
	fs := afero.NewMemMapFs()
	info, err := writeFile(fs, "/healthy/file", strings.NewReader("payload"), 0600, 0700)
	if err != nil || info.Size() != 7 {
		t.Fatalf("healthy write: info=%v err=%v", info, err)
	}
	data, err := afero.ReadFile(fs, "/healthy/file")
	if err != nil || string(data) != "payload" {
		t.Fatalf("stored bytes: %q, %v", data, err)
	}
	closeErr := errors.New("close failed")
	_, err = writeFile(closeErrorFs{fs, closeErr}, "/close/file", strings.NewReader("payload"), 0600, 0700)
	if !errors.Is(err, closeErr) {
		t.Fatalf("lost close error: %v", err)
	}
	readErr := errors.New("read failed")
	_, err = writeFile(closeErrorFs{fs, closeErr}, "/both/file", failedUploadReader{readErr}, 0600, 0700)
	if !errors.Is(err, closeErr) || !errors.Is(err, readErr) {
		t.Fatalf("lost copy or close error: %v", err)
	}
}
