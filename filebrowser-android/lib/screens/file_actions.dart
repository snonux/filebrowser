import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../app_routes.dart';
import '../models/models.dart';
import '../navigation_key.dart';
import '../providers/bookmarks_provider.dart';
import '../providers/device_files_provider.dart';
import '../providers/external_edits_provider.dart';
import '../providers/file_operations_provider.dart';
import '../providers/files_provider.dart';
import '../providers/local_files_provider.dart';
import '../providers/offline_provider.dart';
import '../providers/session_provider.dart';
import '../services/file_operations.dart';
import '../utils/format.dart';
import 'folder_picker_screen.dart';
import 'local_actions.dart';
import 'share_dialog.dart';

/// Shows a short message at the bottom of the screen.
void showMessage(String message, {SnackBarAction? action}) {
  appMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}

/// Asks for a name; returns null on cancel.
Future<String?> askName(BuildContext context,
    {required String title, required String action, String initial = ''}) {
  final controller = TextEditingController(text: initial);
  // Select the name without its extension, as file managers do.
  final dot = initial.lastIndexOf('.');
  controller.selection = TextSelection(
      baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final name = controller.text.trim();
        if (isValidName(name)) Navigator.pop(context, name);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: Text(action)),
        ],
      );
    },
  );
}

Future<bool> confirm(BuildContext context,
    {required String title, String? message, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}

/// File operations shared by the browser, search and viewer screens.
///
/// It holds the [ProviderContainer] rather than a widget's ref, so uploads
/// and downloads keep reporting progress after the screen that started them
/// is closed.
class FileActions {
  FileActions(BuildContext context)
      : ref = ProviderScope.containerOf(context, listen: false);

  final ProviderContainer ref;

  FileOperation _begin() => ref
      .read(fileOperationsProvider)
      .begin(ref.read(sessionProvider).valueOrNull);

  void _report(OperationResult<dynamic> result, {String prefix = ''}) {
    if (result.error != null) showMessage('$prefix${result.error!.message}');
  }

  void _refresh(String dir) =>
      ref.invalidate(resourceProvider(normalizePath(dir)));

  /// Lets offline copies and bookmarks follow a rename or move.
  Future<void> _moved(String from, String to) async {
    await ref.read(offlineProvider.notifier).moved(from, to);
    await ref
        .read(bookmarksProvider.notifier)
        .moved(BookmarkPlace.server, from, to);
  }

  /// Drops offline copies and bookmarks of a deleted item.
  Future<void> _deleted(String path) async {
    await ref.read(offlineProvider.notifier).deleted(path);
    await ref
        .read(bookmarksProvider.notifier)
        .deleted(BookmarkPlace.server, path);
  }

  /// Bookmarks [item], or removes its bookmark, and says so.
  Future<void> toggleBookmark(FileItem item) async {
    final bookmarks = ref.read(bookmarksProvider.notifier);
    final existing = bookmarks.find(BookmarkPlace.server, item.path);
    final name = item.path == '/' ? 'Home' : item.name;
    if (existing != null) {
      await bookmarks.remove(existing);
      showMessage('Removed the bookmark of $name');
    } else {
      await bookmarks.addServer(item);
      showMessage('Bookmarked $name');
    }
  }

  /// Whether [open] shows the file in the app rather than another app.
  static bool opensInApp(FileItem item) =>
      item.isImage || item.isPdf || item.isVideo || item.isAudio || item.isText;

  /// The offline copy of [item], when there is one.
  File? _offlineCopy(FileItem item) =>
      ref.read(offlineProvider).store?.localFile(item.path);

  /// Hands [item]'s offline copy to another app. Returns false when there is
  /// no copy.
  Future<bool> _openCopy(FileItem item) async {
    final copy = _offlineCopy(item);
    if (copy == null) return false;
    try {
      final error =
          await ref.read(fileOperationsProvider).deviceFiles.open(copy);
      if (error != null) showMessage('Cannot open ${item.name}: $error');
    } catch (error) {
      showMessage('Cannot open ${item.name}: $error');
    }
    return true;
  }

  /// Opens a folder, image, PDF, video, audio or text file in the app;
  /// anything else is handed to another app: its offline copy, or else a
  /// fresh download.
  Future<void> open(BuildContext context, FileItem item) async {
    if (item.isDir) {
      context.push(AppRoutes.files(item.path));
    } else if (item.isImage) {
      context.push(AppRoutes.view(item.path));
    } else if (item.isPdf) {
      context.push(AppRoutes.pdf(item.path));
    } else if (item.isVideo || item.isAudio) {
      context.push(AppRoutes.play(item.path));
    } else if (item.isText) {
      context.push(AppRoutes.edit(item.path));
    } else if (!await _openCopy(item)) {
      await download(item, openWhenDone: true);
    }
  }

  /// Opens a path known only by name (from search): fetches it first.
  Future<void> openPath(BuildContext context, String path) async {
    final operation = _begin();
    try {
      final result = await operation.fetch(path);
      if (result.succeeded && context.mounted) {
        final item = result.value!;
        if (opensInApp(item) || item.isDir) {
          await open(context, item);
        } else if (!await _openCopy(item)) {
          await _download(operation, item, openWhenDone: true);
        }
      } else {
        _report(result);
      }
    } finally {
      operation.close();
    }
  }

  Future<void> createFolder(BuildContext context, String dir) async {
    final operation = _begin();
    try {
      final name =
          await askName(context, title: 'New folder', action: 'Create');
      if (name == null) return;
      final result = await operation.createFolder(joinPath(dir, name));
      if (result.succeeded) _refresh(dir);
      _report(result);
    } finally {
      operation.close();
    }
  }

  Future<void> createFile(BuildContext context, String dir) async {
    final operation = _begin();
    try {
      final name = await askName(context, title: 'New file', action: 'Create');
      if (name == null) return;
      final path = joinPath(dir, name);
      final result = await operation.createFile(path);
      if (result.succeeded) {
        _refresh(dir);
        if (context.mounted) context.push(AppRoutes.edit(path));
      }
      _report(result);
    } finally {
      operation.close();
    }
  }

  Future<void> rename(BuildContext context, FileItem item) async {
    final operation = _begin();
    try {
      final name = await askName(context,
          title: 'Rename', action: 'Rename', initial: item.name);
      if (name == null || name == item.name) return;
      final dir = parentOf(item.path);
      final target = joinPath(dir, name);
      final result = await operation.transfer(item.path, target, copy: false);
      if (result.succeeded) {
        _refresh(dir);
        await _moved(item.path, target);
      }
      _report(result);
    } finally {
      operation.close();
    }
  }

  /// Copies or moves [items] into a folder the user picks.
  Future<void> transferTo(BuildContext context, List<FileItem> items,
      {required bool copy}) async {
    if (items.isEmpty) return;
    final operation = _begin();
    try {
      final source = parentOf(items.first.path);
      final target = await Navigator.of(context).push<String>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FolderPickerScreen(
            start: source, action: copy ? 'Copy here' : 'Move here'),
      ));
      if (target == null || !context.mounted || operation.cancelled) return;
      var done = 0;
      for (final item in items) {
        if (operation.cancelled) return;
        final dest = joinPath(target, item.name);
        if (!copy && normalizePath(dest) == normalizePath(item.path)) continue;
        var result = await operation.transfer(item.path, dest, copy: copy);
        if (result.status == OperationStatus.conflict && context.mounted) {
          final replace = await confirm(context,
              title: '"${item.name}" exists',
              message: 'Replace the item in the destination?',
              action: 'Replace');
          if (!replace) continue;
          result = await operation.transfer(item.path, dest,
              copy: copy, override: true);
        }
        if (result.succeeded) {
          done++;
          if (!copy) await _moved(item.path, dest);
        }
        _report(result);
      }
      if (operation.cancelled) return;
      _refresh(source);
      _refresh(target);
      if (done > 0) {
        showMessage('${copy ? 'Copied' : 'Moved'} $done '
            '${done == 1 ? 'item' : 'items'} to ${target == '/' ? 'Home' : baseName(target)}');
      }
    } finally {
      operation.close();
    }
  }

  Future<bool> delete(BuildContext context, List<FileItem> items) async {
    if (items.isEmpty) return false;
    final operation = _begin();
    try {
      final ok = await confirm(
        context,
        title: items.length == 1
            ? 'Delete "${items.first.name}"?'
            : 'Delete ${items.length} items?',
        message: 'This cannot be undone.',
        action: 'Delete',
      );
      if (!ok || operation.cancelled) return false;
      for (final item in items) {
        final result = await operation.delete(item.path);
        if (result.status == OperationStatus.cancelled) return false;
        if (result.succeeded) await _deleted(item.path);
        _report(result, prefix: '${item.name}: ');
      }
      _refresh(parentOf(items.first.path));
      return true;
    } finally {
      operation.close();
    }
  }

  /// Picks files on the device and uploads them into [dir] with tus.
  Future<void> upload(BuildContext context, String dir) async {
    final operation = _begin();
    try {
      final result = await operation.pickUploads();
      if (!result.succeeded) {
        _report(result);
        return;
      }
      for (final file in result.value!) {
        if (!context.mounted || operation.cancelled) return;
        await _uploadFile(context, operation, file, dir);
      }
    } finally {
      operation.close();
    }
  }

  /// Uploads [file] into [dir]; returns whether it arrived.
  Future<bool> uploadFile(BuildContext context, File file, String dir) async {
    final operation = _begin();
    try {
      return await _uploadFile(context, operation, file, dir);
    } finally {
      operation.close();
    }
  }

  Future<bool> _uploadFile(BuildContext context, FileOperation operation,
      File file, String dir) async {
    final result = await operation.upload(file, dir, replace: (name) async {
      if (!context.mounted) return false;
      return confirm(context,
          title: '"$name" exists',
          message: 'Replace the file on the server?',
          action: 'Replace');
    });
    if (!operation.cancelled) _refresh(dir);
    _report(result, prefix: 'Upload of ${file.uri.pathSegments.last} failed: ');
    return result.succeeded;
  }

  /// Uploads the phone file or folder [local] into the server folder [dir];
  /// a folder with everything in it. Returns whether all of it arrived.
  Future<bool> uploadLocal(
      BuildContext context, FileItem local, String dir) async {
    final operation = _begin();
    try {
      if (!local.isDir) {
        return await _uploadFile(context, operation, File(local.path), dir);
      }
      final root = joinPath(dir, local.name);
      final tree = await ref.read(localFilesProvider).walk(local.path);
      for (final folder in ['', ...tree.folders]) {
        final result = await operation
            .createFolder(folder.isEmpty ? root : joinPath(root, folder));
        // An existing folder is merged into.
        if (!result.succeeded && result.status != OperationStatus.conflict) {
          _report(result, prefix: 'Upload of ${local.name} failed: ');
          return false;
        }
      }
      var ok = true;
      for (final file in tree.files) {
        if (!context.mounted || operation.cancelled) return false;
        final parent = parentOf('/$file');
        ok &= await _uploadFile(context, operation, File('${local.path}/$file'),
            joinPath(root, parent));
      }
      _refresh(dir);
      return ok;
    } on FileSystemException catch (e) {
      showMessage(
          'Upload of ${local.name} failed: ${e.osError?.message ?? e.message}');
      return false;
    } finally {
      operation.close();
    }
  }

  /// Saves [items] into a phone folder the user picks: files as they are,
  /// folders with everything in them. With [move], each item is deleted on
  /// the server once it is saved.
  Future<void> saveToPhone(BuildContext context, List<FileItem> items,
      {bool move = false}) async {
    if (items.isEmpty) return;
    final operation = _begin();
    try {
      final target = await pickPhoneFolder(context,
          action: move ? 'Move here' : 'Save here');
      if (target == null || operation.cancelled) return;
      final roots = await ref.read(storageRootsProvider.future);
      var done = 0;
      for (final item in items) {
        if (operation.cancelled) return;
        final result = await operation.downloadInto(item, target);
        if (!result.succeeded) {
          _report(result, prefix: 'Saving ${item.name} failed: ');
          continue;
        }
        if (move) {
          final deleted = await operation.delete(item.path);
          if (!deleted.succeeded) {
            _report(deleted, prefix: 'Saved, but cannot delete ${item.name}: ');
            continue;
          }
          await _deleted(item.path);
        }
        done++;
      }
      ref.invalidate(localListingProvider(normalizePath(target)));
      if (move) _refresh(parentOf(items.first.path));
      if (done > 0) {
        showMessage('${move ? 'Moved' : 'Saved'} $done '
            '${done == 1 ? 'item' : 'items'} to '
            '${phoneFolderLabel(roots, target)} on this phone');
      }
    } finally {
      operation.close();
    }
  }

  /// Saves a file (or a folder as a zip) into the device's download folder.
  Future<File?> download(FileItem item, {bool openWhenDone = false}) async {
    final operation = _begin();
    try {
      return await _download(operation, item, openWhenDone: openWhenDone);
    } finally {
      operation.close();
    }
  }

  Future<File?> _download(FileOperation operation, FileItem item,
      {required bool openWhenDone}) async {
    final result = await operation.download(item);
    final fileName = item.isDir ? '${item.name}.zip' : item.name;
    if (!result.succeeded) {
      _report(result, prefix: 'Download of $fileName failed: ');
      return null;
    }
    final target = result.value!;
    // A snackbar can outlive this operation. Capture the device service here;
    // opening a saved local file does not perform an account-bound request.
    final deviceFiles = ref.read(fileOperationsProvider).deviceFiles;
    Future<void> openIt() async {
      try {
        final error = await deviceFiles.open(target);
        if (error != null) showMessage('Cannot open $fileName: $error');
      } catch (error) {
        showMessage('Cannot open $fileName: $error');
      }
    }

    if (openWhenDone) {
      final opened = await operation.open(target);
      _report(opened, prefix: 'Cannot open $fileName: ');
      if (opened.succeeded && opened.value != null) {
        showMessage('Cannot open $fileName: ${opened.value}');
      }
    } else {
      showMessage(
          'Saved ${target.uri.pathSegments.last} (${formatSize(target.lengthSync())})',
          action: SnackBarAction(label: 'Open', onPressed: openIt));
    }
    return target;
  }

  /// Shows the item's public links and lets the user add or delete one.
  Future<void> share(BuildContext context, FileItem item) => showDialog<void>(
      context: context, builder: (_) => ShareDialog(item: item));

  /// Keeps [item] (a file, or a folder with everything in it) on the device
  /// so it can be opened while the server cannot be reached.
  Future<void> makeOffline(FileItem item) async {
    showMessage('Making ${item.name} available offline');
    final offline = ref.read(offlineProvider.notifier);
    await offline.pin(item);
    final error = ref.read(offlineProvider).error;
    if (error != null) {
      showMessage('${item.name} will be downloaded later: $error');
    } else if (ref.read(offlineProvider).store?.isPinned(item.path) ?? false) {
      showMessage('${item.name} is available offline');
    }
  }

  /// Stops keeping [path] on the device and deletes its copies.
  Future<void> removeOffline(String path) async {
    await ref.read(offlineProvider.notifier).unpin(path);
    showMessage(
        '${path == '/' ? 'Home' : baseName(path)} is no longer available offline');
  }

  /// Whether [item] can be handed to an editor app and saved back.
  bool canEditExternally(FileItem item) {
    final perm = ref.read(sessionProvider).valueOrNull?.perm;
    return item.type == 'text' && perm != null && perm.modify && perm.download;
  }

  /// The label of the action that edits a text file in another app.
  Future<String> editLabel() async {
    final editor = await ref.read(deviceFilesProvider).editorName();
    return editor == null ? 'Edit in another app' : 'Edit in $editor';
  }

  /// Opens [item] in TurboNotes (or another editor app); every save there
  /// is uploaded back to the server.
  Future<void> editExternally(FileItem item) async {
    final session = ref.read(sessionProvider).valueOrNull;
    if (session == null) return;
    final error =
        await ref.read(externalEditsProvider).start(session.api, item.path);
    if (error != null) showMessage('Cannot edit ${item.name}: $error');
  }

  Future<void> info(BuildContext context, FileItem item) => showDialog<void>(
      context: context, builder: (_) => _InfoDialog(item: item));

  /// The actions menu for one item, limited to what the account may do.
  Future<void> showMenu(BuildContext context, FileItem item) async {
    final editLabel = canEditExternally(item) ? await this.editLabel() : null;
    if (!context.mounted) return;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: Text(item.name,
                  style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(item.isDir
                  ? 'Folder'
                  : '${formatSize(item.size)} · ${formatDate(item.modified)}'),
            ),
            ..._menuTiles(context, sheet, item, editLabel),
          ]),
        ),
      ),
    );
  }

  /// The entries of [showMenu]. Each closes the [sheet] before it runs, so
  /// the action's own dialogs open from [context], which outlives the sheet.
  List<Widget> _menuTiles(BuildContext context, BuildContext sheet,
      FileItem item, String? editLabel) {
    final perm = ref.read(requireSessionProvider).perm;
    final offline = ref.read(offlineProvider).store;
    final keptBy = offline?.pinCovering(item.path);
    final bookmarked = ref
            .read(bookmarksProvider.notifier)
            .find(BookmarkPlace.server, item.path) !=
        null;
    Widget tile(IconData icon, String label, Future<void> Function() run) =>
        ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.pop(sheet);
            run();
          },
        );
    return [
      tile(Icons.open_in_new, 'Open', () => open(context, item)),
      if (editLabel != null)
        tile(Icons.edit_note, editLabel, () => editExternally(item)),
      if (perm.download && opensInApp(item))
        tile(Icons.open_in_browser, 'Open with another app', () async {
          if (!await _openCopy(item)) await download(item, openWhenDone: true);
        }),
      if (perm.download)
        tile(Icons.download, item.isDir ? 'Download as zip' : 'Download',
            () => download(item)),
      if (perm.download)
        tile(Icons.save_alt, 'Save to phone…',
            () => saveToPhone(context, [item])),
      if (perm.download && perm.delete)
        tile(Icons.phone_android, 'Move to phone…',
            () => saveToPhone(context, [item], move: true)),
      if (bookmarked)
        tile(Icons.bookmark_remove_outlined, 'Remove bookmark',
            () => toggleBookmark(item))
      else
        tile(Icons.bookmark_add_outlined, 'Add bookmark',
            () => toggleBookmark(item)),
      if (offline != null && keptBy == item.path)
        tile(Icons.offline_pin, 'Remove offline copy',
            () => removeOffline(item.path))
      else if (keptBy != null)
        ListTile(
          enabled: false,
          leading: const Icon(Icons.offline_pin),
          title: const Text('Available offline'),
          subtitle:
              Text('Kept with ${keptBy == '/' ? 'Home' : baseName(keptBy)}'),
        )
      else if (offline != null && perm.download)
        tile(Icons.offline_pin_outlined, 'Make available offline',
            () => makeOffline(item)),
      if (perm.rename)
        tile(Icons.drive_file_rename_outline, 'Rename',
            () => rename(context, item)),
      if (perm.create)
        tile(Icons.copy, 'Copy to…',
            () => transferTo(context, [item], copy: true)),
      if (perm.rename)
        tile(Icons.drive_file_move_outline, 'Move to…',
            () => transferTo(context, [item], copy: false)),
      if (perm.canShare)
        tile(Icons.share, 'Share link', () => share(context, item)),
      tile(Icons.info_outline, 'Info', () => info(context, item)),
      if (perm.delete)
        tile(Icons.delete_outline, 'Delete', () => delete(context, [item])),
    ];
  }
}

