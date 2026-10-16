import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/paths.dart';
import '../app_routes.dart';
import '../models/models.dart';
import '../providers/bookmarks_provider.dart';
import '../providers/device_files_provider.dart';
import '../providers/local_files_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
import '../services/local_files.dart';
import '../utils/format.dart';
import 'file_actions.dart';
import 'folder_picker_screen.dart';
import 'local_folder_picker_screen.dart';

/// Makes sure the app may manage the phone's files, asking the user when it
/// may not yet. Returns whether it may.
Future<bool> ensureStorageAccess(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final device = container.read(deviceFilesProvider);
  if (await device.hasStorageAccess()) return true;
  if (!context.mounted) return false;
  final ask = await confirm(context,
      title: 'Allow access to your files?',
      message: 'To manage the files on this phone, File Browser needs '
          'access to all files. Android opens the setting next; turn on '
          '"Allow access to manage all files" and come back.',
      action: 'Continue');
  if (!ask) return false;
  final granted = await device.requestStorageAccess();
  container.invalidate(storageAccessProvider);
  if (!granted) showMessage('File Browser has no access to your files');
  return granted;
}

/// The label of a phone folder for messages: its name, or the volume's.
String phoneFolderLabel(List<StorageRoot> roots, String path) {
  final root = rootOf(roots, path);
  return root != null && root.path == path ? root.name : baseName(path);
}

/// Lets the user pick a phone folder, starting at [start] or else the last
/// one used. Remembers the choice. Returns null on cancel.
Future<String?> pickPhoneFolder(BuildContext context,
    {required String action, String? start}) async {
  if (!await ensureStorageAccess(context) || !context.mounted) return null;
  final container = ProviderScope.containerOf(context, listen: false);
  final roots = await container.read(storageRootsProvider.future);
  if (roots.isEmpty) {
    showMessage('No storage found on this phone');
    return null;
  }
  var from = start ?? container.read(preferencesProvider).phoneFolder;
  if (from.isEmpty ||
      rootOf(roots, from) == null ||
      !Directory(from).existsSync()) {
    from = roots.first.path;
  }
  if (!context.mounted) return null;
  final picked = await Navigator.of(context).push<String>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => LocalFolderPickerScreen(start: from, action: action),
  ));
  if (picked != null) {
    await container.read(preferencesProvider.notifier).setPhoneFolder(picked);
  }
  return picked;
}

/// Operations on the phone's own files, and sending them to the server.
class LocalActions {
  LocalActions(BuildContext context)
      : ref = ProviderScope.containerOf(context, listen: false),
        _server = FileActions(context);

  final ProviderContainer ref;
  final FileActions _server;

  LocalFiles get _files => ref.read(localFilesProvider);
  BookmarksNotifier get _bookmarks => ref.read(bookmarksProvider.notifier);

  /// Bookmarks [item], or removes its bookmark, and says so.
  Future<void> toggleBookmark(FileItem item) async {
    final existing = _bookmarks.find(BookmarkPlace.phone, item.path);
    if (existing != null) {
      await _bookmarks.remove(existing);
      showMessage('Removed the bookmark of ${item.name}');
    } else {
      await _bookmarks.addPhone(item);
      showMessage('Bookmarked ${item.name}');
    }
  }

  void _refresh(String dir) =>
      ref.invalidate(localListingProvider(normalizePath(dir)));

  /// Runs [action] and reports a failure; returns whether it worked.
  Future<bool> _try(Future<void> Function() action,
      {String prefix = ''}) async {
    try {
      await action();
      return true;
    } on LocalConflict catch (e) {
      showMessage('$prefix$e');
    } on FileSystemException catch (e) {
      final reason = e.osError?.message ?? e.message;
      showMessage('$prefix$reason');
    }
    return false;
  }

  /// Opens a folder in the app, and a file in the app Android picks.
  Future<void> open(BuildContext context, FileItem item) async {
    if (item.isDir) {
      context.push(AppRoutes.local(item.path));
      return;
    }
    try {
      final error = await ref.read(deviceFilesProvider).open(File(item.path));
      if (error != null) showMessage('Cannot open ${item.name}: $error');
    } catch (error) {
      showMessage('Cannot open ${item.name}: $error');
    }
  }

  Future<void> createFolder(BuildContext context, String dir) async {
    final name = await askName(context, title: 'New folder', action: 'Create');
    if (name == null) return;
    await _try(() => _files.createFolder(joinPath(dir, name)));
    _refresh(dir);
  }

  Future<void> rename(BuildContext context, FileItem item) async {
    final name = await askName(context,
        title: 'Rename', action: 'Rename', initial: item.name);
    if (name == null || name == item.name) return;
    final dir = parentOf(item.path);
    final target = joinPath(dir, name);
    if (await _try(() => _files.move(item.path, target))) {
      await _bookmarks.moved(BookmarkPlace.phone, item.path, target);
    }
    _refresh(dir);
  }

