import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_routes.dart';
import 'navigation_key.dart';
import 'providers/session_provider.dart';
import 'providers/share_provider.dart';
import 'screens/browser_screen.dart';
import 'screens/image_viewer_screen.dart';
import 'screens/local_browser_screen.dart';
import 'screens/login_screen.dart';
import 'screens/media_player_screen.dart';
import 'screens/offline_screen.dart';
import 'screens/pdf_viewer_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/share_upload_screen.dart';
import 'screens/shares_screen.dart';
import 'screens/text_editor_screen.dart';

export 'app_routes.dart' show AppRoutes;

/// Re-runs the router's redirect whenever the session or the waiting share
/// changes.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, __) => notifyListeners());
    ref.listen(pendingShareProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionListenable(ref);
  ref.onDispose(refresh.dispose);

  String pathOf(GoRouterState state) =>
      state.uri.queryParameters['path'] ?? '/';

  return GoRouter(
    navigatorKey: appNavigatorKey,
    initialLocation: AppRoutes.files('/'),
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      if (session.isLoading) return null;
      final signedIn = session.valueOrNull != null;
      final atLogin = state.matchedLocation == AppRoutes.login;
      if (!signedIn) return atLogin ? null : AppRoutes.login;
      // A share from another app waits for the user's upload or cancel.
      final sharing = ref.read(pendingShareProvider) != null;
      final atShare = state.matchedLocation == AppRoutes.shareUpload;
      if (sharing && !atShare) return AppRoutes.shareUpload;
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
        path: AppRoutes.pdfViewer,
        builder: (context, state) => PdfViewerScreen(path: pathOf(state)),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (context, state) => MediaPlayerScreen(path: pathOf(state)),
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
        path: AppRoutes.offline,
        builder: (context, state) => const OfflineScreen(),
      ),
      GoRoute(
        path: AppRoutes.shareUpload,
        builder: (context, state) => const ShareUploadScreen(),
      ),
      GoRoute(
        path: AppRoutes.phone,
        builder: (context, state) =>
            LocalBrowserScreen(path: state.uri.queryParameters['path'] ?? ''),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});
