import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Files or text another app shared with File Browser.
class SharedContent {
  const SharedContent(
      {this.files = const [], this.text, this.subject, this.dir, this.error});

  /// Copies of the shared files, in [dir].
  final List<File> files;

  /// Shared text, when no files came with it.
  final String? text;

  /// The sender's title for the share, such as a page or mail subject.
  final String? subject;

  /// Folder holding this share's copies; removed when the share is done.
  final Directory? dir;

  /// Why the shared files could not be read.
  final String? error;

  bool get isText => files.isEmpty && (text?.isNotEmpty ?? false);

  /// Removes the copies of the shared files.
  Future<void> discard() async {
    try {
      if (dir != null && await dir!.exists()) {
        await dir!.delete(recursive: true);
      }
    } on FileSystemException {
      // The cache is cleaned up by Android or on a later share.
    }
  }
}

/// Delivers what other apps share with File Browser. Tests replace it.
abstract interface class ShareReceiver {
  Stream<SharedContent> get shares;
}

/// Android's "Share" menu, through the channel in MainActivity.kt.
class PlatformShareReceiver implements ShareReceiver {
  static const _channel = MethodChannel('org.buetow.filebrowser/share');

  final _controller = StreamController<SharedContent>.broadcast();
  bool _started = false;

  @override
  Stream<SharedContent> get shares {
    if (!_started) {
      _started = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'received') await _take();
      });
      // A share that launched the app may already be waiting.
      _take();
    }
    return _controller.stream;
  }

  Future<void> _take() async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>('take');
    } on MissingPluginException {
      return; // Not on Android, e.g. the Linux build of the e2e test.
    }
    if (raw == null) return;
    final dir = raw['dir'] as String?;
    _controller.add(SharedContent(
      files: [
        for (final path in (raw['files'] as List?) ?? const []) File('$path'),
      ],
      text: raw['text'] as String?,
      subject: raw['subject'] as String?,
      dir: dir == null ? null : Directory(dir),
      error: raw['error'] as String?,
    ));
  }
}
