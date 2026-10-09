import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/paths.dart';
import '../models/models.dart';
import '../providers/files_provider.dart';
import '../providers/session_provider.dart';
import 'file_actions.dart';

/// Swipes through the images of a folder, starting at [path].
class ImageViewerScreen extends ConsumerStatefulWidget {
  const ImageViewerScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends ConsumerState<ImageViewerScreen> {
  PageController? _pages;
  int _index = 0;

  // Paging is turned off while the current image is zoomed in, so a drag
  // pans the image instead of switching to the next one.
  final _zoom = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() {
      final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    });
  }

  @override
  void dispose() {
    _pages?.dispose();
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(requireSessionProvider);
    final images = ref
            .watch(folderItemsProvider(parentOf(widget.path)))
            .valueOrNull
            ?.where((i) => i.isImage)
            .toList() ??
        const <FileItem>[];
    if (images.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(baseName(widget.path))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_pages == null) {
      _index = images.indexWhere((i) => i.path == normalizePath(widget.path));
      if (_index < 0) _index = 0;
      _pages = PageController(initialPage: _index);
    }
    final current = images[_index.clamp(0, images.length - 1)];
    final api = session.api;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(current.name),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('${_index + 1} / ${images.length}'),
            ),
          ),
          if (session.perm.download)
            IconButton(
              tooltip: 'Download',
              icon: const Icon(Icons.download),
              onPressed: () => FileActions(context).download(current),
            ),
          IconButton(
            tooltip: 'Actions',
            icon: const Icon(Icons.more_vert),
            onPressed: () => FileActions(context).showMenu(context, current),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: images.length,
        physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
        onPageChanged: (i) => setState(() {
          _index = i;
          _zoom.value = Matrix4.identity();
        }),
        itemBuilder: (context, i) => InteractiveViewer(
          transformationController: i == _index ? _zoom : null,
          panEnabled: _zoomed,
          maxScale: 6,
          child: Center(
            child: Image.network(
              api.previewUrl(images[i].path, 'big',
                  modified: images[i].modified),
              headers: api.authHeaders,
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator()),
              errorBuilder: (_, __, ___) => const Text('Image unavailable',
                  style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}
