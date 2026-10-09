import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import 'file_actions.dart';

/// Searches by name below a folder. File Browser also accepts `type:image`
/// and similar filters and quoted phrases, so the query is passed as typed.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _query = TextEditingController();
  List<SearchHit>? _hits;
  bool _busy = false;
  String? _error;

  String get _scope => normalizePath(widget.path);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hits =
          await ref.read(requireSessionProvider).api.search(_scope, query);
      setState(() => _hits = hits);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText:
                _scope == '/' ? 'Search' : 'Search in ${baseName(_scope)}',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search),
              onPressed: _search),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : hits == null
                  ? const SizedBox.shrink()
                  : hits.isEmpty
                      ? const Center(child: Text('No results'))
                      : ListView(children: [
                          for (final hit in hits)
                            ListTile(
                              leading: Icon(hit.isDir
                                  ? Icons.folder
                                  : Icons.insert_drive_file_outlined),
                              title: Text(baseName(hit.path)),
                              subtitle: Text(hit.path),
                              onTap: () => FileActions(context).openPath(
                                  context, joinPath(_scope, hit.path)),
                            ),
                        ]),
    );
  }
}
