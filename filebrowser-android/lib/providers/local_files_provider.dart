import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/local_files.dart';
import 'device_files_provider.dart';
import 'files_provider.dart';
import 'preferences_provider.dart';

final localFilesProvider = Provider<LocalFiles>((ref) => const LocalFiles());

/// Whether the app may manage the phone's files. Invalidate it after asking.
final storageAccessProvider = FutureProvider<bool>(
    (ref) => ref.watch(deviceFilesProvider).hasStorageAccess());

final storageRootsProvider = FutureProvider<List<StorageRoot>>(
    (ref) => ref.watch(deviceFilesProvider).storageRoots());

/// The raw entries of one phone folder.
final localListingProvider = FutureProvider.autoDispose
    .family<List<FileItem>, String>(
        (ref, path) => ref.watch(localFilesProvider).list(path));

/// A phone folder's entries, sorted and filtered like the server's.
final localFolderItemsProvider = Provider.autoDispose
    .family<AsyncValue<List<FileItem>>, String>((ref, path) {
  final prefs = ref.watch(preferencesProvider);
  final showHidden = ref.watch(showHiddenProvider);
  return ref.watch(localListingProvider(path)).whenData((items) =>
      sortItems(items, prefs.sortField, prefs.sortAscending, showHidden));
});

/// The volume [path] is on, or null when it is on none of [roots].
StorageRoot? rootOf(List<StorageRoot> roots, String path) {
  StorageRoot? best;
  for (final root in roots) {
    final r = root.path;
    if ((path == r || path.startsWith('$r/')) &&
        (best == null || r.length > best.path.length)) {
      best = root;
    }
  }
  return best;
}
