import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/paths.dart';
import '../app_routes.dart';
import '../models/models.dart';
import '../providers/offline_provider.dart';
import '../utils/format.dart';
import '../widgets/file_icon.dart';
import 'file_actions.dart';

/// The files and folders marked "available offline", with how much they take
/// on the device. Works without the server.
class OfflineScreen extends ConsumerWidget {
  const OfflineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(offlineProvider);
    final store = status.store;
    final pins = store?.pins ?? const <String>[];
    final usage = store?.usage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Available offline'),
        actions: [
          IconButton(
            tooltip: 'Update offline copies',
            icon: const Icon(Icons.sync),
            onPressed: status.syncing || pins.isEmpty
                ? null
                : () => ref.read(offlineProvider.notifier).sync(),
          ),
        ],
      ),
      body: Column(children: [
        if (status.syncing) const LinearProgressIndicator(),
        if (usage != null && pins.isNotEmpty)
          ListTile(
            dense: true,
            title: Text(
                '${usage.files} ${usage.files == 1 ? 'file' : 'files'} · ${formatSize(usage.bytes)} on this device'),
            subtitle: status.error == null
                ? null
                : Text('Not up to date: ${status.error}'),
          ),
        Expanded(
          child: store == null
              ? const Center(child: CircularProgressIndicator())
              : pins.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Nothing is available offline yet. Choose "Make available offline" in the menu of a file or folder to keep it on this device.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView(children: [
                      for (final path in pins)
                        _PinTile(
                          path: path,
                          item: store.item(path),
                          ready: store.isAvailable(path),
                        ),
                    ]),
        ),
      ]),
    );
  }
}

class _PinTile extends StatelessWidget {
  const _PinTile({required this.path, required this.item, required this.ready});

  final String path;

  /// Null until the pin was first fetched from the server.
  final FileItem? item;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    final actions = FileActions(context);
    return ListTile(
      leading: SizedBox.square(
        dimension: 40,
        child: Icon(item == null ? Icons.downloading : FileIcon.iconFor(item),
            size: 32,
            color: item?.isDir ?? false
                ? Theme.of(context).colorScheme.primary
                : null),
      ),
      title: Text(path == '/' ? 'Home' : baseName(path),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          ready ? parentOf(path) : 'Waiting to download · ${parentOf(path)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'Remove offline copy of ${baseName(path)}',
        icon: const Icon(Icons.offline_pin),
        onPressed: () => actions.removeOffline(path),
      ),
      onTap: item == null
          ? null
          : () => item.isDir
              ? context.push(AppRoutes.files(path))
              : actions.open(context, item),
    );
  }
}
