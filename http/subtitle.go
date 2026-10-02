package fbhttp

import (
	"bytes"
	"io"
	"net/http"
	"regexp"
	"strings"

	"github.com/asticode/go-astisub"

	"github.com/filebrowser/filebrowser/v2/files"
)

// maxSubtitleConversionSize bounds the subtitle files converted to WebVTT.
// Conversion holds the file, a normalized copy, the parsed cues and the
// rendered output in memory at once, so its cost is a multiple of the file
// size. Real subtitle files are well under a megabyte; 10MB matches the cap
// files.detectType applies before loading text content.
const maxSubtitleConversionSize = 10 << 20

var srtLineBreakTag = regexp.MustCompile(`(?i)<br(?:\s+[^>]*)?\s*/?>`)

var subtitleHandler = withUser(func(w http.ResponseWriter, r *http.Request, d *data) (int, error) {
	if !d.user.Perm.Download {
		return http.StatusAccepted, nil
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

	if file.IsDir {
		return http.StatusBadRequest, nil
	}

	return subtitleFileHandler(w, r, file)
})

func subtitleFileHandler(w http.ResponseWriter, r *http.Request, file *files.FileInfo) (int, error) {
	// if its not a subtitle file, reject
	if !files.IsSupportedSubtitle(file.Name) {
		return http.StatusBadRequest, nil
	}

	fd, err := file.Fs.Open(file.Path)
	if err != nil {
		return http.StatusInternalServerError, err
	}
	defer fd.Close()

	// load subtitle for conversion to vtt
	sub, status, err := loadSubtitle(fd, file)
	if err != nil || status != 0 {
		return status, err
	}

	setContentDisposition(w, r, file)
	w.Header().Add("Content-Security-Policy", `script-src 'none';`)
	w.Header().Set("Cache-Control", "private")
	// force type to text/vtt
	w.Header().Set("Content-Type", "text/vtt")

	// serve vtt file directly
	if sub == nil {
		http.ServeContent(w, r, file.Name, file.ModTime, fd)
		return 0, nil
	}

	// convert others to vtt and serve from buffer
	var buf = &bytes.Buffer{}
	err = sub.WriteToWebVTT(buf)
	if err != nil {
		return http.StatusInternalServerError, err
	}
	http.ServeContent(w, r, file.Name, file.ModTime, bytes.NewReader(buf.Bytes()))
	return 0, nil
}

// loadSubtitle parses the formats that have to be converted to WebVTT. It
// returns a nil subtitle for a file that is served as is (.vtt), and a non-zero
// status when the file cannot be converted.
//
// The size is checked twice: against the stat size, to refuse an oversized file
// without reading it, and through a limited reader, so a file that grew after
// the stat (or whose stat size is unknown) still cannot exceed the bound.
func loadSubtitle(fd io.Reader, file *files.FileInfo) (*astisub.Subtitles, int, error) {
	isSRT := strings.HasSuffix(file.Name, ".srt")
	if !isSRT && !strings.HasSuffix(file.Name, ".ass") && !strings.HasSuffix(file.Name, ".ssa") {
		return nil, 0, nil
	}

	if file.Size > maxSubtitleConversionSize {
		return nil, http.StatusRequestEntityTooLarge, nil
	}

	content, err := io.ReadAll(io.LimitReader(fd, maxSubtitleConversionSize+1))
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	if len(content) > maxSubtitleConversionSize {
		return nil, http.StatusRequestEntityTooLarge, nil
	}

	var sub *astisub.Subtitles
	if isSRT {
		sub, err = astisub.ReadFromSRT(bytes.NewReader(normalizeSRTLineBreaks(content)))
	} else {
		sub, err = astisub.ReadFromSSA(bytes.NewReader(content))
	}
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}

	return sub, 0, nil
}

func normalizeSRTLineBreaks(content []byte) []byte {
	return srtLineBreakTag.ReplaceAll(content, []byte("\n"))
}
