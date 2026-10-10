import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_adapter.dart';

void main() {
  late FakeAdapter adapter;
  late FileBrowserApi api;
  late List<String> renewed;
  Future<String?> Function()? reauth;

  FileBrowserApi build(ResponseBody Function(RequestOptions) handler,
      {BasicAuth? basicAuth}) {
    adapter = FakeAdapter(handler);
    renewed = [];
    return FileBrowserApi(
      baseUrl: 'http://fb.local/base/',
      basicAuth: basicAuth,
      dio: Dio()..httpClientAdapter = adapter,
      onTokenRenewed: renewed.add,
      reauthenticate: () => reauth?.call() ?? Future.value(),
    );
  }

  setUp(() => reauth = null);

  test('normalizes the server address', () {
    expect(FileBrowserApi.normalizeBaseUrl(' files.example.com/ '),
        'https://files.example.com');
    expect(FileBrowserApi.normalizeBaseUrl('http://10.0.0.2:8080/fb//'),
        'http://10.0.0.2:8080/fb');
  });

  test('login stores the token and later requests send it', () async {
    final token = fakeToken();
    api = build((o) => o.path.endsWith('/api/login')
        ? reply(200, body: token)
        : reply(200,
            body: {'name': '', 'path': '/', 'isDir': true, 'items': []}));
    expect(await api.login('alice', 'pw'), token);
    final login = adapter.requests.single;
    expect(login.uri.toString(), 'http://fb.local/base/api/login');
    expect(login.headers.containsKey('X-Auth'), isFalse);

    await api.fetch('/');
    expect(adapter.requests.last.uri.toString(),
        'http://fb.local/base/api/resources/');
    expect(adapter.requests.last.headers['X-Auth'], token);
  });

  test('wrong password is a 403 ApiException', () async {
    api = build((_) => reply(403));
    expect(
        () => api.login('alice', 'nope'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)));
  });

  test('a non-token login answer is rejected', () async {
    api = build((_) => reply(200, body: '<html>proxy page</html>'));
    expect(() => api.login('alice', 'pw'), throwsA(isA<ApiException>()));
  });

  test('paths are encoded per segment', () async {
    api = build((_) => reply(200, body: {'path': '/', 'items': []}))
      ..token = fakeToken();
    await api.fetch('/a b/c#d?e%f+g');
    expect(adapter.requests.single.uri.toString(),
        'http://fb.local/base/api/resources/a%20b/c%23d%3Fe%25f%2Bg');
  });

  test('move and copy encode the destination twice', () async {
    api = build((_) => reply(200))..token = fakeToken();
    await api.move('/x.txt', '/dir/a+b %.txt');
    final uri = adapter.requests.single.uri;
    expect(uri.queryParameters['action'], 'rename');
    // After the query string is decoded the server unescapes once more.
    expect(Uri.decodeQueryComponent(uri.queryParameters['destination']!),
        '/dir/a+b %.txt');
    await api.copy('/x.txt', '/y.txt', override: true);
    expect(adapter.requests.last.uri.queryParameters['action'], 'copy');
    expect(adapter.requests.last.uri.queryParameters['override'], 'true');
  });

  test('a 401 re-authenticates once and retries', () async {
    final fresh = fakeToken(username: 'fresh');
    var calls = 0;
    reauth = () async {
      calls++;
      return fresh;
    };
    api = build((o) => o.headers['X-Auth'] == fresh
        ? reply(200, body: {'path': '/', 'items': []})
        : reply(401))
      ..token = 'old.token.value';
    await api.fetch('/');
    expect(calls, 1);
    expect(api.token, fresh);
    expect(adapter.sentHeaders.map((h) => h['X-Auth']),
        ['old.token.value', fresh]);
  });

  test('a 401 without re-authentication surfaces as unauthorized', () async {
    reauth = () async => null;
    api = build((_) => reply(401))..token = 'a.b.c';
    expect(
        () => api.fetch('/'),
        throwsA(
            isA<ApiException>().having((e) => e.isUnauthorized, 'u', true)));
  });

  test('X-Renew-Token renews at most once a minute', () async {
    final fresh = fakeToken(username: 'renewed');
    api = build((o) => o.path.endsWith('/api/renew')
        ? reply(200, body: fresh)
        : reply(200,
            body: {'path': '/', 'items': []},
            headers: {'X-Renew-Token': 'true'}))
      ..token = 'a.b.c';
    await api.fetch('/');
    await Future<void>.delayed(Duration.zero);
    await api.fetch('/');
    await Future<void>.delayed(Duration.zero);
    expect(
        adapter.requests.where((r) => r.path.endsWith('/api/renew')).length, 1);
    expect(renewed, [fresh]);
    expect(api.token, fresh);
  });

  test('basic auth goes to the server only', () async {
    api = build((_) => reply(200, body: ''),
        basicAuth: const BasicAuth('gate', 'pw'))
      ..token = 'a.b.c';
    await api.dio.get<String>('http://fb.local/base/api/usage/');
    expect(
        adapter.requests.last.headers['Authorization'], 'Basic Z2F0ZTpwdw==');
    await api.dio.get<String>('http://elsewhere.local/x');
    expect(adapter.requests.last.headers.containsKey('Authorization'), isFalse);
    expect(adapter.requests.last.headers.containsKey('X-Auth'), isFalse);
    expect(api.authHeaders,
        {'X-Auth': 'a.b.c', 'Authorization': 'Basic Z2F0ZTpwdw=='});
  });

  test('search parses the streamed lines', () async {
    api = build((_) => reply(200,
        body: '{"dir":false,"path":"a/b.txt"}\n\n{"dir":true,"path":"c"}\n'))
      ..token = 'a.b.c';
    final hits = await api.search('/docs', 'b');
    expect(adapter.requests.single.uri.toString(),
        'http://fb.local/base/api/search/docs?query=b');
    expect(
        hits.map((h) => (h.path, h.isDir)), [('a/b.txt', false), ('c', true)]);
  });

  group('shares', () {
    const link = {
      'hash': 'h1',
      'path': '/f',
      'userID': 7,
      'expire': 0,
      'hasPassword': false
    };
    Map<String, dynamic> sentBody() =>
        jsonDecode(adapter.requests.single.data as String)
            as Map<String, dynamic>;

    test('createShare sends expiry as a string', () async {
      api = build((_) => reply(200, body: link))..token = 'a.b.c';
      final share = await api.createShare('/a dir/f#1',
          expires: 3, unit: 'days', password: 'pw');
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(),
          'http://fb.local/base/api/share/a%20dir/f%231');
      expect(sentBody(), {'password': 'pw', 'expires': '3', 'unit': 'days'});
      expect(share.hash, 'h1');
      expect(share.userId, 7);
    });

    test('createShare without options asks for a permanent open link',
        () async {
      api = build((_) => reply(200, body: link))..token = 'a.b.c';
      await api.createShare('/f');
      expect(sentBody(), {'password': '', 'expires': '', 'unit': 'hours'});
    });

    test('createShare accepts every unit of the web UI', () async {
      for (final unit in ['seconds', 'minutes', 'hours', 'days']) {
        api = build((_) => reply(200, body: link))..token = 'a.b.c';
        await api.createShare('/f', expires: 1, unit: unit);
        expect(sentBody()['unit'], unit);
      }
    });

    test('createShare refuses bad options without calling the server',
        () async {
      api = build((_) => reply(200, body: link))..token = 'a.b.c';
      // The refusal arrives through the future, like every other failure.
      await expectLater(
          api.createShare('/f', expires: -1), throwsArgumentError);
      await expectLater(
          api.createShare('/f', expires: 2147483648, unit: 'seconds'),
          throwsArgumentError);
      await expectLater(api.createShare('/f', expires: 1, unit: 'weeks'),
          throwsArgumentError);
      expect(adapter.requests, isEmpty);
    });

    test('createShare refuses a lifetime the server would overflow on',
        () async {
      const longest = {
        'seconds': 2147483647,
        'minutes': 153722867,
        'hours': 2562047,
        'days': 106751,
      };
      for (final MapEntry(key: unit, value: max) in longest.entries) {
        api = build((_) => reply(200, body: link))..token = 'a.b.c';
        // The longest lifetime still fits the server's 64-bit nanoseconds.
        final seconds = max *
            const {
              'seconds': 1,
              'minutes': 60,
              'hours': 3600,
              'days': 86400
            }[unit]!;
        expect(seconds, lessThanOrEqualTo(9223372036), reason: unit);
        await api.createShare('/f', expires: max, unit: unit);
        expect(sentBody()['expires'], '$max', reason: unit);
        if (unit == 'seconds') continue;
        await expectLater(api.createShare('/f', expires: max + 1, unit: unit),
            throwsArgumentError,
            reason: unit);
        expect(adapter.requests, hasLength(1), reason: unit);
      }
    });

    test('a folder is addressed with a trailing slash, as the web UI does',
        () async {
      api = build((o) => reply(200, body: o.method == 'GET' ? [link] : link))
        ..token = 'a.b.c';
      await api.sharesFor('/a dir/sub', isDir: true);
      await api.createShare('/a dir/sub/', isDir: true);
      await api.sharesFor('/', isDir: true);
      expect(adapter.requests.map((r) => '${r.method} ${r.uri}'), [
        'GET http://fb.local/base/api/share/a%20dir/sub/',
        'POST http://fb.local/base/api/share/a%20dir/sub/',
        'GET http://fb.local/base/api/share/',
      ]);
    });

    test('a file is addressed without a trailing slash', () async {
      api = build((o) => reply(200, body: o.method == 'GET' ? [link] : link))
        ..token = 'a.b.c';
      await api.sharesFor('/a dir/f/');
      await api.createShare('/a dir/f/');
      expect(adapter.requests.map((r) => r.uri.toString()).toSet(),
          {'http://fb.local/base/api/share/a%20dir/f'});
    });

    test('createShare reports a missing share permission', () async {
      api = build((_) => reply(403))..token = 'a.b.c';
      expect(
          () => api.createShare('/f'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)));
    });

    test('createShare reports a server error', () async {
      api = build((_) => reply(500, body: 'boom'))..token = 'a.b.c';
      expect(
          () => api.createShare('/f'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)));
    });

    test('sharesFor lists the links of one path', () async {
      api = build((_) => reply(200, body: [
            link,
            {...link, 'hash': 'h2', 'hasPassword': true}
          ]))
        ..token = 'a.b.c';
      final links = await api.sharesFor('/a dir/f');
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.uri.toString(),
          'http://fb.local/base/api/share/a%20dir/f');
      expect(links.map((l) => (l.hash, l.hasPassword)),
          [('h1', false), ('h2', true)]);
    });

    test('sharesFor of the root folder', () async {
      api = build((_) => reply(200, body: []))..token = 'a.b.c';
      expect(await api.sharesFor('/'), isEmpty);
      expect(adapter.requests.single.uri.toString(),
          'http://fb.local/base/api/share/');
    });

    test('shares lists every link of the account', () async {
      api = build((_) => reply(200, body: [link]))..token = 'a.b.c';
      expect((await api.shares()).single.path, '/f');
      expect(adapter.requests.single.uri.toString(),
          'http://fb.local/base/api/shares');
    });

    test('deleteShare addresses the link by its hash', () async {
      api = build((_) => reply(200))..token = 'a.b.c';
      await api.deleteShare('a-b_c');
      expect(adapter.requests.single.method, 'DELETE');
      expect(adapter.requests.single.uri.toString(),
          'http://fb.local/base/api/share/a-b_c');
    });

    test('deleteShare reports a link that is already gone', () async {
      api = build((_) => reply(404))..token = 'a.b.c';
      expect(
          () => api.deleteShare('h1'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)));
    });

    test('usernames maps account ids to names', () async {
      api = build((_) => reply(200, body: [
            {'id': 1, 'username': 'admin'},
            {'id': 7, 'username': 'bob'}
          ]))
        ..token = 'a.b.c';
      expect(await api.usernames(), {1: 'admin', 7: 'bob'});
      expect(adapter.requests.single.uri.toString(),
          'http://fb.local/base/api/users');
    });

    test('usernames leaves out entries without an id or a name', () async {
      api = build((_) => reply(200, body: [
            {'username': 'no-id'},
            {'id': 0, 'username': 'zero'},
            {'id': 3, 'username': ''},
            {'id': 4},
            {'id': 7, 'username': 'bob'}
          ]))
        ..token = 'a.b.c';
      expect(await api.usernames(), {7: 'bob'});
    });

    test('usernames reports that only administrators may list users', () async {
      api = build((_) => reply(403))..token = 'a.b.c';
      expect(
          () => api.usernames(),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)));
    });

    test('links point at the configured address, base path included', () {
      final share = ShareLink.fromJson(link);
      api = build((_) => reply(200));
      expect(api.shareUrl(share), 'http://fb.local/base/share/h1');
      expect(api.shareDownloadUrl(share),
          'http://fb.local/base/api/public/dl/h1?inline=true');
    });

    test('links for an address entered with several trailing slashes', () {
      final share = ShareLink.fromJson(link);
      final slashes = FileBrowserApi(baseUrl: 'http://fb.local/base///');
      expect(slashes.shareUrl(share), 'http://fb.local/base/share/h1');
      expect(slashes.shareDownloadUrl(share),
          'http://fb.local/base/api/public/dl/h1?inline=true');
    });

    test('links for a server without a base path', () {
      final share = ShareLink.fromJson(link);
      final plain = FileBrowserApi(baseUrl: 'files.example.com:8443/');
      expect(plain.shareUrl(share), 'https://files.example.com:8443/share/h1');
      expect(plain.shareDownloadUrl(share),
          'https://files.example.com:8443/api/public/dl/h1?inline=true');
    });
  });

  test('preview and raw URLs', () {
    api = build((_) => reply(200));
    expect(api.rawUrl('/a dir', archive: 'zip'),
        'http://fb.local/base/api/raw/a%20dir?algo=zip');
    expect(
        api.previewUrl('/p.png', 'thumb',
            modified: DateTime.fromMillisecondsSinceEpoch(5)),
        'http://fb.local/base/api/preview/thumb/p.png?inline=true&key=5');
  });
}
