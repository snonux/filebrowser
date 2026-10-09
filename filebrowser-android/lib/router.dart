import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_routes.dart';
import 'providers/session_provider.dart';
import 'screens/browser_screen.dart';
import 'screens/image_viewer_screen.dart';
import 'screens/login_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/shares_screen.dart';
import 'screens/text_editor_screen.dart';

export 'app_routes.dart' show AppRoutes;

/// Re-runs the router's redirect whenever the session changes.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionListenable(ref);
  ref.onDispose(refresh.dispose);

  String pathOf(GoRouterState state) =>
      state.uri.queryParameters['path'] ?? '/';

  return GoRouter(
    initialLocation: AppRoutes.files('/'),
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      if (session.isLoading) return null;
      final signedIn = session.valueOrNull != null;
      final atLogin = state.matchedLocation == AppRoutes.login;
      if (!signedIn) return atLogin ? null : AppRoutes.login;
      if (atLogin) return AppRoutes.files('/');
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.browse,
        builder: (context, state) => BrowserScreen(path: pathOf(state)),
      ),
      GoRoute(
        path: AppRoutes.editor,
        builder: (context, state) => TextEditorScreen(path: pathOf(state)),
      ),
      GoRoute(
        path: AppRoutes.viewer,
        builder: (context, state) => ImageViewerScreen(path: pathOf(state)),
      ),
      GoRoute(
        path: AppRoutes.searchPage,
        builder: (context, state) => SearchScreen(path: pathOf(state)),
      ),
      GoRoute(
        path: AppRoutes.shares,
        builder: (context, state) => const SharesScreen(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});
