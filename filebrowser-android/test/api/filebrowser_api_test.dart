import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
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

  test('createShare sends expiry as a string', () async {
    api = build((_) => reply(200,
        body: {'hash': 'h1', 'path': '/f', 'expire': 0, 'hasPassword': false}))
      ..token = 'a.b.c';
    final share = await api.createShare('/f', expires: 3, unit: 'days');
    expect(adapter.requests.single.data, contains('"expires":"3"'));
    expect(api.shareUrl(share), 'http://fb.local/base/share/h1');
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
