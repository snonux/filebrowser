import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../screens/file_actions.dart';
import '../utils/format.dart';

/// When a share link stops working, e.g. `Expires 2026-10-09 18:42`.
String shareExpiryText(ShareLink link) {
  final at = link.expiresAt;
  if (at == null) return 'Never expires';
  return '${at.isAfter(DateTime.now()) ? 'Expires' : 'Expired'} '
      '${formatDate(at)}';
}

/// Puts [text] on the clipboard; returns false when the platform refuses,
/// so the caller does not claim a copy that did not happen.
Future<bool> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } on PlatformException {
    return false;
  }
}

/// One share link with its copy and delete buttons, as used by the share
/// dialog of a file and by the list of all links.
class ShareLinkTile extends StatefulWidget {
  const ShareLinkTile({
    super.key,
    required this.api,
    required this.link,
    required this.title,
    required this.label,
    required this.onDelete,
    this.owner,
    this.downloadLink = false,
    this.actionsBelow = false,
  });

  final FileBrowserApi api;
  final ShareLink link;
  final String title;

  /// Names the link in the button tooltips, so each button is distinct for
  /// screen readers when several links are listed.
  final String label;

  /// Asks for confirmation and deletes the link. The delete button is off
  /// until it completes.
  final Future<void> Function() onDelete;

  /// The user name of the link's owner, when it is worth showing.
  final String? owner;

  /// Whether to offer the direct download link as well.
  final bool downloadLink;

  /// Puts the buttons under the text instead of beside it; a dialog is too
  /// narrow to fit a whole address next to three buttons.
  final bool actionsBelow;

  @override
  State<ShareLinkTile> createState() => _ShareLinkTileState();
}

class _ShareLinkTileState extends State<ShareLinkTile> {
  /// Whether a delete is under way. A second request for the same link would
  /// only be answered with "not found".
  bool _deleting = false;

  Future<void> _copy(String text, String message) async =>
      showMessage(await copyText(text) ? message : 'Could not copy the link');

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      await widget.onDelete();
    } finally {
      // The tile is gone once its link is deleted.
      if (mounted) setState(() => _deleting = false);
    }
  }

  List<Widget> _actions() {
    final api = widget.api;
    final link = widget.link;
    final label = widget.label;
    return [
      IconButton(
        tooltip: 'Copy link for $label',
        icon: const Icon(Icons.copy),
        onPressed: () => _copy(api.shareUrl(link), 'Link copied'),
      ),
      if (widget.downloadLink)
        IconButton(
          // A direct download cannot ask for the password, so the web UI
          // disables this for protected links; so does the app.
          tooltip: link.hasPassword
              ? 'No download link for $label: it has a password'
              : 'Copy download link for $label',
          icon: const Icon(Icons.download_for_offline_outlined),
          onPressed: link.hasPassword
              ? null
              : () => _copy(api.shareDownloadUrl(link), 'Download link copied'),
        ),
      IconButton(
        tooltip: 'Delete link for $label',
        icon: const Icon(Icons.delete_outline),
        onPressed: _deleting ? null : _delete,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final below = widget.actionsBelow;
    final expiry = shareExpiryText(widget.link);
    final owner = widget.owner;
    final tile = ListTile(
      contentPadding: below ? EdgeInsets.zero : null,
      leading: Icon(widget.link.hasPassword ? Icons.lock : Icons.link),
      title: Text(widget.title),
      subtitle: Text(owner == null ? expiry : '$expiry · $owner'),
      trailing: below
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: _actions()),
    );
    if (!below) return tile;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      tile,
      Row(mainAxisAlignment: MainAxisAlignment.end, children: _actions()),
    ]);
  }
}
