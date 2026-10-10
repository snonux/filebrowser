import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../widgets/share_link_tile.dart';
import 'file_actions.dart';

final sharesProvider = FutureProvider.autoDispose<List<ShareLink>>(
    (ref) => ref.watch(requireSessionProvider.select((s) => s.api)).shares());

/// User names by account id, for labelling whose link each one is.
///
/// Only an administrator is shown other accounts' links, and only an
/// administrator may list users, so everyone else gets an empty map. A failed
/// lookup also leaves the map empty: the links are still listed, unlabelled.
final shareOwnersProvider =
    FutureProvider.autoDispose<Map<int, String>>((ref) async {
  final session = ref.watch(requireSessionProvider);
  if (!session.perm.admin) return const {};
  try {
    return await session.api.usernames();
  } on ApiException {
    return const {};
  }
});

/// How [deleteShareLink] ended.
enum ShareDeletion {
  /// The user did not confirm; nothing was sent.
  cancelled,

  /// The link is gone from the server.
  deleted,

  /// The server refused or could not be reached. The usual cause is that the
  /// link is already gone (it expired or was deleted elsewhere), so the
  /// caller should fetch its list again.
  failed,
}

/// Asks before deleting [link] and reports a failure to the user.
Future<ShareDeletion> deleteShareLink(
    BuildContext context, FileBrowserApi api, ShareLink link) async {
  if (!await confirm(context,
      title: 'Delete this link?',
      message: 'People with the link lose access.',
      action: 'Delete')) {
    return ShareDeletion.cancelled;
  }
  try {
    await api.deleteShare(link.hash);
    return ShareDeletion.deleted;
  } on ApiException catch (e) {
    showMessage(e.message);
    return ShareDeletion.failed;
  }
}

/// The account's share links, with copy and delete.
class SharesScreen extends ConsumerWidget {
  const SharesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shares = ref.watch(sharesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Share links')),
      body: RefreshIndicator(
        onRefresh: () => _reload(ref),
        child: shares.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _message(ApiException.from(e).message),
          data: (links) => links.isEmpty
              ? _message('No share links')
              : _list(context, ref, links),
        ),
      ),
    );
  }

  /// Fetches the links and the owner names again, which can be as stale.
  /// It completes once the list is up to date. A failure is not passed on:
  /// the list shows it in place of the links.
  Future<void> _reload(WidgetRef ref) async {
    ref.invalidate(shareOwnersProvider);
    ref.invalidate(sharesProvider);
    try {
      await ref.read(sharesProvider.future);
    } catch (_) {
      // Shown by [build] through the provider's error state.
    }
  }

  /// A scrollable placeholder, so pull-to-refresh still works.
  Widget _message(String text) => ListView(children: [
        const SizedBox(height: 120),
        Center(child: Text(text)),
      ]);

  Widget _list(BuildContext context, WidgetRef ref, List<ShareLink> links) {
    final api = ref.watch(requireSessionProvider).api;
    final owners = ref.watch(shareOwnersProvider).valueOrNull ?? const {};
    return ListView(children: [
      for (final link in links)
        ShareLinkTile(
          // By link, not by position: the tile keeps state while it deletes.
          key: ValueKey(link.hash),
          api: api,
          link: link,
          title: link.path,
          label: link.path,
          owner: owners[link.userId],
          onDelete: () async {
            final result = await deleteShareLink(context, api, link);
            // The screen may have been left while the server answered.
            if (result == ShareDeletion.cancelled || !context.mounted) return;
            // Also after a failed delete, see [ShareDeletion.failed]. Waiting
            // for the new list keeps the delete button off until the row is
            // gone.
            await _reload(ref);
          },
        ),
    ]);
  }
}
