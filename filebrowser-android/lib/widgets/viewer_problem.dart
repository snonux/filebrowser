import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/file_actions.dart';

/// Why a viewer cannot show a file, with a way to open it in another app
/// instead when [item] is given (that needs the download permission).
class ViewerProblem extends StatelessWidget {
  const ViewerProblem({super.key, required this.message, this.item});

  final String message;
  final FileItem? item;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, textAlign: TextAlign.center),
          if (item != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open with another app'),
              onPressed: () =>
                  FileActions(context).download(item, openWhenDone: true),
            ),
          ],
        ]),
      ),
    );
  }
}
