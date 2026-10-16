import 'dart:io';

import '../api/paths.dart';
import '../models/models.dart';

/// A storage volume of the phone: internal storage, an SD card or a USB
/// drive.
class StorageRoot {
  const StorageRoot({required this.name, required this.path});

  final String name;

  /// Absolute path of the volume's top folder.
  final String path;
}

/// Raised by [LocalFiles] when a target already exists.
class LocalConflict implements Exception {
  const LocalConflict(this.path);

  final String path;

  @override
  String toString() => '"${baseName(path)}" already exists';
}

/// File manager operations on the phone's own storage. Paths are absolute
/// and slash-separated, like the server's, so the helpers in `paths.dart`
/// apply to them too.
class LocalFiles {
  const LocalFiles();

  /// The entries of [dir], as [FileItem]s with a type guessed from the
  /// file name. Broken links and entries that vanish while listing are
  /// left out.
  Future<List<FileItem>> list(String dir) async {
    final items = <FileItem>[];
    await for (final entity in Directory(dir).list(followLinks: false)) {
      final item = await stat(entity.path);
      if (item != null) items.add(item);
    }
    return items;
  }

  /// [path] as a [FileItem], or null when it does not exist.
  Future<FileItem?> stat(String path) async {
    final info = await FileStat.stat(path);
    final isLink = await FileSystemEntity.isLink(path);
    if (info.type == FileSystemEntityType.notFound) return null;
    final isDir = info.type == FileSystemEntityType.directory;
    final name = baseName(path);
    return FileItem(
      path: normalizePath(path),
      name: name,
      size: isDir ? 0 : info.size,
      modified: info.modified,
      isDir: isDir,
      type: isDir ? '' : typeOf(name),
      extension: _extension(name),
      isSymlink: isLink,
    );
  }

  Future<bool> exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  Future<void> createFolder(String path) async {
    if (await exists(path)) throw LocalConflict(path);
    await Directory(path).create();
  }

  /// Renames or moves [from] to [to]. Across volumes, where a rename is not
  /// possible, it copies and then deletes. With [override], an existing
  /// [to] is deleted first.
  Future<void> move(String from, String to, {bool override = false}) async {
    if (normalizePath(from) == normalizePath(to)) return;
    _checkNotInside(from, to);
    await _clear(to, override);
    try {
      await _entity(from).rename(to);
    } on FileSystemException {
      // EXDEV: another volume. Copy, then remove the original.
      await _copy(from, to);
      await delete(from);
    }
  }

  /// Copies [from] (a file, or a folder with everything in it) to [to].
  Future<void> copy(String from, String to, {bool override = false}) async {
    if (normalizePath(from) == normalizePath(to)) throw LocalConflict(to);
    _checkNotInside(from, to);
    await _clear(to, override);
    await _copy(from, to);
  }

  Future<void> delete(String path) async {
    await _entity(path).delete(recursive: true);
  }

  /// A path in [dir] for [name] that does not exist yet: [name] itself, or
  /// `name (1).ext`, `name (2).ext`, …
  Future<String> freeName(String dir, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var target = joinPath(dir, name);
    for (var i = 1; await exists(target); i++) {
      target = joinPath(dir, '$stem ($i)$ext');
    }
    return target;
  }

  /// Every file below [dir], with its path relative to [dir]; and every
  /// folder, so empty ones are kept too.
  Future<({List<String> folders, List<String> files})> walk(String dir) async {
    final folders = <String>[];
    final files = <String>[];
    final root = normalizePath(dir);
    await for (final entity
        in Directory(root).list(recursive: true, followLinks: false)) {
      final relative = normalizePath(entity.path).substring(root.length + 1);
      if (entity is Directory) {
        folders.add(relative);
      } else if (entity is File) {
        files.add(relative);
      }
    }
    folders.sort();
    files.sort();
    return (folders: folders, files: files);
  }

  FileSystemEntity _entity(String path) =>
      FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);

  void _checkNotInside(String from, String to) {
    final f = normalizePath(from);
    if (normalizePath(to).startsWith('$f/')) {
      throw FileSystemException('A folder cannot go into itself', to);
    }
  }

  Future<void> _clear(String to, bool override) async {
    if (!await exists(to)) return;
    if (!override) throw LocalConflict(to);
    await delete(to);
  }

  Future<void> _copy(String from, String to) async {
    if (!FileSystemEntity.isDirectorySync(from)) {
      await File(from).copy(to);
      return;
    }
    await Directory(to).create(recursive: true);
    await for (final entity in Directory(from).list(followLinks: false)) {
      await _copy(entity.path, joinPath(to, baseName(entity.path)));
    }
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  static const _types = {
    'image': [
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', //
      'svg',
    ],
    'video': ['mp4', 'mkv', 'webm', 'mov', 'avi', '3gp', 'm4v', 'ts'],
    'audio': [
      'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav', 'mid', //
      'amr',
    ],
    'pdf': ['pdf'],
    'text': [
      'txt', 'md', 'markdown', 'json', 'yaml', 'yml', 'xml', 'csv', 'log', //
      'ini', 'conf', 'cfg', 'toml', 'sh', 'fish', 'py', 'go', 'dart', 'js',
      'html', 'css', 'kt', 'java', 'c', 'h', 'cpp', 'rs', 'rb', 'pl',
    ],
  };

  /// The server's type names (`image`, `video`, `audio`, `pdf`, `text`,
  /// `blob`), guessed from [name]'s extension.
  static String typeOf(String name) {
    final ext = _extension(name).replaceFirst('.', '');
    for (final entry in _types.entries) {
      if (entry.value.contains(ext)) return entry.key;
    }
    return 'blob';
  }
}
