import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/paths.dart';
import '../providers/local_files_provider.dart';
import '../services/local_files.dart';
import 'file_actions.dart';

/// Full-screen dialog to choose a folder on the phone. Pops with its path.
class LocalFolderPickerScreen extends ConsumerStatefulWidget {
  const LocalFolderPickerScreen(
      {super.key, required this.start, required this.action});

  final String start;
  final String action;

  @override
  ConsumerState<LocalFolderPickerScreen> createState() =>
      _LocalFolderPickerScreenState();
}

class _LocalFolderPickerScreenState
    extends ConsumerState<LocalFolderPickerScreen> {
  late String _path = normalizePath(widget.start);

  Future<void> _newFolder() async {
    final name = await askName(context, title: 'New folder', action: 'Create');
    if (name == null) return;
    final path = joinPath(_path, name);
    try {
      await ref.read(localFilesProvider).createFolder(path);
      ref.invalidate(localListingProvider(_path));
      setState(() => _path = path);
    } on LocalConflict catch (e) {
      showMessage('$e');
    } catch (e) {
      showMessage('Cannot create $name: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final roots = ref.watch(storageRootsProvider).valueOrNull ?? const [];
    final root = rootOf(roots, _path);
    final atRoot = root != null && root.path == _path;
    final listing = ref.watch(localFolderItemsProvider(_path));
    return Scaffold(
      appBar: AppBar(
        title: Text(atRoot ? root.name : baseName(_path)),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _newFolder,
          ),
        ],
      ),
      body: Column(children: [
        if (!atRoot && root != null)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('Parent folder'),
            onTap: () => setState(() => _path = parentOf(_path)),
          ),
        if (atRoot && roots.length > 1)
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final r in roots)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ChoiceChip(
                      label: Text(r.name),
                      selected: r.path == _path,
                      onSelected: (_) => setState(() => _path = r.path),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: listing.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Cannot open this folder: $e')),
            data: (items) {
              final dirs = items.where((i) => i.isDir).toList();
              if (dirs.isEmpty) {
                return const Center(child: Text('No subfolders'));
              }
              return ListView(children: [
                for (final dir in dirs)
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(dir.name),
                    onTap: () => setState(() => _path = dir.path),
                  ),
              ]);
            },
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _path),
            child: Text(widget.action),
          ),
        ),
      ),
    );
  }
}