class _InfoDialog extends ConsumerStatefulWidget {
  const _InfoDialog({required this.item});

  final FileItem item;

  @override
  ConsumerState<_InfoDialog> createState() => _InfoDialogState();
}

class _InfoDialogState extends ConsumerState<_InfoDialog> {
  String? _checksum;
  bool _working = false;

  Future<void> _computeChecksum() async {
    setState(() => _working = true);
    try {
      final sum = await ref
          .read(requireSessionProvider)
          .api
          .checksum(widget.item.path, 'sha256');
      if (!mounted) return;
      setState(() => _checksum = sum);
    } on ApiException catch (e) {
      showMessage(e.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            SelectableText(value),
          ]),
        );
    return AlertDialog(
      title: Text(item.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('Path', item.path),
            row(
                'Type',
                item.isDir
                    ? 'Folder'
                    : (item.type.isEmpty ? 'File' : item.type)),
            if (!item.isDir)
              row('Size', '${formatSize(item.size)} (${item.size} bytes)'),
            row('Modified', formatDate(item.modified)),
            if (_checksum != null) row('SHA-256', _checksum!),
          ],
        ),
      ),
      actions: [
        if (!item.isDir && _checksum == null)
          TextButton(
            onPressed: _working ? null : _computeChecksum,
            child: Text(_working ? 'Computing…' : 'SHA-256'),
          ),
        if (_checksum != null)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _checksum!));
              showMessage('Checksum copied');
            },
            child: const Text('Copy checksum'),
          ),
        FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}
