import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../app_routes.dart';
import '../models/models.dart';
import '../providers/files_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
import '../utils/format.dart';
import '../widgets/app_drawer.dart';
import '../widgets/file_icon.dart';
import '../widgets/transfer_bar.dart';
import 'file_actions.dart';

/// Lists one folder. Tap opens an entry, the ⋮ button or a long press on an
/// entry offers the other actions; long press starts multi-selection.
class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  final Set<String> _selected = {};

  String get _path => normalizePath(widget.path);
  bool get _selecting => _selected.isNotEmpty;

  Future<void> _refresh() async {
    ref.invalidate(resourceProvider(_path));
    try {
      await ref.read(resourceProvider(_path).future);
    } catch (_) {
      // The error is shown by the list itself.
    }
  }

  void _toggle(FileItem item) => setState(() {
        if (!_selected.remove(item.path)) _selected.add(item.path);
      });

  List<FileItem> _selectedItems(List<FileItem> items) =>
      items.where((i) => _selected.contains(i.path)).toList();

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(requireSessionProvider);
    final perm = session.perm;
    final itemsAsync = ref.watch(folderItemsProvider(_path));
    final items = itemsAsync.valueOrNull ?? const <FileItem>[];
    final actions = FileActions(context);
    final title = _path == '/' ? 'Home' : baseName(_path);

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
              if (perm.create)
                IconButton(
                  tooltip: 'Copy to',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await actions.transferTo(context, _selectedItems(items),
                        copy: true);
                    if (mounted) setState(_selected.clear);
                  },
                ),
              if (perm.rename)
                IconButton(
                  tooltip: 'Move to',
                  icon: const Icon(Icons.drive_file_move_outline),
                  onPressed: () async {
                    await actions.transferTo(context, _selectedItems(items),
                        copy: false);
                    if (mounted) setState(_selected.clear);
                  },
                ),
              if (perm.delete)
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (await actions.delete(context, _selectedItems(items)) &&
                        mounted) {
                      setState(_selected.clear);
                    }
                  },
                ),
            ],
          )
        : AppBar(
            title: Text(title),
            actions: [
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: () => context.push(AppRoutes.search(_path)),
              ),
              const _SortMenu(),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => switch (v) {
                  'hidden' => ref
                      .read(preferencesProvider.notifier)
                      .setShowHidden(!ref.read(showHiddenProvider)),
                  'zip' => actions.download(FileItem(
                      path: _path,
                      name: _path == '/' ? 'files' : baseName(_path),
                      size: 0,
                      modified: DateTime.now(),
                      isDir: true,
                      type: '')),
                  'refresh' => _refresh(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: 'hidden',
                    checked: ref.watch(showHiddenProvider),
                    child: const Text('Show hidden files'),
                  ),
                  if (perm.download)
                    const PopupMenuItem(
                        value: 'zip', child: Text('Download folder as zip')),
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
        // A folder opened from another shows a back arrow; the menu drawer
        // is on the first screen of the stack.
        drawer: _selecting || GoRouter.of(context).canPop()
            ? null
            : AppDrawer(currentPath: _path),
        floatingActionButton: perm.create && !_selecting
            ? FloatingActionButton(
                tooltip: 'Add',
                onPressed: () => _showAddMenu(context, actions),
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: const TransferBar(),
        body: Column(
          children: [
            _Breadcrumbs(path: _path),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: itemsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _Message(
                    icon: Icons.error_outline,
                    text: ApiException.from(e).message,
                    action: TextButton(
                        onPressed: _refresh, child: const Text('Retry')),
                  ),
                  data: (items) => items.isEmpty
                      ? const _Message(
                          icon: Icons.folder_off_outlined,
                          text: 'This folder is empty')
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final item = items[i];
                            final selected = _selected.contains(item.path);
                            return ListTile(
                              key: ValueKey(item.path),
                              selected: selected,
                              leading: FileIcon(item: item, api: session.api),
                              title: Text(item.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(item.isDir
                                  ? formatDate(item.modified)
                                  : '${formatSize(item.size)} · ${formatDate(item.modified)}'),
                              trailing: _selecting
                                  ? Checkbox(
                                      value: selected,
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
          ],
        ),
      ),
    );
  }

  void _showAddMenu(BuildContext context, FileActions actions) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Upload files'),
            onTap: () {
              Navigator.pop(sheet);
              actions.upload(context, _path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder'),
            onTap: () {
              Navigator.pop(sheet);
              actions.createFolder(context, _path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('New file'),
            onTap: () {
              Navigator.pop(sheet);
              actions.createFile(context, _path);
            },
          ),
        ]),
      ),
    );
  }
}

class _SortMenu extends ConsumerWidget {
  const _SortMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(preferencesProvider);
    return PopupMenuButton<SortField>(
      tooltip: 'Sort',
      icon: const Icon(Icons.sort),
      onSelected: (field) => ref.read(preferencesProvider.notifier).setSort(
          field, field == prefs.sortField ? !prefs.sortAscending : true),
      itemBuilder: (_) => [
        for (final (field, label) in [
          (SortField.name, 'Name'),
          (SortField.size, 'Size'),
          (SortField.modified, 'Last modified'),
        ])
          PopupMenuItem(
            value: field,
            child: Row(children: [
              Expanded(child: Text(label)),
              if (field == prefs.sortField)
                Icon(prefs.sortAscending
                    ? Icons.arrow_upward
                    : Icons.arrow_downward),
            ]),
          ),
      ],
    );
  }
}

/// The folder's location as tappable segments.
class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (path == '/') return const SizedBox.shrink();
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    final crumbs = <Widget>[
      TextButton(
        onPressed: () => context.go(AppRoutes.files('/')),
        child: const Text('Home'),
      ),
    ];
    for (var i = 0; i < parts.length; i++) {
      final target = '/${parts.take(i + 1).join('/')}';
      crumbs
        ..add(const Icon(Icons.chevron_right, size: 16))
        ..add(TextButton(
          onPressed: i == parts.length - 1
              ? null
              : () => context.go(AppRoutes.files(target)),
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

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // A scrollable so pull-to-refresh also works on an empty or failed folder.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(icon, size: 48, color: Theme.of(context).disabledColor),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center),
        if (action != null) Center(child: action),
      ],
    );
  }
}
