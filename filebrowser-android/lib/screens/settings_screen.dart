import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../providers/files_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/session_provider.dart';
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
        const Divider(),
        if (session != null)
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () async {
              if (await confirm(context,
                  title: 'Log out?',
                  message: 'The saved password is removed from this device.',
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
