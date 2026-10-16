import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/paths.dart';
import '../app_routes.dart';
import '../navigation_key.dart';
import '../providers/bookmarks_provider.dart';
import '../providers/local_files_provider.dart';
import '../widgets/file_icon.dart';
import 'file_actions.dart';
import 'local_actions.dart';

/// Opens what [bookmark] points to: a folder in the browser, a file in the
/// app's viewer or another app. Server items open from their offline copies
/// when the server cannot be reached.
Future<void> openBookmark(BuildContext context, Bookmark bookmark) async {
  if (!bookmark.onPhone) {
    if (bookmark.isDir) {
      context.push(AppRoutes.files(bookmark.path));
    } else {
      await FileActions(context).open(context, bookmark.item);
    }
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  if (!await ensureStorageAccess(context) || !context.mounted) return;
  final item = await container.read(localFilesProvider).stat(bookmark.path);
  if (!context.mounted) return;
  if (item == null) {
    showMessage('${bookmark.name} is no longer on this phone',
        action: SnackBarAction(
            label: 'Remove',
            onPressed: () =>
                container.read(bookmarksProvider.notifier).remove(bookmark)));
    return;
  }
  await LocalActions(context).open(context, item);
}

/// Where a bookmark is, for its subtitle: "Server · /projects" or
/// "Phone · Internal storage/Download".
String bookmarkLocation(WidgetRef ref, Bookmark bookmark) {
  final parent = parentOf(bookmark.path);
  if (!bookmark.onPhone) {
    return bookmark.path == '/' ? 'Server' : 'Server · $parent';
  }
  final roots = ref.watch(storageRootsProvider).valueOrNull ?? const [];
  final root = rootOf(roots, parent);
  final where = root == null
      ? parent
      : '${root.name}${parent.substring(root.path.length)}';
  return 'Phone · $where';
}

/// One bookmark in a list; tapping it opens the item.
class BookmarkTile extends ConsumerWidget {
  const BookmarkTile(
      {super.key, required this.bookmark, this.trailing, this.onOpen});

  final Bookmark bookmark;
  final Widget? trailing;

  /// Runs before the item opens, for example to close the drawer.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(FileIcon.iconFor(bookmark.item),
          color: bookmark.isDir ? Theme.of(context).colorScheme.primary : null),
      title: Text(bookmark.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(bookmarkLocation(ref, bookmark),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: () {
        final onOpen = this.onOpen;
        if (onOpen == null) {
          openBookmark(context, bookmark);
          return;
        }
        // The tile goes away with the drawer; open from the app's navigator.
        onOpen();
        openBookmark(appNavigatorKey.currentContext ?? context, bookmark);
      },
    );
  }
}

/// All bookmarks, with a way to remove each.
class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref.watch(bookmarksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Bookmarks')),
      body: bookmarks.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No bookmarks yet. Choose "Add bookmark" in the menu of a '
                'file or folder, on the server or on this phone, to open it '
                'quickly from here and from the menu drawer.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView(children: [
              for (final bookmark in bookmarks)
                BookmarkTile(
                  key: ValueKey('${bookmark.place.name}:${bookmark.path}'),
                  bookmark: bookmark,
                  trailing: IconButton(
                    tooltip: 'Remove bookmark of ${bookmark.name}',
                    icon: const Icon(Icons.bookmark_remove_outlined),
                    onPressed: () {
                      ref.read(bookmarksProvider.notifier).remove(bookmark);
                      showMessage('Removed the bookmark of ${bookmark.name}');
                    },
                  ),
                ),
            ]),
    );
  }
}
