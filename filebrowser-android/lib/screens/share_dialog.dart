import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import 'file_actions.dart';

/// Creates a public link for a file or folder.
class ShareDialog extends ConsumerStatefulWidget {
  const ShareDialog({super.key, required this.item});

  final FileItem item;

  @override
  ConsumerState<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends ConsumerState<ShareDialog> {
  final _expires = TextEditingController();
  final _password = TextEditingController();
  String _unit = 'hours';
  bool _busy = false;
  String? _link;
  String? _error;

  @override
  void dispose() {
    _expires.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final expires = int.tryParse(_expires.text.trim()) ?? 0;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(requireSessionProvider).api;
      final share = await api.createShare(widget.item.path,
          expires: expires, unit: _unit, password: _password.text);
      final link = api.shareUrl(share);
      await Clipboard.setData(ClipboardData(text: link));
      setState(() => _link = link);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_link != null) {
      return AlertDialog(
        title: const Text('Link created'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(_link!),
          const SizedBox(height: 8),
          const Text('The link was copied to the clipboard.'),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _link!));
              showMessage('Link copied');
            },
            child: const Text('Copy again'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      );
    }
    return AlertDialog(
      title: Text('Share "${widget.item.name}"'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _expires,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Expires after', hintText: 'Never'),
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _unit,
              onChanged: (v) => setState(() => _unit = v!),
              items: const [
                DropdownMenuItem(value: 'minutes', child: Text('minutes')),
                DropdownMenuItem(value: 'hours', child: Text('hours')),
                DropdownMenuItem(value: 'days', child: Text('days')),
              ],
            ),
          ]),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password (optional)'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _busy ? null : _create,
            child: const Text('Create link')),
      ],
    );
  }
}
