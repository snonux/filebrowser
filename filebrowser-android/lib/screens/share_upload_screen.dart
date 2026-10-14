import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/paths.dart';
import '../app_routes.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
import '../providers/share_provider.dart';
import '../services/share_receiver.dart';
import '../utils/format.dart';
import '../utils/shared_text.dart';
import '../widgets/transfer_bar.dart';
import 'file_actions.dart';
import 'folder_picker_screen.dart';

/// Uploads what another app shared: files as they are, text as a Markdown
/// or plain text file.
class ShareUploadScreen extends ConsumerWidget {
  const ShareUploadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final share = ref.watch(pendingShareProvider);
    if (share == null) return const Scaffold();
    // A new share replaces the form, not just its contents.
    return _ShareForm(key: ObjectKey(share), share: share);
  }
}

enum _TextKind { markdown, plain }

class _ShareForm extends ConsumerStatefulWidget {
  const _ShareForm({super.key, required this.share});

  final SharedContent share;

  @override
  ConsumerState<_ShareForm> createState() => _ShareFormState();
}

class _ShareFormState extends ConsumerState<_ShareForm> {
  late String _folder = ref.read(preferencesProvider).shareFolder;
  final _name = TextEditingController();
  late _TextKind _kind;
  bool _busy = false;

  SharedContent get _share => widget.share;

  @override
  void initState() {
    super.initState();
    final text = _share.text ?? '';
    _kind = looksLikeMarkdown(text) ? _TextKind.markdown : _TextKind.plain;
    if (_share.isText) {
      _name.text = textBaseName(text, subject: _share.subject) + _extension;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _extension => _kind == _TextKind.markdown ? '.md' : '.txt';

  /// Swaps a `.md` or `.txt` ending of the name for the chosen kind's.
  void _setKind(_TextKind kind) {
    final name = _name.text.trim();
    final stem =
        name.replaceFirst(RegExp(r'\.(md|txt)$', caseSensitive: false), '');
    setState(() {
      _kind = kind;
      _name.text = stem + _extension;
    });
  }

  Future<void> _pickFolder() async {
    final folder = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => FolderPickerScreen(start: _folder, action: 'Upload here'),
    ));
    if (folder != null && mounted) setState(() => _folder = folder);
  }

  void _cancel() {
    ref.read(pendingShareProvider.notifier).done();
    context.go(AppRoutes.files('/'));
  }

  Future<void> _upload() async {
    final List<File> files;
    Directory? scratch;
    if (_share.isText) {
      final name = _name.text.trim();
      if (!isValidName(name)) {
        showMessage('Enter a file name without "/"');
        return;
      }
      final dir = _share.dir ??
          (scratch = await Directory.systemTemp.createTemp('fb-share'));
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsString(_share.text!);
      files = [file];
    } else {
      files = _share.files;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final actions = FileActions(context);
    var uploaded = 0;
    try {
      for (final file in files) {
        if (!mounted) return;
        if (await actions.uploadFile(context, file, _folder)) uploaded++;
      }
    } finally {
      await scratch?.delete(recursive: true);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // Keep the form after a failure so the user can try again.
    if (uploaded < files.length) return;
    await ref.read(preferencesProvider.notifier).setShareFolder(_folder);
    ref.read(pendingShareProvider.notifier).done();
    showMessage(files.length == 1
        ? 'Uploaded ${baseName(files.first.path)}'
        : 'Uploaded ${files.length} files');
    if (mounted) context.go(AppRoutes.files(_folder));
  }

  @override
  Widget build(BuildContext context) {
    final canUpload =
        ref.watch(sessionProvider).valueOrNull?.perm.create ?? false;
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Upload to File Browser'),
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : _cancel,
          ),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (_share.error != null)
            Text('Cannot read the shared files: ${_share.error}',
                style: TextStyle(color: theme.colorScheme.error)),
          if (!canUpload)
            Text('This account may not upload files.',
                style: TextStyle(color: theme.colorScheme.error)),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Upload to folder'),
            subtitle: Text(_folder == '/' ? 'Home' : _folder),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _pickFolder,
          ),
          const Divider(),
          if (_share.isText) ..._textForm(theme) else ..._fileList(),
        ]),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          const TransferBar(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                icon: const Icon(Icons.upload),
                label: const Text('Upload'),
                onPressed: _busy ||
                        !canUpload ||
                        (_share.files.isEmpty && !_share.isText)
                    ? null
                    : _upload,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _textForm(ThemeData theme) => [
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          enabled: !_busy,
          decoration: const InputDecoration(
              labelText: 'File name', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        SegmentedButton<_TextKind>(
          segments: const [
            ButtonSegment(
                value: _TextKind.markdown,
                label: Text('Markdown'),
                icon: Icon(Icons.code)),
            ButtonSegment(
                value: _TextKind.plain,
                label: Text('Plain text'),
                icon: Icon(Icons.notes)),
          ],
          selected: {_kind},
          onSelectionChanged: _busy ? null : (s) => _setKind(s.single),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(_share.text!,
              maxLines: 20,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace')),
        ),
      ];

  List<Widget> _fileList() => [
        for (final file in _share.files)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(baseName(file.path)),
            subtitle: Text(formatSize(_sizeOf(file))),
          ),
      ];

  static int _sizeOf(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }
}
