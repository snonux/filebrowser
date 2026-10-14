import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../models/models.dart';
import '../providers/files_provider.dart';
import '../providers/offline_provider.dart';
import '../providers/session_provider.dart';
import 'file_actions.dart';

/// Shows a text file and, with the modify permission, edits and saves it.
class TextEditorScreen extends ConsumerStatefulWidget {
  const TextEditorScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends ConsumerState<TextEditorScreen> {
  final _text = TextEditingController();
  String _saved = '';
  bool _loading = true;
  bool _saving = false;
  bool _editable = false;
  bool _offline = false;
  String? _error;

  /// "Edit in TurboNotes" when the file can be edited in another app.
  String? _editLabel;
  FileItem? _item;

  bool get _dirty => _text.text != _saved;

  @override
  void initState() {
    super.initState();
    _load();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(requireSessionProvider);
    try {
      final item = (await session.api.fetch(widget.path)).item;
      _saved = item.content ?? '';
      _text.text = _saved;
      _editable = session.perm.modify && item.type == 'text';
      if (mounted) {
        final actions = FileActions(context);
        if (actions.canEditExternally(item)) {
          _item = item;
          _editLabel = await actions.editLabel();
        }
      }
    } on ApiException catch (e) {
      // Without the server, show the offline copy if there is one. It
      // cannot be saved, so it is read-only.
      final copy = e.statusCode == null
          ? (await ref.read(offlineProvider.notifier).ready)
              ?.localFile(widget.path)
          : null;
      _error = e.message;
      if (copy != null) {
        try {
          _saved = await copy.readAsString();
          _text.text = _saved;
          _offline = true;
          _error = null;
        } on FileSystemException {
          // Removed meanwhile, or not text: report the server error.
        }
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      final content = _text.text;
      await ref.read(requireSessionProvider).api.saveText(widget.path, content);
      _saved = content;
      ref.invalidate(resourceProvider(parentOf(widget.path)));
      showMessage('Saved');
      return true;
    } on ApiException catch (e) {
      showMessage('Not saved: ${e.message}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save changes?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('Discard')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Save')),
        ],
      ),
    );
    if (choice == 'save' && !await _save()) return;
    if (choice != null && mounted) {
      _saved = _text.text;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(baseName(widget.path)),
          actions: [
            if (_editLabel != null && !_offline)
              IconButton(
                tooltip: _editLabel,
                icon: const Icon(Icons.edit_note),
                // Unsaved edits here would be lost in the other app's copy.
                onPressed: _dirty
                    ? null
                    : () {
                        FileActions(context).editExternally(_item!);
                        Navigator.of(context).pop();
                      },
              ),
            if (_editable)
              IconButton(
                tooltip: 'Save',
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                onPressed: _dirty && !_saving ? _save : null,
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : Column(children: [
                    if (_offline)
                      const MaterialBanner(
                        leading: Icon(Icons.cloud_off),
                        content: Text(
                            'The server cannot be reached. This is the offline copy; it cannot be edited.'),
                        actions: [SizedBox.shrink()],
                      ),
                    Expanded(
                        child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _text,
                        readOnly: !_editable,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontFamily: 'monospace'),
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: _editable ? 'Empty file' : null,
                        ),
                      ),
                    )),
                  ]),
      ),
    );
  }
}
