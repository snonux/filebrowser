import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../widgets/share_link_tile.dart';
import 'file_actions.dart';
import 'shares_screen.dart';

/// The public links of a file or folder, like the web UI's share prompt.
///
/// It opens on the links that already exist for the item, each with copy,
/// copy download link and delete, and switches to a form for a new link. With
/// no links yet it starts on the form.
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

  /// The item's links; null until the first answer from the server.
  List<ShareLink>? _links;

  /// Whether the form for a new link is shown instead of the list.
  bool _adding = false;
  bool _busy = false;

  /// Whether the links could not be fetched so far, so [_links] is only
  /// what this dialog created itself. A later fetch that works clears it.
  bool _loadFailed = false;

  /// Counts the links created and deleted in this dialog. A list that was
  /// asked for before such a change and answers after it is not shown: it
  /// would bring back a link deleted meanwhile, or lose one just created.
  /// The list is asked for again instead.
  int _listVersion = 0;
  String? _error;
  String? _expiresError;

  FileBrowserApi get _api => ref.read(requireSessionProvider).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _expires.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Fetches the item's links. A failure of the first request opens the form
  /// and says so; a failed later one keeps the list that is shown.
  Future<void> _load() async {
    final item = widget.item;
    final version = _listVersion;
    try {
      final links =
          sortShareLinks(await _api.sharesFor(item.path, isDir: item.isDir));
      if (!mounted) return;
      // Outdated by a change made while it was under way, see [_listVersion].
      if (version != _listVersion) {
        await _load();
        return;
      }
      setState(() {
        _links = links;
        // A reload must not close a form the user opened meanwhile.
        _adding = _adding || links.isEmpty;
        _loadFailed = false;
      });
    } on ApiException catch (e) {
      if (!mounted || _links != null) return;
      // The list is unknown, but a new link can still be tried.
      setState(() {
        _links = [];
        _adding = true;
        _loadFailed = true;
        _error = 'Could not load the existing links: ${e.message}';
      });
    }
  }

  Future<void> _create() async {
    final expires = parseShareExpiry(_expires.text, _unit);
    setState(() {
      _error = null;
      _expiresError = expires == null
          ? 'Enter a whole number from 0 to ${maxShareExpiryFor(_unit)}'
          : null;
    });
    if (expires == null) return;
    setState(() => _busy = true);
    // Read before the first await: the dialog may be closed meanwhile.
    final api = _api;
    final item = widget.item;
    try {
      // Trimmed like the web UI's field, so a stray space does not become a
      // password nobody knows about.
      final share = await api.createShare(item.path,
          isDir: item.isDir,
          expires: expires,
          unit: _unit,
          password: _password.text.trim());
      // Show the link before copying it: the link exists even if the copy
      // fails, and a form left open would invite a duplicate.
      if (mounted) _showCreated(share);
      showMessage(await copyText(api.shareUrl(share))
          ? 'Link created and copied'
          : 'Link created, but it could not be copied');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns to the list with [share] in it and the form reset.
  void _showCreated(ShareLink share) {
    _expires.clear();
    _password.clear();
    setState(() {
      _listVersion++;
      _links = sortShareLinks([...?_links, share]);
      _unit = 'hours';
      _adding = false;
    });
    // The item may have more links than the one just made.
    if (_loadFailed) _load();
  }

  Future<void> _delete(ShareLink link) async {
    final result = await deleteShareLink(context, _api, link);
    if (!mounted) return;
    switch (result) {
      case ShareDeletion.cancelled:
        break;
      case ShareDeletion.deleted:
        setState(() {
          _listVersion++;
          _links = _links!.where((l) => l.hash != link.hash).toList();
          _adding = _links!.isEmpty;
        });
      case ShareDeletion.failed:
        await _load();
    }
  }

  /// Leaves the form: back to the list, or out of the dialog when there is
  /// nothing to list.
  void _cancelForm() {
    if (_links!.isEmpty) {
      Navigator.pop(context);
    } else {
      setState(() {
        _adding = false;
        _error = null;
        _expiresError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Text('Share "${widget.item.name}"');
    if (_links == null) {
      return AlertDialog(
        title: title,
        content: const SizedBox(
            height: 64, child: Center(child: CircularProgressIndicator())),
      );
    }
    return _adding ? _buildForm(title) : _buildList(title);
  }

  Widget _buildList(Widget title) {
    return AlertDialog(
      title: title,
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_loadFailed)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('The existing links could not be loaded, so '
                    'there may be more than are listed here.'),
              ),
            for (final link in _links!)
              ShareLinkTile(
                // By link, not by position: the tile keeps state while it
                // deletes, and the list changes under it.
                key: ValueKey(link.hash),
                api: _api,
                link: link,
                title: _api.shareUrl(link),
                label: link.hash,
                downloadLink: true,
                actionsBelow: true,
                onDelete: () => _delete(link),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
        FilledButton(
            onPressed: () => setState(() => _adding = true),
            child: const Text('New link')),
      ],
    );
  }

  Widget _buildForm(Widget title) {
    return AlertDialog(
      title: title,
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _buildDuration(),
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
        TextButton(onPressed: _cancelForm, child: const Text('Cancel')),
        FilledButton(
            onPressed: _busy ? null : _create,
            child: const Text('Create link')),
      ],
    );
  }

  /// Drops the complaint about the lifetime once the number or the unit is
  /// changed: the limit it names depends on the unit.
  void _clearExpiresError() {
    if (_expiresError != null) setState(() => _expiresError = null);
  }

  /// The lifetime of the new link: a number and its unit.
  Widget _buildDuration() {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: TextField(
          controller: _expires,
          keyboardType: TextInputType.number,
          onChanged: (_) => _clearExpiresError(),
          decoration: InputDecoration(
            labelText: 'Expires after',
            hintText: 'Never',
            errorText: _expiresError,
            errorMaxLines: 2,
          ),
        ),
      ),
      const SizedBox(width: 12),
      DropdownButton<String>(
        value: _unit,
        onChanged: (v) {
          setState(() => _unit = v!);
          _clearExpiresError();
        },
        items: [
          for (final unit in shareUnits)
            DropdownMenuItem(value: unit, child: Text(unit)),
        ],
      ),
    ]);
  }
}
