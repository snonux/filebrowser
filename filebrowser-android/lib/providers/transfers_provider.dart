import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TransferKind { upload, download }

enum TransferStatus { running, done, failed }

/// Progress of one upload or download, shown in the transfer bar.
class Transfer {
  const Transfer({
    required this.id,
    required this.kind,
    required this.name,
    this.sent = 0,
    this.total = 0,
    this.status = TransferStatus.running,
    this.error,
  });

  final int id;
  final TransferKind kind;
  final String name;
  final int sent;
  final int total;
  final TransferStatus status;
  final String? error;

  double? get fraction => total <= 0 ? null : sent / total;

  Transfer copyWith(
          {int? sent, int? total, TransferStatus? status, String? error}) =>
      Transfer(
        id: id,
        kind: kind,
        name: name,
        sent: sent ?? this.sent,
        total: total ?? this.total,
        status: status ?? this.status,
        error: error ?? this.error,
      );
}

class TransfersNotifier extends Notifier<List<Transfer>> {
  int _nextId = 0;

  @override
  List<Transfer> build() => const [];

  int start(TransferKind kind, String name) {
    final id = _nextId++;
    state = [...state, Transfer(id: id, kind: kind, name: name)];
    return id;
  }

  void progress(int id, int sent, int total) =>
      _update(id, (t) => t.copyWith(sent: sent, total: total));

  void finish(int id) => _update(
      id, (t) => t.copyWith(status: TransferStatus.done, sent: t.total));

  void fail(int id, String error) => _update(
      id, (t) => t.copyWith(status: TransferStatus.failed, error: error));

  /// Removes finished and failed transfers.
  void clearFinished() =>
      state = state.where((t) => t.status == TransferStatus.running).toList();

  void _update(int id, Transfer Function(Transfer) change) => state = [
        for (final t in state) t.id == id ? change(t) : t,
      ];
}

final transfersProvider =
    NotifierProvider<TransfersNotifier, List<Transfer>>(TransfersNotifier.new);
