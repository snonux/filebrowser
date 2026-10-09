/// Helpers for File Browser paths.
///
/// The server addresses every file by an absolute, slash-separated path inside
/// the user's scope (for example `/photos/2024/beach.jpg`). The app keeps paths
/// in that decoded form and encodes them only when building a URL.
library;

/// Percent-encodes each segment of [path] so it can be appended to an API URL.
/// Slashes stay as separators; everything else, including `%`, `+`, `#` and
/// `?`, is encoded.
String encodePath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

/// Normalises [path] to start with exactly one slash and have no trailing
/// slash (except for the root, which is `/`).
String normalizePath(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return '/${parts.join('/')}';
}

/// Joins a directory and a child name.
String joinPath(String dir, String name) {
  final d = normalizePath(dir);
  return d == '/' ? '/$name' : '$d/$name';
}

/// Returns the parent directory of [path]; the parent of `/` is `/`.
String parentOf(String path) {
  final p = normalizePath(path);
  final i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.substring(0, i);
}

/// Returns the last segment of [path], or `/` for the root.
String baseName(String path) {
  final p = normalizePath(path);
  return p == '/' ? '/' : p.substring(p.lastIndexOf('/') + 1);
}

/// Returns true when [name] is a usable single file or folder name.
bool isValidName(String name) =>
    name.trim().isNotEmpty &&
    !name.contains('/') &&
    name != '.' &&
    name != '..';
