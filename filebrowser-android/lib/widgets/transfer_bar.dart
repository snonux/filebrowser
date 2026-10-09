import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/transfers_provider.dart';
import '../utils/format.dart';

/// Progress of uploads and downloads, shown under the file list.
class TransferBar extends ConsumerWidget {
  const TransferBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider);
    if (transfers.isEmpty) return const SizedBox.shrink();
    final running =
        transfers.where((t) => t.status == TransferStatus.running).toList();
    final failed =
        transfers.where((t) => t.status == TransferStatus.failed).length;
    final current = running.isNotEmpty ? running.first : transfers.last;
    final verb =
        current.kind == TransferKind.upload ? 'Uploading' : 'Downloading';
    final String label;
    if (running.isNotEmpty) {
      final more = running.length > 1 ? ' (+${running.length - 1} more)' : '';
      final amount = current.total > 0
          ? ' · ${formatSize(current.sent)} of ${formatSize(current.total)}'
          : '';
      label = '$verb ${current.name}$amount$more';
    } else {
      final done = transfers.length - failed;
      label = failed == 0
          ? '$done ${done == 1 ? 'transfer' : 'transfers'} finished'
          : '$done finished, $failed failed: ${transfers.lastWhere((t) => t.status == TransferStatus.failed).error}';
    }
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (running.isNotEmpty)
            LinearProgressIndicator(value: current.fraction),
          ListTile(
            dense: true,
            leading: Icon(running.isNotEmpty
                ? (current.kind == TransferKind.upload
                    ? Icons.upload
                    : Icons.download)
                : (failed == 0
                    ? Icons.check_circle_outline
                    : Icons.error_outline)),
            title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: running.isEmpty
                ? IconButton(
                    tooltip: 'Dismiss',
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        ref.read(transfersProvider.notifier).clearFinished(),
                  )
                : null,
          ),
        ]),
      ),
    );
  }
}
