import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import 'device_files.dart';

/// One file another app (TurboNotes) is editing: a local copy it writes to,
/// and the server file each change is uploaded to.
class ExternalEdit {
  ExternalEdit._(this.api, this.path, this.local, this._base);

  final FileBrowserApi api;

  /// The server file that was opened.
  final String path;

  /// The copy the editor writes to.
  final File local;

  /// The server file changes go to: [path], or a conflict copy next to it
  /// once [path] was changed on the server by someone else.
  late String target = path;

  /// The content the server holds as far as this edit knows.
  Uint8List _base;

  /// The local copy's size and time when last uploaded (or downloaded).
  int _length = -1;
  DateTime? _modified;

  /// A change seen at the last check, uploaded once it holds still for one
  /// more check, so a save still being written is never uploaded half done.
  int? _pendingLength;
  DateTime? _pendingModified;

  /// The last error reported, so a failure that repeats is reported once.
  String? _error;

  bool get conflicted => target != path;
}

/// Hands text files to another app for editing ("Edit in TurboNotes") and
/// uploads each change it saves.
///
/// The file is downloaded to [DeviceFiles.editDirectory] and lent to the
/// editor, which writes its saves straight into the copy. Every [interval],
/// and when the app returns to the foreground ([check]), changed copies are
/// uploaded. If someone else changed the file on the server meanwhile, the
/// edits go to a conflict copy next to it instead of overwriting theirs.
class ExternalEdits {
  ExternalEdits({
    required this.deviceFiles,
    required this.onMessage,
    required this.onUploaded,
    this.interval = const Duration(seconds: 2),
  });

  final DeviceFiles deviceFiles;

  /// Tells the user what happened (saved, conflict, failure).
  final void Function(String message) onMessage;

  /// Called with the folder of a file that was uploaded, to refresh it.
  final void Function(String dir) onUploaded;

  final Duration interval;

  final _edits = <String, ExternalEdit>{};
  Timer? _timer;
  Future<void>? _checking;
  bool _disposed = false;

  /// The edits in progress, by server path.
  @visibleForTesting
  Map<String, ExternalEdit> get edits => Map.unmodifiable(_edits);

  /// Downloads [path] and opens it in the editor app. Returns an error
  /// message, or null once the editor was started.
  Future<String?> start(FileBrowserApi api, String path) async {
    final Uint8List bytes;
    try {
      bytes = await api.readBytes(path);
    } catch (error) {
      return ApiException.from(error).message;
    }
    // Edits still waiting for upload from an earlier start are kept: the
    // new copy starts from the server's version, which may already be it.
    await check();
    if (_disposed) return 'Signed out';
    final old = _edits.remove(path);
    if (old != null) _remove(old);
    final dir = await deviceFiles.editDirectory();
    // One folder per edit keeps the file's own name for the editor.
    final folder = await dir.createTemp('e');
    final local = File('${folder.path}/${baseName(path)}');
    await local.writeAsBytes(bytes, flush: true);
    final edit = ExternalEdit._(api, path, local, bytes);
    _remember(edit);
    _edits[path] = edit;
    final error = await deviceFiles.edit(local);
    if (error != null) {
      _edits.remove(path);
      _remove(edit);
      return error;
    }
    _timer ??= Timer.periodic(interval, (_) => check());
    return null;
  }

  /// Uploads every copy the editor changed since the last check.
  Future<void> check() {
    final running = _checking;
    if (running != null) return running;
    final checking = () async {
      for (final edit in _edits.values.toList()) {
        if (_disposed) return;
        await _sync(edit);
      }
    }();
    _checking = checking;
    return checking.whenComplete(() => _checking = null);
  }

  void _remember(ExternalEdit edit) {
    final stat = edit.local.statSync();
    edit._length = stat.size;
    edit._modified = stat.modified;
  }

  Future<void> _sync(ExternalEdit edit) async {
    final FileStat stat;
    try {
      stat = await edit.local.stat();
    } on FileSystemException {
      return;
    }
    if (stat.type == FileSystemEntityType.notFound) {
      // The cache was cleared; nothing left to upload.
      _edits.remove(edit.path);
      return;
    }
    if (stat.size == edit._length && stat.modified == edit._modified) return;
    if (stat.size != edit._pendingLength ||
        stat.modified != edit._pendingModified) {
      edit._pendingLength = stat.size;
      edit._pendingModified = stat.modified;
      return;
    }
    final name = baseName(edit.path);
    try {
      final bytes = await edit.local.readAsBytes();
      if (listEquals(bytes, edit._base)) {
        edit._length = stat.size;
        edit._modified = stat.modified;
        return;
      }
      if (!edit.conflicted) {
        final onServer = await edit.api.readBytes(edit.path);
        if (!listEquals(onServer, edit._base) && !listEquals(onServer, bytes)) {
          edit.target = conflictPath(edit.path, DateTime.now());
          await edit.api.createFile(edit.target, content: bytes);
          onMessage('$name was changed on the server meanwhile; your edits '
              'are saved as ${baseName(edit.target)}');
        }
      }
      if (edit.conflicted) {
        await edit.api.saveBytes(edit.target, bytes);
      } else {
        await edit.api.saveBytes(edit.path, bytes);
        onMessage('Saved $name');
      }
      edit._base = bytes;
      edit._length = stat.size;
      edit._modified = stat.modified;
      edit._error = null;
      onUploaded(parentOf(edit.path));
    } catch (error) {
      // Tried again at the next check: the copy still differs.
      final message = ApiException.from(error).message;
      if (message != edit._error) {
        edit._error = message;
        onMessage('Could not save $name: $message. Retrying.');
      }
    }
  }

  void _remove(ExternalEdit edit) {
    try {
      edit.local.parent.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for Android to clear with the rest of the cache.
    }
  }

  /// Stops watching edits made for another account; the copies stay in the
  /// cache until Android clears it.
  void sessionChanged(FileBrowserApi? api) {
    _edits.removeWhere((_, edit) => !identical(edit.api, api));
    if (_edits.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Where edits go when the file changed on the server meanwhile:
/// `notes.md` becomes `notes (edited 2026-10-14 034215).md`.
String conflictPath(String path, DateTime at) {
  final name = baseName(path);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  return joinPath(parentOf(path), '$stem (edited $stamp)$ext');
}
