import 'dart:convert';
import 'dart:io';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../models/models.dart';

/// One item kept for offline use: a folder, or a file with its local copy.
class OfflineEntry {
  const OfflineEntry(this.item, {this.local});

  factory OfflineEntry.fromJson(Map<String, dynamic> json) => OfflineEntry(
        FileItem.fromJson((json['item'] as Map).cast<String, dynamic>()),
        local: json['local'] as String?,
      );

  final FileItem item;

  /// The copy's path relative to the store's `files` folder; null for a
  /// folder.
  final String? local;

  Map<String, dynamic> toJson() =>
      {'item': item.toJson(), if (local != null) 'local': local};
}

/// Files and folders of one account marked "available offline", with copies
/// on the device so they can be browsed and opened while the server cannot be
/// reached.
///
/// A pin is the path of a file or folder; a folder pin covers everything
/// below it. [sync] mirrors the pins from the server: it downloads new and
/// changed files and removes the copies of files that are gone. A pin whose
/// item was deleted on the server is dropped. Copies stay until their pin is
/// removed or the item is deleted.
///
/// Each file is kept as `files/<n>/<name>`: its own name, so other apps
/// recognise its type, in its own folder, so names that differ only in case
/// do not collide on case-insensitive storage.
class OfflineStore {
  OfflineStore._(this.root);

  /// The account's folder: `index.json` and the `files` folder.
  final Directory root;

  final Set<String> _pins = {};
  final Map<String, OfflineEntry> _entries = {};
  int _next = 0;

  /// Loads the store in [root], or starts an empty one.
  static Future<OfflineStore> open(Directory root) async {
    final store = OfflineStore._(root);
    final index = store._indexFile;
    if (await index.exists()) {
      try {
        final json = jsonDecode(await index.readAsString()) as Map;
        store._next = (json['next'] as num?)?.toInt() ?? 0;
        store._pins
            .addAll(((json['pins'] as List?) ?? const []).cast<String>());
        ((json['entries'] as Map?) ?? const {}).forEach((key, value) {
          store._entries[key as String] =
              OfflineEntry.fromJson((value as Map).cast<String, dynamic>());
        });
      } on Object {
        // A damaged index loses the list, not the app: start over.
        store._pins.clear();
        store._entries.clear();
      }
    }
    return store;
  }

  File get _indexFile => File('${root.path}/index.json');
  String get _filesPath => '${root.path}/files';

  Future<void> _save() async {
    await root.create(recursive: true);
    final json = jsonEncode({
      'next': _next,
      'pins': _pins.toList()..sort(),
      'entries': {for (final e in _entries.entries) e.key: e.value.toJson()},
    });
    // Write a new file and rename it, so a crash never leaves half an index.
    final temp = File('${_indexFile.path}.tmp');
    await temp.writeAsString(json, flush: true);
    await temp.rename(_indexFile.path);
  }

  /// The pinned paths, sorted.
  List<String> get pins => _pins.toList()..sort();

  bool get isEmpty => _pins.isEmpty;

  bool isPinned(String path) => _pins.contains(normalizePath(path));

  /// The pin that keeps [path] offline: [path] itself or the nearest pinned
  /// folder above it; null when it is not kept.
  String? pinCovering(String path) {
    var p = normalizePath(path);
    while (true) {
      if (_pins.contains(p)) return p;
      if (p == '/') return null;
      p = parentOf(p);
    }
  }

  bool covers(String path) => pinCovering(path) != null;

  /// The item as last seen on the server, when it is kept offline.
  FileItem? item(String path) => _entries[normalizePath(path)]?.item;

  /// The local copy of the file at [path], once it has been downloaded.
  File? localFile(String path) {
    final local = _entries[normalizePath(path)]?.local;
    if (local == null) return null;
    final file = File('$_filesPath/$local');
    return file.existsSync() ? file : null;
  }

  /// Whether [path] can be used offline: a folder that is kept, or a file
  /// whose copy is on the device.
  bool isAvailable(String path) {
    final entry = _entries[normalizePath(path)];
    if (entry == null) return false;
    return entry.item.isDir || localFile(path) != null;
  }

