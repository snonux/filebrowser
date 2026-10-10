import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../utils/format.dart';
import '../widgets/viewer_problem.dart';
import 'file_actions.dart';

/// Plays a video or audio file, streamed from the server (seeking uses HTTP
/// range requests, so nothing is downloaded first).
class MediaPlayerScreen extends ConsumerStatefulWidget {
  const MediaPlayerScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<MediaPlayerScreen> createState() => _MediaPlayerScreenState();
}

class _MediaPlayerScreenState extends ConsumerState<MediaPlayerScreen> {
  VideoPlayerController? _player;
  FileItem? _item;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    final player = _player;
    // The plugin has no implementation on some desktop platforms, where
    // disposing throws like everything else.
    if (player != null) unawaited(player.dispose().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(requireSessionProvider).api;
    try {
      // Fetching the item first also renews an expired session, so the
      // credentials handed to the player below are current.
      final item = (await api.fetch(widget.path)).item;
      if (!mounted) return;
      setState(() => _item = item);
      final player = VideoPlayerController.networkUrl(
        Uri.parse(api.rawUrl(widget.path)),
        httpHeaders: api.authHeaders,
      );
      _player = player;
      await player.initialize();
      player.addListener(_onPlayerChanged);
      await player.play();
      if (mounted) setState(() => _ready = true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // Unsupported format or codec, a network error, or no player on this
      // platform.
      if (mounted) {
        setState(() => _error = 'This file cannot be played here.');
      }
    }
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    final error = _player!.value.errorDescription;
    if (error != null && _error == null) {
      setState(() => _error = 'Playback failed: $error');
    } else {
      setState(() {});
    }
  }

  void _togglePlay() {
    final player = _player!;
    if (player.value.isPlaying) {
      player.pause();
    } else {
      // Starting again at the end replays from the beginning.
      if (player.value.position >= player.value.duration) {
        player.seekTo(Duration.zero);
      }
      player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final perm = ref.watch(requireSessionProvider).perm;
    final item = _item;
    final isVideo = item?.isVideo ?? false;
    final dark = isVideo && _error == null;
    return Scaffold(
      backgroundColor: dark ? Colors.black : null,
      appBar: AppBar(
        backgroundColor: dark ? Colors.black : null,
        foregroundColor: dark ? Colors.white : null,
        title: Text(baseName(widget.path)),
        actions: [
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
      return ViewerProblem(message: _error!, item: canDownload ? item : null);
    }
    final player = _player;
    if (!_ready || player == null || item == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final value = player.value;
    final picture = item.isVideo
        ? GestureDetector(
            onTap: _togglePlay,
            child: AspectRatio(
              aspectRatio: value.aspectRatio,
              child: VideoPlayer(player),
            ),
          )
        : Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.audiotrack,
                size: 120, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(item.name,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ]);
    final controlsColor = item.isVideo ? Colors.white : null;
    return SafeArea(
      child: Column(children: [
        Expanded(child: Center(child: picture)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: VideoProgressIndicator(player,
              allowScrubbing: true,
              padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Text(formatDuration(value.position),
                style: TextStyle(color: controlsColor)),
            const Spacer(),
            IconButton(
              tooltip: 'Back 10 seconds',
              color: controlsColor,
              icon: const Icon(Icons.replay_10),
              onPressed: () =>
                  player.seekTo(value.position - const Duration(seconds: 10)),
            ),
            IconButton.filled(
              tooltip: value.isPlaying ? 'Pause' : 'Play',
              iconSize: 36,
              icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: _togglePlay,
            ),
            IconButton(
              tooltip: 'Forward 10 seconds',
              color: controlsColor,
              icon: const Icon(Icons.forward_10),
              onPressed: () =>
                  player.seekTo(value.position + const Duration(seconds: 10)),
            ),
            const Spacer(),
            Text(formatDuration(value.duration),
                style: TextStyle(color: controlsColor)),
          ]),
        ),
      ]),
    );
  }
}
