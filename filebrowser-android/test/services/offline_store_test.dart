import 'dart:io';

import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/api/paths.dart';
import 'package:filebrowser_android/services/offline_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/fake_adapter.dart';

/// A tiny File Browser: folders are paths without content.
class FakeServer {
  final files = <String, String>{};
  final folders = <String>{'/'};
  final modified = <String, DateTime>{};
  bool reachable = true;
  int downloads = 0;
  int _clock = 0;

  void put(String path, String content) {
    files[path] = content;
    modified[path] = DateTime.utc(2026).add(Duration(seconds: ++_clock));
    for (var dir = parentOf(path); dir != '/'; dir = parentOf(dir)) {
      folders.add(dir);
    }
  }

  void remove(String path) {
    files.removeWhere((k, _) => k == path || k.startsWith('$path/'));
    folders.removeWhere((k) => k == path || k.startsWith('$path/'));
  }

  Map<String, dynamic> _item(String path) => {
        'path': path,
        'name': baseName(path),
        'isDir': folders.contains(path),
        'size': files[path]?.length ?? 0,
        'modified': (modified[path] ?? DateTime.utc(2026)).toIso8601String(),
        'type': folders.contains(path) ? '' : 'text',
      };

  ResponseBody handle(RequestOptions o) {
    if (!reachable) throw const SocketException('Connection refused');
    final segments = o.uri.pathSegments;
    final kind = segments[1];
    final path = normalizePath(segments.skip(2).join('/'));
    final exists = files.containsKey(path) || folders.contains(path);
    if (!exists) return reply(404);
    if (kind == 'raw') {
      downloads++;
      return reply(200, body: files[path]!);
    }
    return reply(200, body: {
      ..._item(path),
      if (folders.contains(path))
        'items': [
          for (final p in {...files.keys, ...folders})
            if (p != path && parentOf(p) == path) _item(p),
        ],
    });
  }
}