  /// Number of downloaded files and their total size.
  ({int files, int bytes}) get usage {
    var files = 0, bytes = 0;
    for (final e in _entries.values) {
      if (e.local != null) {
        files++;
        bytes += e.item.size;
      }
    }
    return (files: files, bytes: bytes);
  }

  /// The listing of [path] from what is kept offline. Folders above a pin are
  /// listed too, with just the way down to it, so the app can be browsed from
  /// Home. Returns null when nothing at or below [path] is kept.
  Resource? listing(String path) {
    final p = normalizePath(path);
    final prefix = p == '/' ? '/' : '$p/';
    final self = _entries[p];
    if (self != null && !self.item.isDir) return null;
    var known = self != null;
    final children = <String, FileItem>{};
    for (final key in _entries.keys) {
      if (key == p || !key.startsWith(prefix)) continue;
      known = true;
      final rest = key.substring(prefix.length);
      final slash = rest.indexOf('/');
      final childPath = slash < 0 ? key : prefix + rest.substring(0, slash);
      if (children.containsKey(childPath)) continue;
      final entry = _entries[childPath];
      if (entry != null && entry.local == null && !entry.item.isDir) continue;
      children[childPath] = entry?.item ?? _folder(childPath);
    }
    if (!known) return null;
    return Resource(
      item: self?.item ?? _folder(p),
      items: [
        for (final item in children.values)
          if (item.isDir || localFile(item.path) != null) item,
      ],
      offline: true,
    );
  }

  static FileItem _folder(String path) => FileItem(
        path: path,
        name: baseName(path),
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        isDir: true,
        type: '',
      );

  /// Whether a fresh [listing] of folder [path] from the server shows changes
  /// the offline copies have not caught up with.
  bool isStale(String path, Resource listing) {
    final p = normalizePath(path);
    if (!listing.item.isDir || !covers(p)) return false;
    final names = <String>{};
    for (final child in listing.items) {
      final childPath = joinPath(p, child.name);
      names.add(childPath);
      final entry = _entries[childPath];
      if (entry == null) return true;
      if (!child.isDir &&
          (entry.local == null || !_sameVersion(entry.item, child))) {
        return true;
      }
    }
    return _entries.keys
        .any((k) => parentOf(k) == p && k != p && !names.contains(k));
  }

  static bool _sameVersion(FileItem a, FileItem b) =>
      a.isDir == b.isDir &&
      a.size == b.size &&
      a.modified.millisecondsSinceEpoch == b.modified.millisecondsSinceEpoch;

  /// Marks [path] to be kept offline. [sync] downloads it.
  Future<void> pin(String path) async {
    _pins.add(normalizePath(path));
    await _save();
  }

  /// Stops keeping [path] offline and deletes the copies no other pin keeps.
  Future<void> unpin(String path) async {
    _pins.remove(normalizePath(path));
    await _prune((key) => covers(key));
    await _save();
  }

  /// Forgets [path] and everything below it, after it was deleted.
  Future<void> forget(String path) async {
    final p = normalizePath(path);
    _pins.removeWhere((pin) => _isAtOrBelow(pin, p));
    await _prune((key) => !_isAtOrBelow(key, p));
    await _save();
  }

  /// Follows a rename or move of [from] to [to]: pins move along, and copies
  /// are kept as long as a pin still covers their new place.
  Future<void> moved(String from, String to) async {
    final f = normalizePath(from), t = normalizePath(to);
    String rebase(String path) => t + path.substring(f.length);
    final pins = _pins.where((pin) => _isAtOrBelow(pin, f)).toList();
    for (final pin in pins) {
      _pins
        ..remove(pin)
        ..add(rebase(pin));
    }
    final keys = _entries.keys.where((k) => _isAtOrBelow(k, f)).toList();
    final moved = <String, OfflineEntry>{};
    for (final key in keys) {
      final entry = _entries.remove(key)!;
      final newPath = rebase(key);
      var local = entry.local;
      final newName = baseName(newPath);
      if (local != null && entry.item.name != newName) {
        // Keep the copy's name in step, for apps that go by the name.
        final dir = local.substring(0, local.indexOf('/'));
        final old = File('$_filesPath/$local');
        if (await old.exists()) await old.rename('$_filesPath/$dir/$newName');
        local = '$dir/$newName';
      }
      moved[newPath] = OfflineEntry(entry.item.movedTo(newPath), local: local);
    }
    _entries.addAll(moved);
    await _prune((key) => covers(key));
    await _save();
  }

