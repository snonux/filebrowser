import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/filebrowser_api.dart';
import '../providers/files_provider.dart';
import '../providers/fingerprint_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
import '../services/biometric_login.dart';
import 'file_actions.dart';

final _versionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final prefs = ref.watch(preferencesProvider);
    final notifier = ref.read(preferencesProvider.notifier);
    final version = ref.watch(_versionProvider).valueOrNull ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        if (session != null)
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(session.user.username),
            subtitle: Text(session.api.baseUrl),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.visibility_outlined),
          title: const Text('Show hidden files'),
          subtitle: const Text('Names starting with a dot'),
          value: ref.watch(showHiddenProvider),
          onChanged: notifier.setShowHidden,
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Theme'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {prefs.themeMode},
              onSelectionChanged: (s) => notifier.setThemeMode(s.single),
            ),
          ),
        ),
        if (session != null &&
            (ref.watch(fingerprintAvailableProvider).valueOrNull ?? false))
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Sign in with fingerprint'),
            subtitle: const Text(
                'Unlocks the encrypted password with your fingerprint on the sign-in screen'),
            value: prefs.fingerprintAccount ==
                accountLabel(session.user.username, session.api.baseUrl),
            onChanged: (on) => on
                ? _enableFingerprint(context, ref, session)
                : ref.read(fingerprintLoginProvider).disable(),
          ),
        const Divider(),
        if (session != null)
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () async {
              if (await confirm(context,
                  title: 'Log out?',
                  message: prefs.fingerprintAccount.isEmpty
                      ? 'The saved password is removed from this device.'
                      : 'The saved password is removed from this device. '
                          'You can sign in again with your fingerprint.',
                  action: 'Log out')) {
                await ref.read(sessionProvider.notifier).logout();
              }
            },
          ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Version'),
          subtitle: Text(version),
        ),
      ]),
    );
  }
}

/// Asks for the password, checks it with the server and stores it behind the
/// fingerprint.
Future<void> _enableFingerprint(
    BuildContext context, WidgetRef ref, Session session) async {
  final fingerprint = ref.read(fingerprintLoginProvider);
  final password = await showDialog<String>(
    context: context,
    builder: (context) => const _PasswordDialog(),
  );
  if (password == null || password.isEmpty) return;
  final api = session.api;
  try {
    await FileBrowserApi(baseUrl: api.baseUrl, basicAuth: api.basicAuth)
        .login(session.user.username, password);
  } on ApiException catch (e) {
    showMessage(e.statusCode == 403 ? 'Wrong password' : e.message);
    return;
  }
  final auth = api.basicAuth;
  try {
    await fingerprint.enable(BiometricLogin(
      serverUrl: api.baseUrl,
      username: session.user.username,
      password: password,
      proxyUsername: auth?.username ?? '',
      proxyPassword: auth?.password ?? '',
    ));
    showMessage('Fingerprint sign-in is on');
  } on BiometricCanceled {
    // Dismissed the prompt.
  } on BiometricUnavailable catch (e) {
    showMessage('Fingerprint sign-in could not be turned on: ${e.message}');
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Sign in with fingerprint'),
        content: TextField(
          controller: _password,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'Password', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _password.text),
              child: const Text('Continue')),
        ],
      );
}
