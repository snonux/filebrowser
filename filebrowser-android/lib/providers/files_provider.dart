import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'preferences_provider.dart';
import 'session_provider.dart';

/// The raw listing of one folder (or one file) from the server.
final resourceProvider =
    FutureProvider.autoDispose.family<Resource, String>((ref, path) {
  final api = ref.watch(requireSessionProvider.select((s) => s.api));
  return api.fetch(path);
});

/// Whether dotfiles are shown: the user's own toggle, else the account's
/// "hide dotfiles" setting.
final showHiddenProvider = Provider<bool>((ref) {
  final own = ref.watch(preferencesProvider.select((p) => p.showHidden));
  if (own != null) return own;
  final session = ref.watch(sessionProvider).valueOrNull;
  return !(session?.user.hideDotfiles ?? false);
});

/// Sorts entries: folders first, then by the chosen field.
List<FileItem> sortItems(
    List<FileItem> items, SortField field, bool ascending, bool showHidden) {
  final visible =
      showHidden ? [...items] : items.where((i) => !i.isHidden).toList();
  int compare(FileItem a, FileItem b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final c = switch (field) {
      SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortField.size => a.size.compareTo(b.size),
      SortField.modified => a.modified.compareTo(b.modified),
    };
    return ascending ? c : -c;
  }

  visible.sort(compare);
  return visible;
}

/// The folder's entries, sorted and filtered for display.
final folderItemsProvider = Provider.autoDispose
    .family<AsyncValue<List<FileItem>>, String>((ref, path) {
  final prefs = ref.watch(preferencesProvider);
  final showHidden = ref.watch(showHiddenProvider);
  return ref.watch(resourceProvider(path)).whenData((r) =>
      sortItems(r.items, prefs.sortField, prefs.sortAscending, showHidden));
});
