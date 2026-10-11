import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/providers/preferences_provider.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/services/credential_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String token(String username) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({
          'exp': 4102444800,
          'user': {'id': 1, 'username': username, 'perm': {}},
        })))}.signature';

class HeldTokenStore extends MemoryCredentialStore {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> writeToken(String token) async {
    started.complete();
    await release.future;
    await super.writeToken(token);
  }
}

class HeldPreferencesNotifier extends PreferencesNotifier {
  HeldPreferencesNotifier({this.beforeUpdate = false});

  final bool beforeUpdate;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setServer(
      {required String serverUrl,
      required String username,
      required String proxyUsername}) async {
    if (username == 'bob' && beforeUpdate) {
      started.complete();
      await release.future;
    }
    await super.setServer(
        serverUrl: serverUrl, username: username, proxyUsername: proxyUsername);
    if (username == 'bob' && !beforeUpdate) {
      started.complete();
      await release.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late ProviderContainer container;
  late MemoryCredentialStore store;
  late SessionController controller;
  late String url;
  late Completer<HttpRequest> heldRenew;
  late Completer<HttpRequest> heldLogin;
  var holdLogin = false, rejectResources = false, rejectLogin = false;
  var resources = 0, logins = 0;
  final clients = <FileBrowserApi>[];

  Future<void> answer(HttpRequest request, String body,
      {int status = 200}) async {
    request.response.statusCode = status;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> initialize(
      {MemoryCredentialStore? credentials,
      PreferencesNotifier? preferences}) async {
    store = credentials ?? MemoryCredentialStore();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider
          .overrideWithValue(await SharedPreferences.getInstance()),
      credentialStoreProvider.overrideWithValue(store),
      if (preferences != null)
        preferencesProvider.overrideWith(() => preferences),
    ]);
    await container.read(sessionProvider.future);
    controller = container.read(sessionProvider.notifier);
  }

  Future<FileBrowserApi> login(String username, {bool remember = true}) async {
    await controller.login(
        serverUrl: url,
        username: username,
        password: 'pw-$username',
        stayLoggedIn: remember,
        proxyUsername: 'proxy',
        proxyPassword: 'proxy-pw');
    final api = container.read(sessionProvider).requireValue!.api;
    clients.add(api);
    return api;
  }

  Future<void> expectAccount(String? username) async {
    expect(
        container.read(sessionProvider).valueOrNull?.user.username, username);
    final credentials = await store.read();
    expect(credentials.token, username == null ? null : token(username));
    expect(credentials.password, username == null ? null : 'pw-$username');
    expect(credentials.proxyPassword, 'proxy-pw');
    container.invalidate(sessionProvider);
    final restored = await container.read(sessionProvider.future);
    expect(restored?.user.username, username);
    if (restored != null) clients.add(restored.api);
  }

  final originalHttpOverrides = HttpOverrides.current;
  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    heldRenew = Completer<HttpRequest>();
    heldLogin = Completer<HttpRequest>();
    holdLogin = rejectResources = rejectLogin = false;
    resources = logins = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      switch (request.uri.path) {
        case '/api/login':
          logins++;
          final data =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (holdLogin) {
            heldLogin.complete(request);
          } else {
            await answer(request, token(data['username'] as String),
                status: rejectLogin ? 403 : 200);
          }
        case '/api/renew':
          heldRenew.complete(request);
        default:
          resources++;
          if (rejectResources) {
            await answer(request, '', status: 401);
          } else {
            request.response.headers.set('X-Renew-Token', 'true');
            request.response.headers.contentType = ContentType.json;
            await answer(
                request, jsonEncode({'path': '/', 'isDir': true, 'items': []}));
          }
      }
    });
    await initialize();
  });
  tearDown(() async {
    container.dispose();
    for (final api in clients) {
      api.dio.close(force: true);
    }
    clients.clear();
    await server.close(force: true);
    HttpOverrides.global = originalHttpOverrides;
  });

  for (final switchAccount in [false, true]) {
    final action = switchAccount ? 'account switch' : 'logout';
    test('delayed background renewal is discarded after $action', () async {
      final oldApi = await login('alice');
      await oldApi.fetch('/');
      final request = await heldRenew.future;
      final renewing = oldApi.renew();
      if (switchAccount) {
        await login('bob');
      } else {
        await controller.logout();
      }
      await answer(request, token('obsolete'));
      await renewing;
      await expectAccount(switchAccount ? 'bob' : null);
    });
    test('delayed reauthentication is discarded after $action', () async {
      final oldApi = await login('alice');
      rejectResources = holdLogin = true;
      final failure = expectLater(
          oldApi.fetch('/'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)));
      final request = await heldLogin.future;
      holdLogin = false;
      if (switchAccount) {
        await login('bob');
      } else {
        await controller.logout();
      }
      await answer(request, token('obsolete'));
      await failure;
      expect(resources, 1, reason: 'An ended session must not retry');
      await expectAccount(switchAccount ? 'bob' : null);
    });
    test('credential write underway cannot win over $action', () async {
      container.dispose();
      final heldStore = HeldTokenStore();
      await initialize(credentials: heldStore);
      final oldApi = await login('alice');
      final renewing = oldApi.renew();
      await answer(await heldRenew.future, token('obsolete'));
      await heldStore.started.future;
      final replacing = switchAccount ? login('bob') : controller.logout();
      heldStore.release.complete();
      await renewing;
      await replacing;
      await expectAccount(switchAccount ? 'bob' : null);
    });
    test('old API cannot reauthenticate after $action', () async {
      final oldApi = await login('alice');
      if (switchAccount) {
        await login('bob');
      } else {
        await controller.logout();
      }
      final count = logins;
      rejectResources = true;
      await expectLater(oldApi.fetch('/'), throwsA(isA<ApiException>()));
      expect(logins, count);
      await expectAccount(switchAccount ? 'bob' : null);
    });
  }
  test('provider rebuild rejects a renewal from its previous session',
      () async {
    final oldApi = await login('alice');
    final renewing = oldApi.renew();
    final request = await heldRenew.future;
    container.invalidate(sessionProvider);
    final restored = await container.read(sessionProvider.future);
    clients.add(restored!.api);
    await answer(request, token('obsolete'));
    await renewing;
    await expectAccount('alice');
  });

  test('disposed provider rejects delayed reauthentication', () async {
    final oldApi = await login('alice');
    rejectResources = holdLogin = true;
    final failure =
        expectLater(oldApi.fetch('/'), throwsA(isA<ApiException>()));
    final request = await heldLogin.future;
    container.dispose();
    await answer(request, token('obsolete'));
    await failure;
    expect(resources, 1);
    expect((await store.read()).token, token('alice'));
    // Recreate the provider with the same persisted settings and credentials.
    await initialize(credentials: store);
    await expectAccount('alice');
  });

  test('rebuild waits for a held credential write and queued logout', () async {
    container.dispose();
    final heldStore = HeldTokenStore();
    await initialize(credentials: heldStore);
    final api = await login('alice');
    final renewing = api.renew();
    await answer(await heldRenew.future, token('obsolete'));
    await heldStore.started.future;
    final loggingOut = controller.logout();
    container.invalidate(sessionProvider);
    final restoring = container.read(sessionProvider.future);
    heldStore.release.complete();
    await renewing;
    await loggingOut;
    expect(await restoring, isNull);
    await expectAccount(null);
  });

  for (final beforeUpdate in [true, false]) {
    final phase = beforeUpdate ? 'before' : 'after';
    test('rebuild $phase preference update restores the whole account',
        () async {
      container.dispose();
      final preferences = HeldPreferencesNotifier(beforeUpdate: beforeUpdate);
      await initialize(preferences: preferences);
      await login('alice');
      final bobServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => bobServer.close(force: true));
      final bobUrl = 'http://${bobServer.address.address}:${bobServer.port}';
      final loginBodies = <Map<String, dynamic>>[];
      final proxyHeaders = <String?>[];
      final resourceTokens = <String?>[];
      bobServer.listen((request) async {
        proxyHeaders.add(request.headers.value('Authorization'));
        if (request.uri.path == '/api/login') {
          loginBodies.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          await answer(request, token('bob'));
        } else {
          resourceTokens.add(request.headers.value('X-Auth'));
          if (resourceTokens.length == 1) {
            await answer(request, '', status: 401);
          } else {
            request.response.headers.contentType = ContentType.json;
            await answer(
                request, jsonEncode({'path': '/', 'isDir': true, 'items': []}));
          }
        }
      });
      final loggingIn = controller.login(
          serverUrl: bobUrl,
          username: 'bob',
          password: 'pw-bob',
          stayLoggedIn: true,
          proxyUsername: 'bob-proxy',
          proxyPassword: 'bob-proxy-pw');
      await preferences.started.future;
      container.invalidate(sessionProvider);
      final restoring = container.read(sessionProvider.future);
      preferences.release.complete();
      await loggingIn;
      final restored = (await restoring)!;
      clients.add(restored.api);
      expect(restored.user.username, 'bob');
      expect(restored.api.baseUrl, bobUrl);
      expect(restored.api.basicAuth?.username, 'bob-proxy');
      expect(restored.api.basicAuth?.password, 'bob-proxy-pw');
      final oldServerLogins = logins;
      final oldServerResources = resources;
      await restored.api.fetch('/');
      expect(loginBodies, hasLength(2),
          reason: 'Login then 401 reauthentication');
      for (final body in loginBodies) {
        expect(body['username'], 'bob');
        expect(body['password'], 'pw-bob');
      }
      expect(proxyHeaders, hasLength(4));
      expect(proxyHeaders,
          everyElement(const BasicAuth('bob-proxy', 'bob-proxy-pw').header));
      expect(resourceTokens, [token('bob'), token('bob')]);
      expect(logins, oldServerLogins, reason: 'Never send Bob login to Alice');
      expect(resources, oldServerResources,
          reason: 'Never send Bob token to Alice');
      final credentials = await store.read();
      expect(credentials.token, token('bob'));
      expect(credentials.password, 'pw-bob');
      expect(credentials.proxyPassword, 'bob-proxy-pw');
      expect(container.read(sessionProvider).requireValue!.api, restored.api);
    });
  }

  test('normal login and renewal update state and remembered credentials',
      () async {
    final api = await login('alice');
    final renewing = api.renew();
    await answer(await heldRenew.future, token('renewed'));
    await renewing;
    expect(
        container.read(sessionProvider).requireValue!.user.username, 'renewed');
    expect((await store.read()).token, token('renewed'));
    expect((await store.read()).password, 'pw-alice');
  });
  test('normal reauthentication retries with the remembered password',
      () async {
    final api = await login('alice');
    rejectResources = holdLogin = true;
    final fetching = api.fetch('/');
    final request = await heldLogin.future;
    rejectResources = false;
    await answer(request, token('alice'));
    await fetching;
    expect(logins, 2);
    expect(resources, 2);
    await answer(await heldRenew.future, token('alice'));
    await api.renew();
    await expectAccount('alice');
  });
  test('unauthorized without remembered password ends the session', () async {
    final api = await login('alice', remember: false);
    rejectResources = true;
    await expectLater(api.fetch('/'), throwsA(isA<ApiException>()));
    expect(logins, 1);
    await expectAccount(null);
  });
  test('failed reauthentication ends the current session', () async {
    final api = await login('alice');
    rejectResources = rejectLogin = true;
    await expectLater(api.fetch('/'), throwsA(isA<ApiException>()));
    await expectAccount(null);
  });
  test('failed account login leaves the existing session renewable', () async {
    final api = await login('alice');
    rejectLogin = true;
    await expectLater(
        controller.login(
            serverUrl: url,
            username: 'bob',
            password: 'wrong',
            stayLoggedIn: true),
        throwsA(isA<ApiException>()));
    final renewing = api.renew();
    await answer(await heldRenew.future, token('alice'));
    await renewing;
    await expectAccount('alice');
  });

  test('login response arriving after logout cannot restore a session',
      () async {
    await login('alice');
    holdLogin = true;
    final loggingIn = controller.login(
        serverUrl: url,
        username: 'bob',
        password: 'pw-bob',
        stayLoggedIn: true);
    final request = await heldLogin.future;
    await controller.logout();
    await answer(request, token('bob'));
    await loggingIn;
    await expectAccount(null);
    expect(container.read(preferencesProvider).username, 'alice');
  });
}
