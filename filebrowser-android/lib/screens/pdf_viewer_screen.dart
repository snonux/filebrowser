import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../utils/format.dart';
import '../widgets/viewer_problem.dart';
import 'file_actions.dart';

/// Shows a PDF: pages scroll vertically and pinch-zoom. The file is fetched
/// into memory first, through the API client so the session's credentials
/// (and a proxy login) apply.
class PdfViewerScreen extends ConsumerStatefulWidget {
  const PdfViewerScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends ConsumerState<PdfViewerScreen> {
  final _cancel = CancelToken();
  final _controller = PdfViewerController();
  FileItem? _item;
  Uint8List? _bytes;
  String? _error;
  int _received = 0;
  int _total = -1;
  int? _page;
  int _pageCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(requireSessionProvider).api;
    try {
      final item = (await api.fetch(widget.path)).item;
      if (mounted) setState(() => _item = item);
      final bytes = await api.readBytes(widget.path, cancelToken: _cancel,
          onProgress: (received, total) {
        if (mounted) {
          setState(() {
            _received = received;
            _total = total < 0 ? item.size : total;
          });
        }
      });
      if (mounted) setState(() => _bytes = bytes);
    } on ApiException catch (e) {
      if (mounted && !_cancel.isCancelled) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perm = ref.watch(requireSessionProvider).perm;
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: Text(baseName(widget.path)),
        actions: [
          if (_pageCount > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('${_page ?? 1} / $_pageCount'),
              ),
            ),
          if (item != null && perm.download)
            IconButton(
              tooltip: 'Download',
              icon: const Icon(Icons.download),
              onPressed: () => FileActions(context).download(item),
            ),
          if (item != null)
            IconButton(
              tooltip: 'Actions',
              icon: const Icon(Icons.more_vert),
              onPressed: () => FileActions(context).showMenu(context, item),
            ),
        ],
      ),
      body: _body(context, item, perm.download),
    );
  }

  Widget _body(BuildContext context, FileItem? item, bool canDownload) {
    if (_error != null) {
      return ViewerProblem(
        message: _error!,
        item: canDownload ? item : null,
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      final fraction = _total > 0 ? _received / _total : null;
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(value: fraction),
          if (_total > 0) ...[
            const SizedBox(height: 16),
            Text('${formatSize(_received)} of ${formatSize(_total)}'),
          ],
        ]),
      );
    }
    return PdfViewer.data(
      bytes,
      sourceName: widget.path,
      controller: _controller,
      params: PdfViewerParams(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        onViewerReady: (document, controller) => setState(() {
          _pageCount = document.pages.length;
          _page = controller.pageNumber;
        }),
        onPageChanged: (page) => setState(() => _page = page),
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            ViewerProblem(
          message: 'This PDF cannot be shown: $error',
          item: canDownload ? item : null,
        ),
      ),
    );
  }
}
