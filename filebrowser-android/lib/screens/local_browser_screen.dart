import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/paths.dart';
import '../app_routes.dart';
import '../models/models.dart';
import '../providers/files_provider.dart';
import '../providers/local_files_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
import '../services/local_files.dart';
import '../utils/format.dart';
import '../widgets/app_drawer.dart';
import '../widgets/file_icon.dart';
import '../widgets/transfer_bar.dart';
import 'browser_screen.dart';
import 'local_actions.dart';

/// "On this phone": lists a folder of the phone's own storage. An empty
/// [path] shows the storage volumes, or the only one there is.
class LocalBrowserScreen extends ConsumerStatefulWidget {
  const LocalBrowserScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<LocalBrowserScreen> createState() => _LocalBrowserScreenState();
}

class _LocalBrowserScreenState extends ConsumerState<LocalBrowserScreen>
    with WidgetsBindingObserver {
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Access may have been granted in Android's settings, and other apps
    // may have changed the files.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(storageAccessProvider);
      if (widget.path.isNotEmpty) {
        ref.invalidate(localListingProvider(normalizePath(widget.path)));
      }
    }
  }

  Future<void> _refresh(String path) async {
    ref.invalidate(localListingProvider(path));
    try {
      await ref.read(localListingProvider(path).future);
    } catch (_) {
      // The error is shown by the list itself.
    }
  }

  void _toggle(FileItem item) => setState(() {
        if (!_selected.remove(item.path)) _selected.add(item.path);
      });

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(storageAccessProvider);
    final roots = ref.watch(storageRootsProvider);
    final drawer = _selecting || ModalRoute.of(context)?.isFirst == false
        ? null
        : const AppDrawer(currentPath: '/');
    Scaffold plain(Widget body) => Scaffold(
        appBar: AppBar(title: const Text('On this phone')),
        drawer: drawer,
        body: body);

    if (access.isLoading || roots.isLoading) {
      return plain(const Center(child: CircularProgressIndicator()));
    }
    if (access.valueOrNull != true) {
      return plain(ListMessage(
        icon: Icons.folder_off_outlined,
        text: 'File Browser needs access to all files to manage the files '
            'on this phone.',
        action: FilledButton(
          onPressed: () => ensureStorageAccess(context),
          child: const Text('Allow access'),
        ),
      ));
    }
    final volumes = roots.valueOrNull ?? const <StorageRoot>[];
    if (volumes.isEmpty) {
      return plain(const ListMessage(
          icon: Icons.sd_card_alert_outlined,
          text: 'No storage found on this phone'));
    }
    if (widget.path.isEmpty && volumes.length > 1) {
      return plain(ListView(children: [
        for (final volume in volumes)
          ListTile(
            leading: Icon(volume == volumes.first
                ? Icons.smartphone
                : Icons.sd_card_outlined),
            title: Text(volume.name),
            subtitle: Text(volume.path),
            onTap: () => context.push(AppRoutes.local(volume.path)),
          ),
      ]));
    }
    final path =
        widget.path.isEmpty ? volumes.first.path : normalizePath(widget.path);
    return _folder(context, path, volumes, drawer);
  }

  Widget _folder(BuildContext context, String path, List<StorageRoot> volumes,
      Widget? drawer) {
    final session = ref.watch(requireSessionProvider);
    final itemsAsync = ref.watch(localFolderItemsProvider(path));
    final items = itemsAsync.valueOrNull ?? const <FileItem>[];
    final selected = items.where((i) => _selected.contains(i.path)).toList();
    final actions = LocalActions(context);
    final root = rootOf(volumes, path);
    final title =
        root != null && root.path == path ? root.name : baseName(path);
    final canUpload = session.perm.create;

    Future<void> thenClear(Future<void> action) async {
      await action;
      if (mounted) setState(_selected.clear);
    }

    final appBar = _selecting
        ? AppBar(
            leading: IconButton(
              tooltip: 'Cancel selection',
              icon: const Icon(Icons.close),
              onPressed: () => setState(_selected.clear),
            ),
            title: Text('${_selected.length} selected'),
            actions: [
              IconButton(
                tooltip: 'Select all',
                icon: const Icon(Icons.select_all),
                onPressed: () =>
                    setState(() => _selected.addAll(items.map((i) => i.path))),
              ),
              if (canUpload)
                IconButton(
                  tooltip: 'Upload to server',
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: () => thenClear(
                      actions.sendToServer(context, selected, move: false)),
                ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => thenClear(switch (v) {
                  'move-server' =>
                    actions.sendToServer(context, selected, move: true),
                  'copy' => actions.transferTo(context, selected, copy: true),
                  'move' => actions.transferTo(context, selected, copy: false),
                  _ => actions.delete(context, selected),
                }),
                itemBuilder: (_) => [
                  if (canUpload)
                    const PopupMenuItem(
                        value: 'move-server', child: Text('Move to server…')),
                  const PopupMenuItem(value: 'copy', child: Text('Copy to…')),
                  const PopupMenuItem(value: 'move', child: Text('Move to…')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          )
        : AppBar(
            title: Text(title),
            actions: [
              const SortMenu(),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => switch (v) {
                  'hidden' => ref
                      .read(preferencesProvider.notifier)
                      .setShowHidden(!ref.read(showHiddenProvider)),
                  'refresh' => _refresh(path),
                  _ => null,
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: 'hidden',
                    checked: ref.watch(showHiddenProvider),
                    child: const Text('Show hidden files'),
                  ),
                  const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                ],
              ),
            ],
          );

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: appBar,
        drawer: drawer,
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton(
                tooltip: 'New folder',
                onPressed: () => actions.createFolder(context, path),
                child: const Icon(Icons.create_new_folder_outlined),
              ),
        bottomNavigationBar: const TransferBar(),
        body: Column(children: [
          _LocalBreadcrumbs(path: path, root: root),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(path),
              child: itemsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListMessage(
                  icon: Icons.error_outline,
                  text: e is FileSystemException
                      ? 'Cannot open this folder: '
                          '${e.osError?.message ?? e.message}'
                      : 'Cannot open this folder: $e',
                  action: TextButton(
                      onPressed: () => _refresh(path),
                      child: const Text('Retry')),
                ),
                data: (items) => items.isEmpty
                    ? const ListMessage(
                        icon: Icons.folder_off_outlined,
                        text: 'This folder is empty')
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          final isSelected = _selected.contains(item.path);
                          return ListTile(
                            key: ValueKey(item.path),
                            selected: isSelected,
                            leading: FileIcon(
                                item: item,
                                api: session.api,
                                local: item.isImage ? File(item.path) : null),
                            title: Text(item.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                item.isDir
                                    ? formatDate(item.modified)
                                    : '${formatSize(item.size)} · ${formatDate(item.modified)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            trailing: _selecting
                                ? Checkbox(
                                    value: isSelected,
                                    onChanged: (_) => _toggle(item))
                                : IconButton(
                                    tooltip: 'Actions for ${item.name}',
                                    icon: const Icon(Icons.more_vert),
                                    onPressed: () =>
                                        actions.showMenu(context, item),
                                  ),
                            onTap: () => _selecting
                                ? _toggle(item)
                                : actions.open(context, item),
                            onLongPress: () => _toggle(item),
                          );
                        },
                      ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The folder's location below its storage volume, as tappable segments.
class _LocalBreadcrumbs extends StatelessWidget {
  const _LocalBreadcrumbs({required this.path, required this.root});

  final String path;
  final StorageRoot? root;

  @override
  Widget build(BuildContext context) {
    final root = this.root;
    if (root == null || root.path == path) return const SizedBox.shrink();
    final parts = path
        .substring(root.path.length)
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList();
    final crumbs = <Widget>[
      TextButton(
        onPressed: () => context.go(AppRoutes.local(root.path)),
        child: Text(root.name),
      ),
    ];
    for (var i = 0; i < parts.length; i++) {
      final target = '${root.path}/${parts.take(i + 1).join('/')}';
      crumbs
        ..add(const Icon(Icons.chevron_right, size: 16))
        ..add(TextButton(
          onPressed: i == parts.length - 1
              ? null
              : () => context.go(AppRoutes.local(target)),
          child: Text(parts[i]),
        ));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: crumbs),
      ),
    );
  }
}
