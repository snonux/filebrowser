import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets the app keeps between launches.
class StoredCredentials {
  const StoredCredentials({
    this.token,
    this.password,
    this.proxyPassword,
  });

  /// The last JWT the server issued.
  final String? token;

  /// The account password, only kept when the user chose "Stay signed in", so
  /// the app can log in again after the short-lived token expires.
  final String? password;

  /// Password for a basic-auth reverse proxy in front of the server.
  final String? proxyPassword;
}

/// Abstraction over secret storage so tests can run without platform code.
abstract interface class CredentialStore {
  Future<StoredCredentials> read();
  Future<void> write(StoredCredentials credentials);
  Future<void> writeToken(String token);
  Future<void> clear();
}

/// Production store backed by Android's keystore-encrypted storage.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  static const _token = 'token';
  static const _password = 'password';
  static const _proxyPassword = 'proxy_password';

  final FlutterSecureStorage _storage;

  @override
  Future<StoredCredentials> read() async => StoredCredentials(
        token: await _storage.read(key: _token),
        password: await _storage.read(key: _password),
        proxyPassword: await _storage.read(key: _proxyPassword),
      );

  @override
  Future<void> write(StoredCredentials c) async {
    await _put(_token, c.token);
    await _put(_password, c.password);
    await _put(_proxyPassword, c.proxyPassword);
  }

  @override
  Future<void> writeToken(String token) => _put(_token, token);

  @override
  Future<void> clear() async {
    await _storage.delete(key: _token);
    await _storage.delete(key: _password);
    await _storage.delete(key: _proxyPassword);
  }

  Future<void> _put(String key, String? value) => value == null
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);
}

/// In-memory store for tests.
class MemoryCredentialStore implements CredentialStore {
  StoredCredentials _value = const StoredCredentials();

  @override
  Future<StoredCredentials> read() async => _value;

  @override
  Future<void> write(StoredCredentials credentials) async =>
      _value = credentials;

  @override
  Future<void> writeToken(String token) async => _value = StoredCredentials(
      token: token,
      password: _value.password,
      proxyPassword: _value.proxyPassword);

  @override
  Future<void> clear() async => _value = const StoredCredentials();
}
