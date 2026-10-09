import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../providers/files_provider.dart';

/// Full-screen dialog to choose a destination folder. Pops with its path.
class FolderPickerScreen extends ConsumerStatefulWidget {
  const FolderPickerScreen(
      {super.key, required this.start, required this.action});

  final String start;
  final String action;

  @override
  ConsumerState<FolderPickerScreen> createState() => _FolderPickerScreenState();
}

class _FolderPickerScreenState extends ConsumerState<FolderPickerScreen> {
  late String _path = normalizePath(widget.start);

  @override
  Widget build(BuildContext context) {
    final listing = ref.watch(folderItemsProvider(_path));
    return Scaffold(
      appBar: AppBar(
        title: Text(_path == '/' ? 'Home' : baseName(_path)),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(children: [
        if (_path != '/')
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('Parent folder'),
            onTap: () => setState(() => _path = parentOf(_path)),
          ),
        Expanded(
          child: listing.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(ApiException.from(e).message)),
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
