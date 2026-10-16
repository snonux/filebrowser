import 'dart:convert';
import 'dart:io';

import 'package:filebrowser_android/providers/fingerprint_provider.dart';
import 'package:filebrowser_android/providers/preferences_provider.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/services/biometric_login.dart';
import 'package:filebrowser_android/services/credential_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String token(String username) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({
          'exp': 4102444800,
          'user': {'id': 1, 'username': username, 'perm': {}},
        })))}.signature';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late String url;
  late ProviderContainer container;
  late MemoryCredentialStore store;
  late MemoryBiometricVault vault;
  var password = 'secret';

  FingerprintLogin fingerprint() => container.read(fingerprintLoginProvider);
  Preferences prefs() => container.read(preferencesProvider);
  BiometricLogin alice([String pw = 'secret']) =>
      BiometricLogin(serverUrl: url, username: 'alice', password: pw);

  final originalHttpOverrides = HttpOverrides.current;
  setUp(() async {
    // Talk to the local server instead of the test binding's fake HTTP.
    HttpOverrides.global = null;
    password = 'secret';
    SharedPreferences.setMockInitialValues({});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final ok = data['password'] == password;
      request.response.statusCode = ok ? 200 : 403;
      request.response.write(ok ? token(data['username'] as String) : '');
      await request.response.close();
    });
    store = MemoryCredentialStore();
    vault = MemoryBiometricVault();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider
          .overrideWithValue(await SharedPreferences.getInstance()),
      credentialStoreProvider.overrideWithValue(store),
      biometricVaultProvider.overrideWithValue(vault),
    ]);
    await container.read(sessionProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await server.close(force: true);
    HttpOverrides.global = originalHttpOverrides;
  });

  test('offers fingerprint sign-in until it is turned on or declined',
      () async {
    expect(await fingerprint().shouldOffer(alice()), isTrue);
    await fingerprint().enable(alice());
    expect(vault.stored?.password, 'secret');
    expect(prefs().fingerprintAccount, 'alice@$url');
    expect(await fingerprint().shouldOffer(alice()), isFalse);

    final bob = BiometricLogin(serverUrl: url, username: 'bob', password: 'x');
    expect(await fingerprint().shouldOffer(bob), isTrue);
    await fingerprint().decline(bob);
    expect(await fingerprint().shouldOffer(bob), isFalse);
  });

  test('is not offered without an enrolled fingerprint', () async {
    vault.available = false;
    container.invalidate(fingerprintAvailableProvider);
    expect(await fingerprint().shouldOffer(alice()), isFalse);
  });

  test('a dismissed prompt leaves fingerprint sign-in off', () async {
    vault.error = const BiometricCanceled();
    await expectLater(
        fingerprint().enable(alice()), throwsA(isA<BiometricCanceled>()));
    expect(prefs().fingerprintAccount, isEmpty);
  });

  test('signs in after logout without keeping the password', () async {
    await fingerprint().enable(alice());
    expect(await fingerprint().signIn(stayLoggedIn: false), isTrue);
    final session = container.read(sessionProvider).valueOrNull;
    expect(session?.user.username, 'alice');
    expect(session?.api.baseUrl, url);
    expect((await store.read()).password, isNull);
    expect(vault.prompts, 2);

    await container.read(sessionProvider.notifier).logout();
    expect(container.read(sessionProvider).valueOrNull, isNull);
    // Logging out keeps fingerprint sign-in.
    expect(prefs().fingerprintAccount, 'alice@$url');
    expect(await fingerprint().signIn(stayLoggedIn: false), isTrue);
    expect(container.read(sessionProvider).valueOrNull?.user.username, 'alice');
  });

  test('a dismissed prompt does not sign in or turn it off', () async {
    await fingerprint().enable(alice());
    vault.error = const BiometricCanceled();
    expect(await fingerprint().signIn(stayLoggedIn: false), isFalse);
    expect(container.read(sessionProvider).valueOrNull, isNull);
    expect(prefs().fingerprintAccount, isNotEmpty);
  });

  test('a changed password turns fingerprint sign-in off', () async {
    await fingerprint().enable(alice());
    password = 'changed';
    await expectLater(fingerprint().signIn(stayLoggedIn: false),
        throwsA(isA<FingerprintLoginFailed>()));
    expect(container.read(sessionProvider).valueOrNull, isNull);
    expect(vault.stored, isNull);
    expect(prefs().fingerprintAccount, isEmpty);
  });

  test('new fingerprints on the device turn fingerprint sign-in off', () async {
    await fingerprint().enable(alice());
    vault.error = const BiometricUnavailable('Key permanently invalidated');
    await expectLater(fingerprint().signIn(stayLoggedIn: false),
        throwsA(isA<FingerprintLoginFailed>()));
    expect(prefs().fingerprintAccount, isEmpty);
  });

  test('the stored sign-in round-trips through JSON', () {
    const login = BiometricLogin(
        serverUrl: 'https://fb',
        username: 'u',
        password: 'p',
        proxyUsername: 'pu',
        proxyPassword: 'pp');
    final back = BiometricLogin.fromJson(
        jsonDecode(jsonEncode(login.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), login.toJson());
  });
}
