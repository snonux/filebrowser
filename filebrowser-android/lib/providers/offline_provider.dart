import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../services/offline_store.dart';
import 'device_files_provider.dart';
import 'session_provider.dart';

/// What the screens show about offline copies. [store] is null until it is
/// loaded, and while nobody is signed in.
class OfflineStatus {
  const OfflineStatus({this.store, this.syncing = false, this.error});

  final OfflineStore? store;

  /// Whether copies are being brought up to date.
  final bool syncing;

  /// Why the last update did not finish, for example an unreachable server.
  final String? error;
}

/// Keeps the files and folders marked "available offline" on the device, one
/// store per server and account.
///
/// The copies are updated when the app starts, when an item is marked, when
/// a listing of a kept folder shows changes, and on request.
class OfflineController extends Notifier<OfflineStatus> {
  Future<OfflineStore?> _ready = Future.value(null);
  OfflineStore? _store;
  Future<void>? _syncing;
  bool _syncAgain = false;

  /// The account's store once it is loaded; null when nobody is signed in or
  /// it cannot be opened.
  Future<OfflineStore?> get ready => _ready;

  @override
  OfflineStatus build() {
    final account = ref.watch(sessionProvider.select((s) {
      final session = s.valueOrNull;
      return session == null
          ? null
          : '${session.api.baseUrl}\n${session.user.username}';
    }));
    _store = null;
    if (account == null) {
      _ready = Future.value(null);
      return const OfflineStatus();
    }
    final device = ref.read(deviceFilesProvider);
    final ready = () async {
      try {
        final dir = await device.offlineDirectory();
        // One folder per server and user, named so any address fits.
        final name = base64Url.encode(utf8.encode(account)).replaceAll('=', '');
        return await OfflineStore.open(Directory('${dir.path}/$name'));
      } on Object {
        return null;
      }
    }();
    _ready = ready;
    ready.then((store) {
      if (!identical(_ready, ready) || store == null) return;
      _store = store;
      state = OfflineStatus(store: store);
      if (!store.isEmpty) sync();
    });
    return const OfflineStatus();
  }

  void _changed(OfflineStore store, {bool? syncing, String? error}) {
    if (!identical(store, _store)) return;
    state = OfflineStatus(
      store: store,
      syncing: syncing ?? state.syncing,
      error: error,
    );
  }

  /// Brings every copy up to date. Calls made while an update runs start one
  /// more afterwards.
  Future<void> sync() {
    final running = _syncing;
    if (running != null) {
      _syncAgain = true;
      return running;
    }
    final run = _run().whenComplete(() => _syncing = null);
    _syncing = run;
    return run;
  }

  Future<void> _run() async {
    do {
      _syncAgain = false;
      final store = await _ready;
      final api = ref.read(sessionProvider).valueOrNull?.api;
      if (store == null || api == null || !identical(store, _store)) return;
      _changed(store, syncing: true);
      try {
        await store.sync(api, onChange: () => _changed(store));
        _changed(store, syncing: false);
      } on Object catch (e) {
        _changed(store, syncing: false, error: ApiException.from(e).message);
        return;
      }
    } while (_syncAgain);
  }

  /// Marks [item] to be kept offline and starts downloading it.
  Future<void> pin(FileItem item) async {
    final store = await _ready;
    if (store == null) return;
    await store.pin(item.path);
    _changed(store);
    await sync();
  }

  /// Stops keeping [path] offline and deletes its copies.
  Future<void> unpin(String path) async {
    final store = await _ready;
    if (store == null) return;
    await store.unpin(path);
    _changed(store, error: state.error);
  }

  /// Drops [path] after the app deleted it.
  Future<void> deleted(String path) async {
    final store = await _ready;
    if (store == null) return;
    await store.forget(path);
    _changed(store, error: state.error);
  }

  /// Follows the app's rename or move of [from] to [to].
  Future<void> moved(String from, String to) async {
    final store = await _ready;
    if (store == null) return;
    await store.moved(from, to);
    _changed(store, error: state.error);
    if (store.covers(to)) await sync();
  }

  /// Called with each folder listing fetched from the server; updates the
  /// copies when it shows changes to a kept folder.
  void listed(String path, Resource listing) {
    final store = _store;
    if (store != null && store.isStale(path, listing)) sync();
  }
}

final offlineProvider =
    NotifierProvider<OfflineController, OfflineStatus>(OfflineController.new);
