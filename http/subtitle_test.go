package fbhttp

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/spf13/afero"

	"github.com/filebrowser/filebrowser/v2/files"
)

func TestNormalizeSRTLineBreaks(t *testing.T) {
	input := []byte("first<br>second<BR/>third<br />fourth<br class=\"x\">fifth")
	got := string(normalizeSRTLineBreaks(input))
	want := "first\nsecond\nthird\nfourth\nfifth"
	if got != want {
		t.Fatalf("normalizeSRTLineBreaks() = %q, want %q", got, want)
	}
}

func TestSubtitleFileHandlerConvertsSRTBreakTags(t *testing.T) {
	fs := afero.NewMemMapFs()
	const path = "/sample.srt"
	const content = "1\n" +
		"00:00:01,000 --> 00:00:02,000\n" +
		"First<br>Second<BR/>Third<br />Fourth\n\n"

	if err := afero.WriteFile(fs, path, []byte(content), 0o644); err != nil {
		t.Fatalf("failed to write subtitle: %v", err)
	}
	info, err := fs.Stat(path)
	if err != nil {
		t.Fatalf("failed to stat subtitle: %v", err)
	}

	file := &files.FileInfo{
		Fs:      fs,
		Path:    path,
		Name:    "sample.srt",
		ModTime: info.ModTime(),
	}
	req := httptest.NewRequest(http.MethodGet, "/api/subtitle/sample.srt?inline=true", http.NoBody)
	rec := httptest.NewRecorder()

	status, err := subtitleFileHandler(rec, req, file)
	if err != nil {
		t.Fatalf("subtitleFileHandler returned error: %v", err)
	}
	if status != 0 {
		t.Fatalf("subtitleFileHandler status = %d, want 0", status)
	}

	body := rec.Body.String()
	if strings.Contains(body, "FirstSecond") {
		t.Fatalf("WebVTT output collapsed SRT <br> tags: %q", body)
	}
	if !strings.Contains(body, "First\nSecond\nThird\nFourth") {
		t.Fatalf("WebVTT output = %q, want converted SRT <br> tags as line breaks", body)
	}
}

// Regression for GHSA-448h-jr2h-3vhp: converting a subtitle file to WebVTT
// loads it into memory several times over, so an oversized file must be refused
// instead of read.
func TestSubtitleFileHandlerRejectsOversizedFiles(t *testing.T) {
	for _, name := range []string{"big.srt", "big.ass", "big.ssa"} {
		t.Run(name, func(t *testing.T) {
			fs := afero.NewMemMapFs()
			path := "/" + name
			content := strings.Repeat("x", maxSubtitleConversionSize+1)
			if err := afero.WriteFile(fs, path, []byte(content), 0o644); err != nil {
				t.Fatalf("failed to write subtitle: %v", err)
			}

			req := httptest.NewRequest(http.MethodGet, "/api/subtitle/"+name, http.NoBody)

			// Once with the real size, as stat reports it, and once with a
			// stale size of zero, as if the file grew after it was stat-ed.
			for _, size := range []int64{int64(len(content)), 0} {
				file := &files.FileInfo{Fs: fs, Path: path, Name: name, Size: size}
				status, err := subtitleFileHandler(httptest.NewRecorder(), req, file)
				if err != nil {
					t.Fatalf("subtitleFileHandler returned error: %v", err)
				}
				if status != http.StatusRequestEntityTooLarge {
					t.Fatalf("VULNERABLE: status = %d with stat size %d, want 413", status, size)
				}
			}
		})
	}
}

// A WebVTT file needs no conversion and is streamed, so the bound does not
// apply to it.
func TestSubtitleFileHandlerStreamsLargeVTT(t *testing.T) {
	fs := afero.NewMemMapFs()
	const path = "/big.vtt"
	content := "WEBVTT\n\n" + strings.Repeat("x", maxSubtitleConversionSize+1)
	if err := afero.WriteFile(fs, path, []byte(content), 0o644); err != nil {
		t.Fatalf("failed to write subtitle: %v", err)
	}

	file := &files.FileInfo{Fs: fs, Path: path, Name: "big.vtt", Size: int64(len(content))}
	req := httptest.NewRequest(http.MethodGet, "/api/subtitle/big.vtt", http.NoBody)
	rec := httptest.NewRecorder()

	status, err := subtitleFileHandler(rec, req, file)
	if err != nil || status != 0 {
		t.Fatalf("subtitleFileHandler = %d, %v; want 0, nil", status, err)
	}
	if rec.Body.Len() != len(content) {
		t.Fatalf("served %d bytes, want %d", rec.Body.Len(), len(content))
	}
}