  static bool _isAtOrBelow(String path, String dir) =>
      path == dir || path.startsWith(dir == '/' ? '/' : '$dir/');

  /// Removes the entries [keep] rejects, with their copies.
  Future<void> _prune(bool Function(String key) keep) async {
    final gone = _entries.keys.where((k) => !keep(k)).toList();
    for (final key in gone) {
      await _deleteCopy(_entries.remove(key)!);
    }
  }

  Future<void> _deleteCopy(OfflineEntry entry) async {
    final local = entry.local;
    if (local == null) return;
    final dir =
        Directory('$_filesPath/${local.substring(0, local.indexOf('/'))}');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Already gone or held open by another app; the space is reclaimed
      // with the app's data at the latest.
    }
  }

  /// Brings the copies of every pin up to date with the server.
  ///
  /// Throws [ApiException] without a status code when the server cannot be
  /// reached; what was downloaded until then is kept. [onChange] is called
  /// whenever a copy was added or removed.
  Future<void> sync(FileBrowserApi api, {void Function()? onChange}) async {
    for (final pin in pins) {
      if (!_pins.contains(pin)) continue; // Removed while syncing.
      final seen = <String>{};
      try {
        await _syncPath(api, pin, seen, onChange);
      } on ApiException catch (e) {
        if (e.statusCode == null) {
          await _save();
          rethrow;
        }
        if (e.statusCode != 404) continue; // Keep what is there.
        _pins.remove(pin); // Deleted on the server.
      }
      // Drop what is no longer on the server under this pin, unless another
      // pin still keeps it.
      await _prune((key) =>
          covers(key) &&
          (!_isAtOrBelow(key, pin) ||
              seen.contains(key) ||
              pinCovering(key) != pin));
      await _save();
      onChange?.call();
    }
  }

  Future<void> _syncPath(FileBrowserApi api, String path, Set<String> seen,
      void Function()? onChange) async {
    final resource = await api.fetch(path);
    final item = resource.item.movedTo(path);
    if (!item.isDir) {
      await _syncFile(api, item, seen, onChange);
      return;
    }
    seen.add(path);
    _entries[path] = OfflineEntry(item);
    for (final child in resource.items) {
      final childPath = joinPath(path, child.name);
      try {
        if (child.isDir) {
          await _syncPath(api, childPath, seen, onChange);
        } else {
          await _syncFile(api, child.movedTo(childPath), seen, onChange);
        }
      } on ApiException catch (e) {
        if (e.statusCode == null) rethrow;
        // 404: deleted since the listing. Anything else (no permission, a
        // server error): keep the copies that are there.
        if (e.statusCode != 404) {
          seen.addAll(_entries.keys.where((k) => _isAtOrBelow(k, childPath)));
        }
      }
    }
  }

  Future<void> _syncFile(FileBrowserApi api, FileItem item, Set<String> seen,
      void Function()? onChange) async {
    seen.add(item.path);
    final old = _entries[item.path];
    if (old?.local != null &&
        _sameVersion(old!.item, item) &&
        localFile(item.path) != null) {
      return;
    }
    final oldLocal = old?.local;
    final dir = oldLocal != null
        ? oldLocal.substring(0, oldLocal.indexOf('/'))
        : '${_next++}';
    final local = '$dir/${item.name}';
    final target = File('$_filesPath/$local');
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    try {
      await api.download(item.path, part.path);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    }
    if (!covers(item.path)) {
      // Unpinned while it downloaded.
      await part.delete();
      return;
    }
    if (oldLocal != null && oldLocal != local) {
      final stale = File('$_filesPath/$oldLocal');
      if (await stale.exists()) await stale.delete();
    }
    await part.rename(target.path);
    _entries[item.path] = OfflineEntry(item, local: local);
    await _save();
    onChange?.call();
  }
}
