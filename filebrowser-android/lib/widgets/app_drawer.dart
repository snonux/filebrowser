import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_routes.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../utils/format.dart';

final _usageProvider = FutureProvider.autoDispose<DiskUsage>(
    (ref) => ref.watch(requireSessionProvider.select((s) => s.api)).usage('/'));

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key, required this.currentPath});

  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(requireSessionProvider);
    final usage = ref.watch(_usageProvider);
    void go(String route) {
      Navigator.pop(context);
      context.push(route);
    }

    return NavigationDrawer(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 16, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(session.user.username,
                style: Theme.of(context).textTheme.titleLarge),
            Text(Uri.parse(session.api.baseUrl).host,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('Home'),
          onTap: () {
            Navigator.pop(context);
            context.go(AppRoutes.files('/'));
          },
        ),
        if (session.perm.share)
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Share links'),
            onTap: () => go(AppRoutes.shares),
          ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () => go(AppRoutes.settings),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
          child: usage.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, __) => const Text('Disk usage unavailable'),
            data: (u) =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(
                  value: u.total == 0 ? 0 : u.used / u.total),
              const SizedBox(height: 6),
              Text('${formatSize(u.used)} of ${formatSize(u.total)} used'),
            ]),
          ),
        ),
      ],
    );
  }
}
