import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../providers/files_provider.dart';
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
  String? _error;

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
    } on ApiException catch (e) {
      _error = e.message;
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
                : Padding(
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
                  ),
      ),
    );
  }
}
