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

/// Asks before deleting [link]; returns whether it is gone from the server.
Future<bool> deleteShareLink(
    BuildContext context, FileBrowserApi api, ShareLink link) async {
  if (!await confirm(context,
      title: 'Delete this link?',
      message: 'People with the link lose access.',
      action: 'Delete')) {
    return false;
  }
  try {
    await api.deleteShare(link.hash);
    return true;
  } on ApiException catch (e) {
    showMessage(e.message);
    return false;
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
        onRefresh: () => ref.refresh(sharesProvider.future),
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
          api: api,
          link: link,
          title: link.path,
          label: link.path,
          owner: owners[link.userId],
          onDelete: () async {
            // Refresh even after a failed delete: the usual cause is that the
            // link is already gone.
            await deleteShareLink(context, api, link);
            ref.invalidate(sharesProvider);
          },
        ),
    ]);
  }
}
