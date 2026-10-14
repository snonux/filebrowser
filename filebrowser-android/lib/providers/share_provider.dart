import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/share_receiver.dart';

/// Overridden in tests with a fake that shares on demand.
final shareReceiverProvider =
    Provider<ShareReceiver>((ref) => PlatformShareReceiver());

/// The share waiting to be uploaded, or null. While one waits, the router
/// shows the upload screen.
class PendingShareNotifier extends Notifier<SharedContent?> {
  @override
  SharedContent? build() {
    final subscription = ref.read(shareReceiverProvider).shares.listen((share) {
      state?.discard();
      state = share;
    });
    ref.onDispose(subscription.cancel);
    return null;
  }

  /// Ends the share; its copies are removed unless [keepFiles] is set, for
  /// uploads that are still reading them.
  void done({bool keepFiles = false}) {
    if (!keepFiles) state?.discard();
    state = null;
  }
}

final pendingShareProvider =
    NotifierProvider<PendingShareNotifier, SharedContent?>(
        PendingShareNotifier.new);
