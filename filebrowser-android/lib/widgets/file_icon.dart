import 'package:flutter/material.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';

/// A thumbnail for images, otherwise an icon for the file's type.
class FileIcon extends StatelessWidget {
  const FileIcon({super.key, required this.item, required this.api});

  final FileItem item;
  final FileBrowserApi api;

  static IconData iconFor(FileItem item) {
    if (item.isDir) return Icons.folder;
    return switch (item.type) {
      'image' => Icons.image_outlined,
      'video' => Icons.movie_outlined,
      'audio' => Icons.audiotrack_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'text' || 'textImmutable' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = item.isDir ? Theme.of(context).colorScheme.primary : null;
    final icon = Icon(iconFor(item), color: color, size: 32);
    if (!item.isImage) return SizedBox.square(dimension: 40, child: icon);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        api.previewUrl(item.path, 'thumb', modified: item.modified),
        headers: api.authHeaders,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        // SVGs and broken images have no raster thumbnail; show the icon.
        errorBuilder: (_, __, ___) =>
            SizedBox.square(dimension: 40, child: icon),
      ),
    );
  }
}
