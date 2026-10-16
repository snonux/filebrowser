import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in `main` with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
    (ref) => throw UnimplementedError('sharedPreferencesProvider not set'));

enum SortField { name, size, modified }

/// Non-secret settings kept between launches.
class Preferences {
  const Preferences({
    this.serverUrl = '',
    this.username = '',
    this.proxyUsername = '',
    this.themeMode = ThemeMode.system,
    this.sortField = SortField.name,
    this.sortAscending = true,
    this.showHidden,
    this.shareFolder = '/',
    this.fingerprintAccount = '',
    this.fingerprintDeclined = '',
  });

  final String serverUrl;
  final String username;

  /// Basic-auth user for a reverse proxy; empty when none is used.
  final String proxyUsername;
  final ThemeMode themeMode;
  final SortField sortField;
  final bool sortAscending;

  /// Null until the user changes it; then the account's own setting no longer
  /// applies.
  final bool? showHidden;

  /// Folder that shares from other apps were last uploaded to.
  final String shareFolder;

  /// The account (`user@server`) whose sign-in is kept behind the
  /// fingerprint; empty when fingerprint sign-in is off.
  final String fingerprintAccount;

  /// The account for which the user said "Not now" to fingerprint sign-in,
  /// so the app doesn't ask again after every password sign-in.
  final String fingerprintDeclined;
}

class PreferencesNotifier extends Notifier<Preferences> {
  late SharedPreferences _prefs;

  @override
  Preferences build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return Preferences(
      serverUrl: _prefs.getString('serverUrl') ?? '',
      username: _prefs.getString('username') ?? '',
      proxyUsername: _prefs.getString('proxyUsername') ?? '',
      themeMode: ThemeMode.values
          .byName(_prefs.getString('themeMode') ?? ThemeMode.system.name),
      sortField:
          SortField.values.byName(_prefs.getString('sortField') ?? 'name'),
      sortAscending: _prefs.getBool('sortAscending') ?? true,
      showHidden: _prefs.getBool('showHidden'),
      shareFolder: _prefs.getString('shareFolder') ?? '/',
      fingerprintAccount: _prefs.getString('fingerprintAccount') ?? '',
      fingerprintDeclined: _prefs.getString('fingerprintDeclined') ?? '',
    );
  }

  Future<void> setServer(
      {required String serverUrl,
      required String username,
      required String proxyUsername}) async {
    await _prefs.setString('serverUrl', serverUrl);
    await _prefs.setString('username', username);
    await _prefs.setString('proxyUsername', proxyUsername);
    ref.invalidateSelf();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString('themeMode', mode.name);
    ref.invalidateSelf();
  }

  Future<void> setSort(SortField field, bool ascending) async {
    await _prefs.setString('sortField', field.name);
    await _prefs.setBool('sortAscending', ascending);
    ref.invalidateSelf();
  }

  Future<void> setShowHidden(bool show) async {
    await _prefs.setBool('showHidden', show);
    ref.invalidateSelf();
  }

  Future<void> setShareFolder(String folder) async {
    await _prefs.setString('shareFolder', folder);
    ref.invalidateSelf();
  }

  Future<void> setFingerprintAccount(String account) async {
    await _prefs.setString('fingerprintAccount', account);
    ref.invalidateSelf();
  }

  Future<void> setFingerprintDeclined(String account) async {
    await _prefs.setString('fingerprintDeclined', account);
    ref.invalidateSelf();
  }
}

final preferencesProvider =
    NotifierProvider<PreferencesNotifier, Preferences>(PreferencesNotifier.new);
