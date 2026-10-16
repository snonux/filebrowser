import 'dart:convert';

import 'package:biometric_storage/biometric_storage.dart';

/// What fingerprint sign-in needs to log in again without typing.
class BiometricLogin {
  const BiometricLogin({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.proxyUsername = '',
    this.proxyPassword = '',
  });

  final String serverUrl;
  final String username;
  final String password;
  final String proxyUsername;
  final String proxyPassword;

  Map<String, String> toJson() => {
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
        'proxyUsername': proxyUsername,
        'proxyPassword': proxyPassword,
      };

  static BiometricLogin fromJson(Map<String, dynamic> json) => BiometricLogin(
        serverUrl: json['serverUrl'] as String,
        username: json['username'] as String,
        password: json['password'] as String,
        proxyUsername: json['proxyUsername'] as String? ?? '',
        proxyPassword: json['proxyPassword'] as String? ?? '',
      );
}

/// The fingerprint prompt was dismissed; nothing is wrong.
class BiometricCanceled implements Exception {
  const BiometricCanceled();
}

/// The stored sign-in can no longer be unlocked, for example because a new
/// fingerprint was enrolled, which invalidates the keystore key.
class BiometricUnavailable implements Exception {
  const BiometricUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Keeps one sign-in behind the device's biometric lock.
abstract interface class BiometricVault {
  /// Whether the device has a fingerprint (or other strong biometric)
  /// enrolled and usable.
  Future<bool> isAvailable();

  /// Stores [login]; asks for a fingerprint to encrypt it.
  ///
  /// Throws [BiometricCanceled] when the prompt is dismissed.
  Future<void> save(BiometricLogin login);

  /// Asks for a fingerprint and returns the stored sign-in, or null when none
  /// is stored.
  ///
  /// Throws [BiometricCanceled] or [BiometricUnavailable].
  Future<BiometricLogin?> unlock();

  Future<void> delete();
}

/// Production vault: an AES key in the Android keystore that can only be used
/// after a fresh biometric check (`setUserAuthenticationRequired`).
class KeystoreBiometricVault implements BiometricVault {
  static const _name = 'fingerprint_login';
  static const _prompt = PromptInfo(
    androidPromptInfo: AndroidPromptInfo(
      title: 'Sign in to File Browser',
      subtitle: 'Touch the fingerprint sensor',
      negativeButton: 'Use password',
      confirmationRequired: false,
    ),
  );

  final _plugin = BiometricStorage();

  Future<BiometricStorageFile> _file() => _plugin.getStorage(_name,
      options: StorageFileInitOptions(), promptInfo: _prompt);

  @override
  Future<bool> isAvailable() async =>
      await _plugin.canAuthenticate() == CanAuthenticateResponse.success;

  @override
  Future<void> save(BiometricLogin login) =>
      _guard(() async => (await _file()).write(jsonEncode(login.toJson())));

  @override
  Future<BiometricLogin?> unlock() => _guard(() async {
        final data = await (await _file()).read();
        if (data == null || data.isEmpty) return null;
        return BiometricLogin.fromJson(
            jsonDecode(data) as Map<String, dynamic>);
      });

  @override
  Future<void> delete() async {
    try {
      // Deleting needs no fingerprint.
      await (await _plugin.getStorage(_name,
              options: StorageFileInitOptions(), promptInfo: _prompt))
          .delete();
    } on Exception {
      // Nothing stored, or the key is already gone.
    }
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on AuthException catch (e) {
      if (e.code == AuthExceptionCode.userCanceled ||
          e.code == AuthExceptionCode.canceled ||
          e.code == AuthExceptionCode.timeout) {
        throw const BiometricCanceled();
      }
      throw BiometricUnavailable(e.message);
    } on BiometricStorageException catch (e) {
      throw BiometricUnavailable(e.message);
    } on FormatException catch (e) {
      throw BiometricUnavailable(e.message);
    } on Exception catch (e) {
      // The plugin reports an invalidated key as a PlatformException.
      throw BiometricUnavailable(e.toString());
    }
  }
}

/// In-memory vault for tests; [available] and [error] steer the prompt.
class MemoryBiometricVault implements BiometricVault {
  MemoryBiometricVault({this.available = true});

  bool available;

  /// Thrown by the next prompts instead of a successful fingerprint check.
  Exception? error;
  BiometricLogin? stored;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> save(BiometricLogin login) async {
    prompts++;
    if (error case final e?) throw e;
    stored = login;
  }

  @override
  Future<BiometricLogin?> unlock() async {
    prompts++;
    if (error case final e?) throw e;
    return stored;
  }

  @override
  Future<void> delete() async => stored = null;
}
