import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../utils/format.dart';
import 'file_actions.dart';

final sharesProvider = FutureProvider.autoDispose<List<ShareLink>>(
    (ref) => ref.watch(requireSessionProvider.select((s) => s.api)).shares());

/// The account's share links, with copy and delete.
class SharesScreen extends ConsumerWidget {
  const SharesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(requireSessionProvider).api;
    final shares = ref.watch(sharesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Share links')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(sharesProvider.future),
        child: shares.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [
            const SizedBox(height: 120),
            Center(child: Text(ApiException.from(e).message)),
          ]),
          data: (links) => links.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: Text('No share links')),
                ])
              : ListView(children: [
                  for (final link in links)
                    ListTile(
                      leading: Icon(link.hasPassword ? Icons.lock : Icons.link),
                      title: Text(link.path),
                      subtitle: Text(link.expiresAt == null
                          ? 'Never expires'
                          : 'Expires ${formatDate(link.expiresAt!)}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Copy link for ${link.path}',
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: api.shareUrl(link)));
                            showMessage('Link copied');
                          },
                        ),
                        IconButton(
                          tooltip: 'Delete link for ${link.path}',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (!await confirm(context,
                                title: 'Delete this link?',
                                message: 'People with the link lose access.',
                                action: 'Delete')) {
                              return;
                            }
                            try {
                              await api.deleteShare(link.hash);
                            } on ApiException catch (e) {
                              showMessage(e.message);
                            }
                            ref.invalidate(sharesProvider);
                          },
                        ),
                      ]),
                    ),
                ]),
        ),
      ),
    );
  }
}
