import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/file_operations.dart';
import 'device_files_provider.dart';
import 'session_provider.dart';
import 'transfers_provider.dart';

final fileOperationsProvider = Provider<FileOperations>((ref) {
  final operations = FileOperations(
      deviceFiles: ref.read(deviceFilesProvider),
      transfers: ref.read(transfersProvider.notifier));
  ref.listen(sessionProvider,
      (_, next) => operations.sessionChanged(next.valueOrNull));
  ref.onDispose(operations.dispose);
  return operations;
});
