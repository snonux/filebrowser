import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../models/models.dart';
import '../services/credential_store.dart';
import 'preferences_provider.dart';

/// Overridden in tests with [MemoryCredentialStore].
final credentialStoreProvider =
    Provider<CredentialStore>((ref) => SecureCredentialStore());

/// A signed-in account on one server.
class Session {
  const Session({required this.api, required this.user});

  final FileBrowserApi api;
  final UserInfo user;

  Permissions get perm => user.perm;
}

/// Restores, creates and ends the session.
///
/// File Browser tokens are short-lived (2 hours by default) and cannot be
/// refreshed once expired. With "Stay signed in" the password is kept in
/// secure storage and the app logs in again on a 401; without it, the user is
/// sent back to the login screen.
class SessionController extends AsyncNotifier<Session?> {
  CredentialStore get _store => ref.read(credentialStoreProvider);

  /// The most recent signed-in session, kept after a logout.
  Session? lastSession;

  @override
  set state(AsyncValue<Session?> value) {
    final session = value.valueOrNull;
    if (session != null) lastSession = session;
    super.state = value;
  }

  @override
  Future<Session?> build() async {
    final prefs = ref.read(preferencesProvider);
    if (prefs.serverUrl.isEmpty || prefs.username.isEmpty) return null;
    final creds = await _store.read();
    final token = creds.token;
    if (token == null) return null;
    final TokenClaims claims;
    try {
      claims = TokenClaims.parse(token);
    } on FormatException {
      return null;
    }
    // An expired token is only useful when the password is remembered: the
    // first request then gets a 401 and logs in again.
    if (claims.isExpired && creds.password == null) return null;
    final api = _createApi(
      serverUrl: prefs.serverUrl,
      username: prefs.username,
      proxyUsername: prefs.proxyUsername,
      proxyPassword: creds.proxyPassword,
    )..token = token;
    return lastSession = Session(api: api, user: claims.user);
  }

  FileBrowserApi _createApi({
    required String serverUrl,
    required String username,
    required String proxyUsername,
    required String? proxyPassword,
  }) {
    late final FileBrowserApi api;
    api = FileBrowserApi(
      baseUrl: serverUrl,
      basicAuth: proxyUsername.isEmpty
          ? null
          : BasicAuth(proxyUsername, proxyPassword ?? ''),
      onTokenRenewed: (token) => _tokenChanged(api, token),
      reauthenticate: () => _reauthenticate(api, username),
    );
    return api;
  }

  void _tokenChanged(FileBrowserApi api, String token) {
    unawaited(_store.writeToken(token));
    final current = state.valueOrNull;
    if (current != null && identical(current.api, api)) {
      state = AsyncData(Session(api: api, user: TokenClaims.parse(token).user));
    }
  }

  Future<String?> _reauthenticate(FileBrowserApi api, String username) async {
    final password = (await _store.read()).password;
    if (password != null) {
      try {
        final token = await api.login(username, password);
        _tokenChanged(api, token);
        return token;
      } on ApiException catch (e) {
        // Keep the session when the server is just unreachable.
        if (e.statusCode == null) return null;
      }
    }
    if (identical(state.valueOrNull?.api, api)) await logout();
    return null;
  }

  /// Logs in and remembers the server. Throws [ApiException] on failure.
  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
    required bool stayLoggedIn,
    String proxyUsername = '',
    String proxyPassword = '',
  }) async {
    final api = _createApi(
      serverUrl: serverUrl,
      username: username,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
    );
    final token = await api.login(username, password);
    await ref.read(preferencesProvider.notifier).setServer(
          serverUrl: api.baseUrl,
          username: username,
          proxyUsername: proxyUsername,
        );
    await _store.write(StoredCredentials(
      token: token,
      password: stayLoggedIn ? password : null,
      proxyPassword: proxyUsername.isEmpty ? null : proxyPassword,
    ));
    state = AsyncData(Session(api: api, user: TokenClaims.parse(token).user));
  }

  /// Forgets the token and password; the server and username stay prefilled.
  Future<void> logout() async {
    final creds = await _store.read();
    await _store.write(StoredCredentials(proxyPassword: creds.proxyPassword));
    state = const AsyncData(null);
  }
}

final sessionProvider =
    AsyncNotifierProvider<SessionController, Session?>(SessionController.new);

/// The current session, for screens behind the login redirect.
///
/// After a logout the screens still on the stack rebuild once more before the
/// router replaces them with the login screen; they keep the last session for
/// that frame instead of failing.
final requireSessionProvider = Provider<Session>((ref) {
  final session = ref.watch(sessionProvider).valueOrNull ??
      ref.read(sessionProvider.notifier).lastSession;
  if (session == null) throw StateError('Not signed in');
  return session;
});
