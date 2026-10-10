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
import '../providers/device_files_provider.dart';
import '../providers/files_provider.dart';
import '../providers/session_provider.dart';
import '../providers/transfers_provider.dart';
import '../utils/format.dart';
import 'folder_picker_screen.dart';
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

  FileBrowserApi get _api => ref.read(requireSessionProvider).api;

  void _refresh(String dir) =>
      ref.invalidate(resourceProvider(normalizePath(dir)));

  /// Opens a folder, image or text file in the app; anything else is
  /// downloaded and handed to another app.
  Future<void> open(BuildContext context, FileItem item) async {
    if (item.isDir) {
      context.push(AppRoutes.files(item.path));
    } else if (item.isImage) {
      context.push(AppRoutes.view(item.path));
    } else if (item.isText) {
      context.push(AppRoutes.edit(item.path));
    } else {
      await download(item, openWhenDone: true);
    }
  }

  /// Opens a path known only by name (from search): fetches it first.
  Future<void> openPath(BuildContext context, String path) async {
    try {
      final item = (await _api.fetch(path)).item;
      if (context.mounted) await open(context, item);
    } on ApiException catch (e) {
      showMessage(e.message);
    }
  }

  Future<void> createFolder(BuildContext context, String dir) async {
    final name = await askName(context, title: 'New folder', action: 'Create');
    if (name == null) return;
    try {
      await _api.createFolder(joinPath(dir, name));
      _refresh(dir);
    } on ApiException catch (e) {
      showMessage(e.message);
    }
  }

  Future<void> createFile(BuildContext context, String dir) async {
    final name = await askName(context, title: 'New file', action: 'Create');
    if (name == null) return;
    final path = joinPath(dir, name);
    try {
      await _api.createFile(path);
      _refresh(dir);
      if (context.mounted) context.push(AppRoutes.edit(path));
    } on ApiException catch (e) {
      showMessage(e.message);
    }
  }

  Future<void> rename(BuildContext context, FileItem item) async {
    final name = await askName(context,
        title: 'Rename', action: 'Rename', initial: item.name);
    if (name == null || name == item.name) return;
    final dir = parentOf(item.path);
    try {
      await _api.move(item.path, joinPath(dir, name));
      _refresh(dir);
    } on ApiException catch (e) {
      showMessage(e.message);
    }
  }

  /// Copies or moves [items] into a folder the user picks.
  Future<void> transferTo(BuildContext context, List<FileItem> items,
      {required bool copy}) async {
    if (items.isEmpty) return;
    final source = parentOf(items.first.path);
    final target = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => FolderPickerScreen(
          start: source, action: copy ? 'Copy here' : 'Move here'),
    ));
    if (target == null || !context.mounted) return;
    var done = 0;
    for (final item in items) {
      final dest = joinPath(target, item.name);
      if (!copy && normalizePath(dest) == normalizePath(item.path)) continue;
      try {
        await _transferOne(item, dest, copy: copy, override: false);
        done++;
      } on ApiException catch (e) {
        if (e.isConflict && context.mounted) {
          final replace = await confirm(context,
              title: '"${item.name}" exists',
              message: 'Replace the item in the destination?',
              action: 'Replace');
          if (!replace) continue;
          try {
            await _transferOne(item, dest, copy: copy, override: true);
            done++;
          } on ApiException catch (e) {
            showMessage(e.message);
          }
        } else {
          showMessage(e.message);
        }
      }
    }
    _refresh(source);
    _refresh(target);
    if (done > 0) {
      showMessage('${copy ? 'Copied' : 'Moved'} $done '
          '${done == 1 ? 'item' : 'items'} to ${target == '/' ? 'Home' : baseName(target)}');
    }
  }

  Future<void> _transferOne(FileItem item, String dest,
          {required bool copy, required bool override}) =>
      copy
          ? _api.copy(item.path, dest, override: override)
          : _api.move(item.path, dest, override: override);

  Future<bool> delete(BuildContext context, List<FileItem> items) async {
    if (items.isEmpty) return false;
    final ok = await confirm(
      context,
      title: items.length == 1
          ? 'Delete "${items.first.name}"?'
          : 'Delete ${items.length} items?',
      message: 'This cannot be undone.',
      action: 'Delete',
    );
    if (!ok) return false;
    for (final item in items) {
      try {
        await _api.delete(item.path);
      } on ApiException catch (e) {
        showMessage('${item.name}: ${e.message}');
      }
    }
    _refresh(parentOf(items.first.path));
    return true;
  }

  /// Picks files on the device and uploads them into [dir] with tus.
  Future<void> upload(BuildContext context, String dir) async {
    final files = await ref.read(deviceFilesProvider).pickFiles();
    for (final file in files) {
      if (!context.mounted) return;
      await uploadFile(context, file, dir);
    }
  }

  Future<void> uploadFile(BuildContext context, File file, String dir) async {
    final name = file.uri.pathSegments.last;
    final path = joinPath(dir, name);
    final transfers = ref.read(transfersProvider.notifier);
    final id = transfers.start(TransferKind.upload, name);
    Future<void> run(bool override) => _api.upload(file, path,
        override: override,
        onProgress: (sent, total) => transfers.progress(id, sent, total));
    try {
      try {
        await run(false);
      } on ApiException catch (e) {
        if (!e.isConflict || !context.mounted) rethrow;
        final replace = await confirm(context,
            title: '"$name" exists',
            message: 'Replace the file on the server?',
            action: 'Replace');
        if (!replace) {
          transfers.fail(id, 'Skipped');
          return;
        }
        await run(true);
      }
      transfers.finish(id);
    } on ApiException catch (e) {
      transfers.fail(id, e.message);
      showMessage('Upload of $name failed: ${e.message}');
    } finally {
      _refresh(dir);
    }
  }

  /// Saves a file (or a folder as a zip) into the device's download folder.
  Future<File?> download(FileItem item, {bool openWhenDone = false}) async {
    final deviceFiles = ref.read(deviceFilesProvider);
    final dir = await deviceFiles.downloadDirectory();
    final fileName = item.isDir ? '${item.name}.zip' : item.name;
    final target = _freeName(dir, fileName);
    final transfers = ref.read(transfersProvider.notifier);
    final id = transfers.start(TransferKind.download, fileName);
    try {
      await _api.download(item.path, target.path,
          archive: item.isDir ? 'zip' : null,
          onProgress: (received, total) =>
              transfers.progress(id, received, total < 0 ? item.size : total));
      transfers.finish(id);
    } on ApiException catch (e) {
      transfers.fail(id, e.message);
      showMessage('Download of $fileName failed: ${e.message}');
      return null;
    }
    Future<void> openIt() async {
      final error = await deviceFiles.open(target);
      if (error != null) showMessage('Cannot open $fileName: $error');
    }

    if (openWhenDone) {
      await openIt();
    } else {
      showMessage(
          'Saved ${target.uri.pathSegments.last} (${formatSize(target.lengthSync())})',
          action: SnackBarAction(label: 'Open', onPressed: openIt));
    }
    return target;
  }

  /// `name`, or `name (1)`, `name (2)`, … if that file already exists.
  File _freeName(Directory dir, String name) {
    var file = File('${dir.path}/$name');
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; file.existsSync(); i++) {
      file = File('${dir.path}/$stem ($i)$ext');
    }
    return file;
  }

  /// Shows the item's public links and lets the user add or delete one.
  Future<void> share(BuildContext context, FileItem item) => showDialog<void>(
      context: context, builder: (_) => ShareDialog(item: item));

  Future<void> info(BuildContext context, FileItem item) => showDialog<void>(
      context: context, builder: (_) => _InfoDialog(item: item));

  /// The actions menu for one item, limited to what the account may do.
  Future<void> showMenu(BuildContext context, FileItem item) {
    final perm = ref.read(requireSessionProvider).perm;
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
              if (perm.download)
                tile(
                    Icons.download,
                    item.isDir ? 'Download as zip' : 'Download',
                    () => download(item)),
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
                tile(Icons.delete_outline, 'Delete',
                    () => delete(context, [item])),
            ]),
          ),
        );
      },
    );
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
