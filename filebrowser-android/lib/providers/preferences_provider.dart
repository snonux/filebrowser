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
}

final preferencesProvider =
    NotifierProvider<PreferencesNotifier, Preferences>(PreferencesNotifier.new);
