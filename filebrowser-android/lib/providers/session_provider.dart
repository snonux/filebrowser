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

  int _generation = 0;
  int _loginAttempt = 0;
  Future<void> _storageOperations = Future.value();

  // Keep credential reads/writes and account preference changes in order.
  // A write already underway may finish after logout starts; logout must then
  // clear it before completing, rather than racing it in secure storage.
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _storageOperations.then((_) => operation());
    _storageOperations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  bool _isCurrent(FileBrowserApi api, int generation) =>
      generation == _generation && identical(state.valueOrNull?.api, api);

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
    final generation = ++_generation;
    ++_loginAttempt;
    ref.onDispose(() {
      ++_generation;
      ++_loginAttempt;
    });
    final store = _store;
    final snapshot = await _serialize(() async {
      // Read settings only after a queued account switch has finished writing
      // both stores. Check before using ref in case this build was disposed.
      if (generation != _generation) return null;
      final prefs = ref.read(preferencesProvider);
      final creds = await store.read();
      return (prefs, creds);
    });
    if (generation != _generation || snapshot == null) return null;
    final (prefs, creds) = snapshot;
    if (prefs.serverUrl.isEmpty || prefs.username.isEmpty) return null;
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
      generation: generation,
      serverUrl: prefs.serverUrl,
      username: prefs.username,
      proxyUsername: prefs.proxyUsername,
      proxyPassword: creds.proxyPassword,
    )..token = token;
    return lastSession = Session(api: api, user: claims.user);
  }

  FileBrowserApi _createApi({
    required int generation,
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
      onTokenRenewed: (token) => _tokenChanged(api, generation, token),
      reauthenticate: () => _reauthenticate(api, generation, username),
    );
    return api;
  }

  Future<bool> _tokenChanged(
      FileBrowserApi api, int generation, String token) async {
    if (!_isCurrent(api, generation)) return false;
    final user = TokenClaims.parse(token).user;
    final store = _store;
    return _serialize(() async {
      if (!_isCurrent(api, generation)) return false;
      await store.writeToken(token);
      if (!_isCurrent(api, generation)) return false;
      state = AsyncData(Session(api: api, user: user));
      return true;
    });
  }

  Future<String?> _reauthenticate(
      FileBrowserApi api, int generation, String username) async {
    if (!_isCurrent(api, generation)) return null;
    final store = _store;
    final password = (await _serialize(store.read)).password;
    if (!_isCurrent(api, generation)) return null;
    if (password != null) {
      try {
        final token = await api.login(username, password);
        return await _tokenChanged(api, generation, token) ? token : null;
      } on ApiException catch (e) {
        // Keep the session when the server is just unreachable.
        if (e.statusCode == null) return null;
      }
    }
    if (_isCurrent(api, generation)) await logout();
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
    final attempt = ++_loginAttempt;
    // A failed sign-in must leave an existing session usable. Invalidate that
    // session only after authentication succeeds, before persisting the switch.
    final generation = _generation + 1;
    final store = _store;
    final preferences = ref.read(preferencesProvider.notifier);
    final api = _createApi(
      generation: generation,
      serverUrl: serverUrl,
      username: username,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
    );
    final token = await api.login(username, password);
    if (attempt != _loginAttempt) return;
    final user = TokenClaims.parse(token).user;
    ++_generation;
    await _serialize(() async {
      if (generation != _generation) return;
      await preferences.setServer(
        serverUrl: api.baseUrl,
        username: username,
        proxyUsername: proxyUsername,
      );
      // Once preferences have started changing, finish the credential pair.
      // A queued logout/new login will clear or replace it, and a provider
      // rebuild waits for this operation before restoring either account.
      await store.write(StoredCredentials(
        token: token,
        password: stayLoggedIn ? password : null,
        proxyPassword: proxyUsername.isEmpty ? null : proxyPassword,
      ));
      if (generation != _generation) return;
      state = AsyncData(Session(api: api, user: user));
    });
  }

  /// Forgets the token and password; the server and username stay prefilled.
  Future<void> logout() async {
    ++_generation;
    ++_loginAttempt;
    final store = _store;
    state = const AsyncData(null);
    await _serialize(() async {
      final creds = await store.read();
      await store.write(StoredCredentials(proxyPassword: creds.proxyPassword));
    });
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
