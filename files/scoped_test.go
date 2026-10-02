package files

import (
	"os"
	"path/filepath"
	"testing"
)

// ResolvePath has to report where an operation would really land, including
// for names that do not exist yet: the missing tail is re-attached to the
// resolved ancestor, and a dangling link is followed rather than treated as a
// plain new file next to it.
func TestResolvePath(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "real", "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "real", "file.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real", filepath.Join(root, "alias")); err != nil {
		t.Skipf("cannot create symlink on this platform: %v", err)
	}
	if err := os.Symlink(filepath.Join("real", "missing.txt"), filepath.Join(root, "dangling")); err != nil {
		t.Fatal(err)
	}

	cases := map[string]string{
		"real/file.txt":           "real/file.txt",
		"alias/file.txt":          "real/file.txt",
		"alias/new.txt":           "real/new.txt",
		"alias/sub/new/deep.txt":  "real/sub/new/deep.txt",
		"dangling":                "real/missing.txt",
		"nowhere/at/all.txt":      "nowhere/at/all.txt",
		"alias/../real/file.txt":  "real/file.txt",
		"real/sub/../../alias/..": ".",
	}
	for in, want := range cases {
		got, err := ResolvePath(filepath.Join(root, filepath.FromSlash(in)))
		if err != nil {
			t.Errorf("ResolvePath(%q) error: %v", in, err)
			continue
		}
		if want := filepath.Join(root, filepath.FromSlash(want)); got != want {
			t.Errorf("ResolvePath(%q) = %q, want %q", in, got, want)
		}
	}
}
