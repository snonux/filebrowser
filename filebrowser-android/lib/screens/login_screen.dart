import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../navigation_key.dart';
import '../providers/fingerprint_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
import '../services/biometric_login.dart';
import 'file_actions.dart' show showMessage;

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _server;
  late final TextEditingController _username;
  final _password = TextEditingController();
  late final TextEditingController _proxyUser;
  final _proxyPassword = TextEditingController();
  bool _stayLoggedIn = true;
  late bool _useProxy;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(preferencesProvider);
    _server = TextEditingController(text: prefs.serverUrl);
    _username = TextEditingController(text: prefs.username);
    _proxyUser = TextEditingController(text: prefs.proxyUsername);
    _useProxy = prefs.proxyUsername.isNotEmpty;
  }

  @override
  void dispose() {
    for (final c in [
      _server,
      _username,
      _password,
      _proxyUser,
      _proxyPassword
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final username = _username.text.trim();
    final password = _password.text;
    final proxyUsername = _useProxy ? _proxyUser.text.trim() : '';
    final proxyPassword = _useProxy ? _proxyPassword.text : '';
    // Read before signing in: the screen goes away once the session starts.
    final fingerprint = ref.read(fingerprintLoginProvider);
    try {
      await ref.read(sessionProvider.notifier).login(
            serverUrl: _server.text,
            username: username,
            password: password,
            stayLoggedIn: _stayLoggedIn,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
          );
      final login = BiometricLogin(
        // The address as the session stores it.
        serverUrl: FileBrowserApi.normalizeBaseUrl(_server.text),
        username: username,
        password: password,
        proxyUsername: proxyUsername,
        proxyPassword: proxyPassword,
      );
      if (await fingerprint.shouldOffer(login)) {
        await offerFingerprintLogin(fingerprint, login);
      }
    } on ApiException catch (e) {
      setState(() => _error = switch (e.statusCode) {
            403 => 'Wrong username or password',
            401 when _useProxy => 'The proxy rejected its username or password',
            401 => 'The server asks for a login in front of File Browser. '
                'Turn on "Proxy login" below.',
            _ => e.message,
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fingerprintSignIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(fingerprintLoginProvider)
          .signIn(stayLoggedIn: _stayLoggedIn);
    } on FingerprintLoginFailed catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fingerprintAccount =
        ref.watch(preferencesProvider.select((p) => p.fingerprintAccount));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.folder_open,
                          size: 64, color: theme.colorScheme.primary),
                      const SizedBox(height: 8),
                      Text('File Browser',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _server,
                        decoration: const InputDecoration(
                          labelText: 'Server address',
                          hintText: 'https://files.example.com',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        validator: _required,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _username,
                        decoration: const InputDecoration(
                            labelText: 'Username',
                            border: OutlineInputBorder()),
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        validator: _required,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        decoration: const InputDecoration(
                            labelText: 'Password',
                            border: OutlineInputBorder()),
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        validator: _required,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Stay signed in'),
                        subtitle: const Text(
                            'Keeps the password encrypted on this device to sign in again when the session expires'),
                        value: _stayLoggedIn,
                        onChanged: (v) => setState(() => _stayLoggedIn = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Proxy login'),
                        subtitle: const Text(
                            'For a reverse proxy that asks for a username and password (HTTP basic auth)'),
                        value: _useProxy,
                        onChanged: (v) => setState(() => _useProxy = v),
                      ),
                      if (_useProxy) ...[
                        TextFormField(
                          controller: _proxyUser,
                          decoration: const InputDecoration(
                              labelText: 'Proxy username',
                              border: OutlineInputBorder()),
                          autocorrect: false,
                          validator: _required,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _proxyPassword,
                          decoration: const InputDecoration(
                              labelText: 'Proxy password',
                              border: OutlineInputBorder()),
                          obscureText: true,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(_error!,
                              style: TextStyle(color: theme.colorScheme.error)),
                        ),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: _busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Sign in'),
                        ),
                      ),
                      if (fingerprintAccount.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _fingerprintSignIn,
                          icon: const Icon(Icons.fingerprint),
                          label: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('Sign in with fingerprint'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks whether to sign in with the fingerprint next time and, if so, stores
/// [login] behind it. Runs after the login screen has gone, on the app's
/// navigator.
Future<void> offerFingerprintLogin(
    FingerprintLogin fingerprint, BiometricLogin login) async {
  // Let the router swap the login screen for the files first, so the dialog
  // isn't removed together with the login page.
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;
  final context = appNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  final enable = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.fingerprint),
      title: const Text('Sign in with your fingerprint?'),
      content: const Text(
          'Next time, sign in to this server with your fingerprint instead of '
          'typing the password. The password is kept encrypted with a key '
          'that only your fingerprint unlocks. You can turn this off in '
          'Settings.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use fingerprint')),
      ],
    ),
  );
  if (enable == null) return;
  if (!enable) return fingerprint.decline(login);
  try {
    await fingerprint.enable(login);
    showMessage('Fingerprint sign-in is on');
  } on BiometricCanceled {
    // Dismissed the prompt; the user can turn it on later in Settings.
  } on BiometricUnavailable catch (e) {
    showMessage('Fingerprint sign-in could not be turned on: ${e.message}');
  }
}
