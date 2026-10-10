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

/// One share link with its copy and delete buttons, as used by the share
/// dialog of a file and by the list of all links.
class ShareLinkTile extends StatelessWidget {
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
  final VoidCallback onDelete;

  /// The user name of the link's owner, when it is worth showing.
  final String? owner;

  /// Whether to offer the direct download link as well.
  final bool downloadLink;

  /// Puts the buttons under the text instead of beside it; a dialog is too
  /// narrow to fit a whole address next to three buttons.
  final bool actionsBelow;

  void _copy(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    showMessage(message);
  }

  List<Widget> _actions() => [
        IconButton(
          tooltip: 'Copy link for $label',
          icon: const Icon(Icons.copy),
          onPressed: () => _copy(api.shareUrl(link), 'Link copied'),
        ),
        if (downloadLink)
          IconButton(
            // A direct download cannot ask for the password, so the web UI
            // disables this for protected links; so does the app.
            tooltip: link.hasPassword
                ? 'No download link for $label: it has a password'
                : 'Copy download link for $label',
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: link.hasPassword
                ? null
                : () =>
                    _copy(api.shareDownloadUrl(link), 'Download link copied'),
          ),
        IconButton(
          tooltip: 'Delete link for $label',
          icon: const Icon(Icons.delete_outline),
          onPressed: onDelete,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final expiry = shareExpiryText(link);
    final tile = ListTile(
      contentPadding: actionsBelow ? EdgeInsets.zero : null,
      leading: Icon(link.hasPassword ? Icons.lock : Icons.link),
      title: Text(title),
      subtitle: Text(owner == null ? expiry : '$expiry · $owner'),
      trailing: actionsBelow
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: _actions()),
    );
    if (!actionsBelow) return tile;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      tile,
      Row(mainAxisAlignment: MainAxisAlignment.end, children: _actions()),
    ]);
  }
}
