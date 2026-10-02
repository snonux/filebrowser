package fbhttp

import (
	"log"
	"net/http"
	gopath "path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/afero"
	"github.com/tomasen/realip"

	"github.com/filebrowser/filebrowser/v2/files"
	"github.com/filebrowser/filebrowser/v2/rules"
	"github.com/filebrowser/filebrowser/v2/runner"
	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/storage"
	"github.com/filebrowser/filebrowser/v2/users"
)

type handleFunc func(w http.ResponseWriter, r *http.Request, d *data) (int, error)

type data struct {
	*runner.Runner
	settings *settings.Settings
	server   *settings.Server
	store    *storage.Storage
	user     *users.User
	raw      interface{}

	// checkerPrefix is prepended to every path before evaluating rules. It is
	// set when the user's filesystem has been rebased onto a subdirectory (as
	// done for public shares), so that rules — which are relative to the user's
	// original scope — are still matched against the real path instead of the
	// rebased one. Empty for regular requests.
	checkerPrefix string

	// scopeRoot is the on-disk root of the user's original scope. It is set
	// together with checkerPrefix, when the user's filesystem is rebased, so
	// that a symlink target can still be expressed relative to the scope the
	// rules are written for. Empty for regular requests, where the user's
	// filesystem is rooted at the scope itself.
	scopeRoot string
}

// Check implements rules.Checker.
func (d *data) Check(path string) bool {
	if d.user.HideDotfiles && rules.MatchHidden(d.rulePath(path)) {
		return false
	}

	return d.CheckRules(path)
}

// CheckRules reports whether the global and user rules allow path. Unlike
// Check, it ignores HideDotfiles: hiding dotfiles is a display preference, so
// it must not stop a user from operating on a tree that contains one.
//
// The rules have to allow both the path as requested and the object it really
// names. The filesystem follows symbolic links, so "/allowed/link/secret.txt"
// can open a file a rule denies as "/denied/secret.txt"; matching only the
// requested name would let any in-scope link alias a way around a deny rule.
func (d *data) CheckRules(path string) bool {
	if len(d.settings.Rules) == 0 && len(d.user.Rules) == 0 {
		return true
	}

	if !d.rulesAllow(d.rulePath(path)) {
		return false
	}

	if resolved, ok := d.resolvedRulePath(path); ok {
		return d.rulesAllow(resolved)
	}

	return true
}

// rulesAllow evaluates the global and then the user rules against a canonical
// scope-relative path. Later rules override earlier ones.
func (d *data) rulesAllow(path string) bool {
	allow := true
	for _, rule := range d.settings.Rules {
		if rule.Matches(path, d.server.CaseInsensitiveFs) {
			allow = rule.Allow
		}
	}

	for _, rule := range d.user.Rules {
		if rule.Matches(path, d.server.CaseInsensitiveFs) {
			allow = rule.Allow
		}
	}

	return allow
}

// resolvedRulePath returns the canonical scope-relative path of the object path
// names once symbolic links are followed. It reports false when there is
// nothing more to check: the filesystem is not disk-backed, the path cannot be
// resolved (the operation on it then fails by itself), or the target lies
// outside the scope — which rules, being scope-relative, cannot describe, and
// which ScopedFs refuses anyway unless external symlinks are explicitly allowed.
func (d *data) resolvedRulePath(path string) (string, bool) {
	base := files.BasePath(d.user.Fs)
	if base == nil {
		return "", false
	}

	root := d.scopeRoot
	if root == "" {
		root = afero.FullBaseFsPath(base, "/")
	}
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", false
	}

	resolved, err := files.ResolvePath(afero.FullBaseFsPath(base, slashClean(path)))
	if err != nil {
		return "", false
	}

	rel, err := filepath.Rel(root, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}

	return slashClean(rel), true
}

// rulePath canonicalizes path into the form the rules are written in.
func (d *data) rulePath(path string) string {
	// Rules are written as "/"-separated virtual paths, but callers hand us
	// paths built by the OS as well as ones taken from the request: afero.Walk
	// and filepath.Join use "\" on Windows, where the filesystem also treats it
	// as a separator. Canonicalize first so the authorization decision does not
	// depend on which separator the caller happened to use.
	path = slashClean(path)

	// When the filesystem has been rebased (e.g. a public share rooted at a
	// subdirectory), the incoming path is relative to that root. Resolve it
	// back to the user's original scope before matching rules, otherwise rules
	// targeting paths below the share root would be silently bypassed.
	if d.checkerPrefix != "" {
		path = gopath.Join(d.checkerPrefix, path)
	}

	return path
}

func handle(fn handleFunc, prefix string, store *storage.Storage, server *settings.Server) http.Handler {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for k, v := range globalHeaders {
			w.Header().Set(k, v)
		}

		settings, err := store.Settings.Get()
		if err != nil {
			log.Fatalf("ERROR: couldn't get settings: %v\n", err)
			return
		}

		status, err := fn(w, r, &data{
			Runner:   &runner.Runner{Enabled: server.EnableExec, Settings: settings},
			store:    store,
			settings: settings,
			server:   server,
		})

		if status >= 400 || err != nil {
			clientIP := realip.FromRequest(r)
			log.Printf("%s: %v %s %v", r.URL.Path, status, clientIP, err)
		}

		if status != 0 {
			txt := http.StatusText(status)
			if status == http.StatusBadRequest && err != nil {
				txt += " (" + err.Error() + ")"
			}
			http.Error(w, strconv.Itoa(status)+" "+txt, status)
			return
		}
	})

	return stripPrefix(prefix, handler)
}
