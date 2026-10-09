import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/filebrowser_api.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';

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
    try {
      await ref.read(sessionProvider.notifier).login(
            serverUrl: _server.text,
            username: _username.text.trim(),
            password: _password.text,
            stayLoggedIn: _stayLoggedIn,
            proxyUsername: _useProxy ? _proxyUser.text.trim() : '',
            proxyPassword: _useProxy ? _proxyPassword.text : '',
          );
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

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
