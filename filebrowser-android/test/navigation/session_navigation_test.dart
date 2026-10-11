import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/app.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/providers/preferences_provider.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/fake_adapter.dart';

class TestSession extends SessionController {
  TestSession(this.initial);
  final Session initial;
  @override
  Future<Session?> build() async => initial;
  void logoutForTest() => state = const AsyncData(null);
  void renew() =>
      state = AsyncData(Session(api: initial.api, user: initial.user));
}

void main() {
  testWidgets('renewing a session keeps the navigation drawer open',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = FileBrowserApi(
        baseUrl: 'http://fb.local',
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((request) => reply(200,
              body: request.path.contains('/usage/')
                  ? {'used': 1, 'total': 100}
                  : {'name': '', 'path': '/', 'isDir': true, 'items': []})));
    final sessions = TestSession(Session(
        api: api,
        user: const UserInfo(
            id: 1,
            username: 'admin',
            perm: Permissions(share: true, download: true))));
    final container = ProviderContainer(overrides: [
      sessionProvider.overrideWith(() => sessions),
      sharedPreferencesProvider.overrideWithValue(prefs)
    ]);
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const FileBrowserApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Share links'), findsOneWidget);
    sessions.renew();
    await tester.pumpAndSettle();
    expect(find.text('Share links'), findsOneWidget);
    sessions.logoutForTest();
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });
}