  /// Copies or moves [items] into another phone folder the user picks.
  Future<void> transferTo(BuildContext context, List<FileItem> items,
      {required bool copy}) async {
    if (items.isEmpty) return;
    final source = parentOf(items.first.path);
    final target = await pickPhoneFolder(context,
        action: copy ? 'Copy here' : 'Move here', start: source);
    if (target == null || !context.mounted) return;
    var done = 0;
    for (final item in items) {
      final dest = joinPath(target, item.name);
      if (!copy && normalizePath(dest) == normalizePath(item.path)) continue;
      Future<void> run({bool override = false}) => copy
          ? _files.copy(item.path, dest, override: override)
          : _files.move(item.path, dest, override: override);
      var ok = false;
      try {
        await run();
        ok = true;
      } on LocalConflict {
        if (!context.mounted) break;
        // Copying into the same folder makes a numbered copy instead.
        if (copy && normalizePath(dest) == normalizePath(item.path)) {
          final free = await _files.freeName(target, item.name);
          ok = await _try(() => _files.copy(item.path, free));
        } else if (await confirm(context,
            title: '"${item.name}" exists',
            message: 'Replace the item in the destination?',
            action: 'Replace')) {
          ok = await _try(() => run(override: true));
        }
      } on FileSystemException catch (e) {
        showMessage('${item.name}: ${e.osError?.message ?? e.message}');
      }
      if (ok) {
        done++;
        if (!copy) await _bookmarks.moved(BookmarkPlace.phone, item.path, dest);
      }
    }
    _refresh(source);
    _refresh(target);
    if (done > 0) {
      showMessage('${copy ? 'Copied' : 'Moved'} $done '
          '${done == 1 ? 'item' : 'items'} to ${baseName(target)}');
    }
  }

  Future<bool> delete(BuildContext context, List<FileItem> items) async {
    if (items.isEmpty) return false;
    final ok = await confirm(
      context,
      title: items.length == 1
          ? 'Delete "${items.first.name}"?'
          : 'Delete ${items.length} items?',
      message: 'They are deleted from this phone. This cannot be undone.',
      action: 'Delete',
    );
    if (!ok) return false;
    for (final item in items) {
      if (await _try(() => _files.delete(item.path),
          prefix: '${item.name}: ')) {
        await _bookmarks.deleted(BookmarkPlace.phone, item.path);
      }
    }
    _refresh(parentOf(items.first.path));
    return true;
  }

  /// Uploads [items] (files or whole folders) into a server folder the user
  /// picks. With [move], each item is deleted from the phone once all of it
  /// arrived.
  Future<void> sendToServer(BuildContext context, List<FileItem> items,
      {required bool move}) async {
    if (items.isEmpty) return;
    final start = ref.read(preferencesProvider).shareFolder;
    final target = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => FolderPickerScreen(
          start: start, action: move ? 'Move here' : 'Upload here'),
    ));
    if (target == null || !context.mounted) return;
    await ref.read(preferencesProvider.notifier).setShareFolder(target);
    var done = 0;
    for (final item in items) {
      if (!context.mounted) break;
      if (!await _server.uploadLocal(context, item, target)) continue;
      if (move &&
          !await _try(() => _files.delete(item.path),
              prefix: 'Uploaded, but cannot delete ${item.name}: ')) {
        continue;
      }
      if (move) await _bookmarks.deleted(BookmarkPlace.phone, item.path);
      done++;
    }
    _refresh(parentOf(items.first.path));
    if (done > 0) {
      showMessage('${move ? 'Moved' : 'Uploaded'} $done '
          '${done == 1 ? 'item' : 'items'} to '
          '${target == '/' ? 'Home' : baseName(target)} on the server');
    }
  }

  /// The actions menu for one phone file or folder.
  Future<void> showMenu(BuildContext context, FileItem item) {
    final canUpload =
        ref.read(sessionProvider).valueOrNull?.perm.create ?? false;
    final bookmarked = _bookmarks.find(BookmarkPlace.phone, item.path) != null;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        Widget tile(IconData icon, String label, Future<void> Function() run) =>
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                Navigator.pop(sheet);
                run();
              },
            );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                title: Text(item.name,
                    style: Theme.of(context).textTheme.titleMedium),
                subtitle: Text(item.isDir
                    ? 'Folder'
                    : '${formatSize(item.size)} · ${formatDate(item.modified)}'),
              ),
              tile(Icons.open_in_new, 'Open', () => open(context, item)),
              if (canUpload) ...[
                tile(Icons.cloud_upload_outlined, 'Upload to server…',
                    () => sendToServer(context, [item], move: false)),
                tile(Icons.drive_folder_upload_outlined, 'Move to server…',
                    () => sendToServer(context, [item], move: true)),
              ],
              if (bookmarked)
                tile(Icons.bookmark_remove_outlined, 'Remove bookmark',
                    () => toggleBookmark(item))
              else
                tile(Icons.bookmark_add_outlined, 'Add bookmark',
                    () => toggleBookmark(item)),
              tile(Icons.drive_file_rename_outline, 'Rename',
                  () => rename(context, item)),
              tile(Icons.copy, 'Copy to…',
                  () => transferTo(context, [item], copy: true)),
              tile(Icons.drive_file_move_outline, 'Move to…',
                  () => transferTo(context, [item], copy: false)),
              tile(Icons.delete_outline, 'Delete',
                  () => delete(context, [item])),
            ]),
          ),
        );
      },
    );
  }
}
