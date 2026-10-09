import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'navigation_key.dart';
import 'providers/preferences_provider.dart';
import 'providers/session_provider.dart';
import 'router.dart';

// File Browser's brand blue.
const _seed = Color(0xFF2979FF);

final _lightTheme = ThemeData(colorSchemeSeed: _seed, useMaterial3: true);
final _darkTheme = ThemeData(
    colorSchemeSeed: _seed, brightness: Brightness.dark, useMaterial3: true);

class FileBrowserApp extends ConsumerWidget {
  const FileBrowserApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(preferencesProvider.select((p) => p.themeMode));
    final restoring = ref.watch(sessionProvider).isLoading;
    return MaterialApp.router(
      title: 'File Browser',
      scaffoldMessengerKey: appMessengerKey,
      routerConfig: router,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: themeMode,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : child!,
    );
  }
}
