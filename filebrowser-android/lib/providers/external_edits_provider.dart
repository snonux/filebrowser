import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/paths.dart';
import '../navigation_key.dart';
import '../services/external_edits.dart';
import 'device_files_provider.dart';
import 'files_provider.dart';
import 'session_provider.dart';

/// Files being edited in another app ("Edit in TurboNotes"); see
/// [ExternalEdits].
final externalEditsProvider = Provider<ExternalEdits>((ref) {
  final edits = ExternalEdits(
    deviceFiles: ref.read(deviceFilesProvider),
    onMessage: (message) => appMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message))),
    onUploaded: (dir) => ref.invalidate(resourceProvider(normalizePath(dir))),
  );
  // Back from the editor: upload its last save right away.
  final lifecycle = AppLifecycleListener(onResume: edits.check);
  ref.listen(sessionProvider,
      (_, next) => edits.sessionChanged(next.valueOrNull?.api));
  ref.onDispose(() {
    lifecycle.dispose();
    edits.dispose();
  });
  return edits;
});