void main() {
  late Directory dir;
  late FakeServer server;
  late FileBrowserApi api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline-test');
    server = FakeServer()
      ..put('/notes.txt', 'top')
      ..put('/docs/a.txt', 'A')
      ..put('/docs/sub/b.txt', 'B')
      ..put('/docs/sub/deeper/c.txt', 'C')
      ..put('/other/x.txt', 'X');
    api = FileBrowserApi(
        baseUrl: 'http://fb.local',
        dio: Dio()..httpClientAdapter = FakeAdapter(server.handle))
      ..token = fakeToken();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<OfflineStore> open() => OfflineStore.open(dir);
  String? read(OfflineStore store, String path) =>
      store.localFile(path)?.readAsStringSync();

  test('a pinned file is downloaded and kept across restarts', () async {
    final store = await open();
    await store.pin('/notes.txt');
    await store.sync(api);
    expect(read(store, '/notes.txt'), 'top');
    expect(store.localFile('/notes.txt')!.path, endsWith('/notes.txt'));

    final again = await open();
    expect(again.pins, ['/notes.txt']);
    expect(read(again, '/notes.txt'), 'top');
    expect(again.localFile('/docs/a.txt'), isNull);
  });

  test('a pinned folder keeps all its subfolders', () async {
    final store = await open();
    await store.pin('/docs');
    await store.sync(api);
    expect(read(store, '/docs/a.txt'), 'A');
    expect(read(store, '/docs/sub/b.txt'), 'B');
    expect(read(store, '/docs/sub/deeper/c.txt'), 'C');
    expect(store.pinCovering('/docs/sub/deeper/c.txt'), '/docs');
    expect(store.covers('/other/x.txt'), isFalse);
    expect(store.usage.files, 3);
  });

  test('offline listings lead from Home down to the kept items', () async {
    final store = await open();
    await store.pin('/docs/sub');
    await store.sync(api);

    final home = store.listing('/')!;
    expect(home.offline, isTrue);
    expect(home.items.map((i) => (i.name, i.isDir)), [('docs', true)]);
    final docs = store.listing('/docs')!;
    expect(docs.items.map((i) => i.name), ['sub']);
    final sub = store.listing('/docs/sub')!;
    expect(sub.items.map((i) => i.name).toSet(), {'b.txt', 'deeper'});
    expect(sub.items.firstWhere((i) => i.name == 'b.txt').size, 1);
    expect(store.listing('/other'), isNull);
    expect(store.listing('/docs/sub/b.txt'), isNull);
  });

  test(
      'changes on the server are followed; unchanged files are not '
      'downloaded again', () async {
    final store = await open();
    await store.pin('/docs');
    await store.sync(api);
    expect(server.downloads, 3);

    server
      ..put('/docs/a.txt', 'A2')
      ..put('/docs/new.txt', 'N')
      ..remove('/docs/sub/deeper');
    await store.sync(api);
    expect(server.downloads, 5);
    expect(read(store, '/docs/a.txt'), 'A2');
    expect(read(store, '/docs/new.txt'), 'N');
    expect(store.localFile('/docs/sub/deeper/c.txt'), isNull);
    expect(store.listing('/docs/sub')!.items.map((i) => i.name), ['b.txt']);
  });

  test('a pin deleted on the server is dropped with its copies', () async {
    final store = await open();
    await store.pin('/docs');
    await store.pin('/notes.txt');
    await store.sync(api);
    final copy = store.localFile('/docs/a.txt')!;

    server.remove('/docs');
    await store.sync(api);
    expect(store.pins, ['/notes.txt']);
    expect(copy.existsSync(), isFalse);
    expect(store.listing('/docs'), isNull);
    expect(read(store, '/notes.txt'), 'top');
  });

  test('an unreachable server keeps every copy', () async {
    final store = await open();
    await store.pin('/docs');
    await store.sync(api);
    server
      ..reachable = false
      ..remove('/docs');
    await expectLater(
        store.sync(api),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', isNull)));
    expect(store.pins, ['/docs']);
    expect(read(store, '/docs/sub/b.txt'), 'B');
  });

  test('unpinning deletes the copies no other pin keeps', () async {
    final store = await open();
    await store.pin('/docs');
    await store.pin('/docs/sub');
    await store.sync(api);
    final a = store.localFile('/docs/a.txt')!;

    await store.unpin('/docs');
    expect(a.existsSync(), isFalse);
    expect(read(store, '/docs/sub/b.txt'), 'B');
    expect(store.covers('/docs/a.txt'), isFalse);

    await store.unpin('/docs/sub');
    expect(store.isEmpty, isTrue);
    expect(store.usage.files, 0);
    expect(store.listing('/'), isNull);
  });

  test('deleting in the app forgets the item', () async {
    final store = await open();
    await store.pin('/docs');
    await store.sync(api);
    await store.forget('/docs/sub');
    expect(store.localFile('/docs/sub/b.txt'), isNull);
    expect(read(store, '/docs/a.txt'), 'A');

    await store.forget('/docs');
    expect(store.isEmpty, isTrue);
  });

  test('renaming in the app keeps the copy under its new name', () async {
    final store = await open();
    await store.pin('/notes.txt');
    await store.pin('/docs');
    await store.sync(api);

    await store.moved('/notes.txt', '/renamed.txt');
    expect(store.pins, ['/docs', '/renamed.txt']);
    expect(read(store, '/renamed.txt'), 'top');
    expect(store.localFile('/renamed.txt')!.path, endsWith('/renamed.txt'));

    // Moved out of a kept folder: no longer kept.
    await store.moved('/docs/a.txt', '/other/a.txt');
    expect(store.localFile('/other/a.txt'), isNull);

    // A kept folder renamed keeps its whole tree.
    await store.moved('/docs', '/papers');
    expect(read(store, '/papers/sub/deeper/c.txt'), 'C');
    expect(store.item('/papers/sub/b.txt')!.path, '/papers/sub/b.txt');
  });

  test('a listing tells when kept copies are behind the server', () async {
    final store = await open();
    await store.pin('/docs');
    await store.sync(api);
    Future<bool> stale(String path) async =>
        store.isStale(path, await api.fetch(path));

    expect(await stale('/docs'), isFalse);
    expect(await stale('/other'), isFalse);
    server.put('/docs/a.txt', 'changed');
    expect(await stale('/docs'), isTrue);
    await store.sync(api);
    expect(await stale('/docs'), isFalse);
    server.remove('/docs/sub');
    expect(await stale('/docs'), isTrue);
  });
}
