import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../services/biometric_login.dart';
import 'preferences_provider.dart';
import 'session_provider.dart';

/// Overridden in tests with [MemoryBiometricVault].
final biometricVaultProvider =
    Provider<BiometricVault>((ref) => KeystoreBiometricVault());

/// Whether this device can use fingerprint sign-in at all.
final fingerprintAvailableProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.watch(biometricVaultProvider).isAvailable();
  } on Exception {
    return false;
  }
});

/// Names an account in the fingerprint preferences.
String accountLabel(String username, String serverUrl) =>
    '$username@$serverUrl';

/// Why a fingerprint sign-in did not go through. The fingerprint sign-in has
/// been turned off when this is thrown; the user signs in with the password.
class FingerprintLoginFailed implements Exception {
  const FingerprintLoginFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns fingerprint sign-in on and off and signs in with it.
///
/// The password (and proxy password) is encrypted with a keystore key that
/// only unlocks after a fingerprint check, so it is never readable without
/// the user's finger. Password sign-in always stays available.
class FingerprintLogin {
  FingerprintLogin(this.ref);

  final Ref ref;

  BiometricVault get _vault => ref.read(biometricVaultProvider);
  PreferencesNotifier get _prefs => ref.read(preferencesProvider.notifier);

  /// Whether to offer fingerprint sign-in after [login] signed in with a
  /// password.
  Future<bool> shouldOffer(BiometricLogin login) async {
    final prefs = ref.read(preferencesProvider);
    final account = accountLabel(login.username, login.serverUrl);
    if (prefs.fingerprintAccount == account ||
        prefs.fingerprintDeclined == account) {
      return false;
    }
    return ref.read(fingerprintAvailableProvider.future);
  }

  /// Stores [login] behind the fingerprint. Throws [BiometricCanceled] when
  /// the user dismisses the prompt.
  Future<void> enable(BiometricLogin login) async {
    await _vault.save(login);
    await _prefs
        .setFingerprintAccount(accountLabel(login.username, login.serverUrl));
  }

  Future<void> decline(BiometricLogin login) => _prefs
      .setFingerprintDeclined(accountLabel(login.username, login.serverUrl));

  Future<void> disable() async {
    await _vault.delete();
    await _prefs.setFingerprintAccount('');
  }

  /// Asks for the fingerprint and signs in with the stored password.
  ///
  /// Returns false when the user dismissed the prompt. Throws
  /// [FingerprintLoginFailed] when the stored sign-in no longer works, and
  /// [ApiException] when the server can't be reached.
  Future<bool> signIn({required bool stayLoggedIn}) async {
    final BiometricLogin? login;
    try {
      login = await _vault.unlock();
    } on BiometricCanceled {
      return false;
    } on BiometricUnavailable {
      await disable();
      throw const FingerprintLoginFailed(
          'Fingerprint sign-in was turned off because the fingerprints on '
          'this device changed. Sign in with your password to turn it on '
          'again.');
    }
    if (login == null) {
      await disable();
      throw const FingerprintLoginFailed(
          'No saved sign-in was found. Sign in with your password.');
    }
    try {
      await ref.read(sessionProvider.notifier).login(
            serverUrl: login.serverUrl,
            username: login.username,
            password: login.password,
            stayLoggedIn: stayLoggedIn,
            proxyUsername: login.proxyUsername,
            proxyPassword: login.proxyPassword,
          );
    } on ApiException catch (e) {
      if (e.statusCode == 403 || e.statusCode == 401) {
        await disable();
        throw const FingerprintLoginFailed(
            'The saved password no longer works, so fingerprint sign-in was '
            'turned off. Sign in with your password to turn it on again.');
      }
      rethrow;
    }
    return true;
  }
}

final fingerprintLoginProvider =
    Provider<FingerprintLogin>((ref) => FingerprintLogin(ref));
