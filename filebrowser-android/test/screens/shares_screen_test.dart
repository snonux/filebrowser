import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/navigation_key.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/screens/shares_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/fake_adapter.dart';

void main() {
  const links = [
    {'hash': 'h1', 'path': '/mine.txt', 'userID': 1, 'expire': 0},
    {'hash': 'h2', 'path': '/theirs.txt', 'userID': 7, 'expire': 0},
  ];

  /// Shows the list of all links for an account with [perm]. [usersStatus]
  /// is what the server answers when asked for the user list.
  Future<FakeAdapter> pumpScreen(WidgetTester tester, Permissions perm,
      {int usersStatus = 200}) async {
    final adapter = FakeAdapter((o) {
      if (o.uri.path.endsWith('/api/shares')) return reply(200, body: links);
      if (usersStatus != 200) return reply(usersStatus);
      return reply(200, body: [
        {'id': 1, 'username': 'alice'},
        {'id': 7, 'username': 'bob'},
      ]);
    });
    final api = FileBrowserApi(
        baseUrl: 'http://fb.local/base',
        dio: Dio()..httpClientAdapter = adapter)
      ..token = 'a.b.c';
    final session =
        Session(api: api, user: UserInfo(id: 1, username: 'alice', perm: perm));
    await tester.pumpWidget(ProviderScope(
      overrides: [requireSessionProvider.overrideWithValue(session)],
      child: MaterialApp(
          scaffoldMessengerKey: appMessengerKey, home: const SharesScreen()),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    return adapter;
  }

  Iterable<String> paths(FakeAdapter adapter) =>
      adapter.requests.map((r) => r.uri.path);

  testWidgets('an administrator sees whose link each one is', (tester) async {
    final adapter = await pumpScreen(
        tester, const Permissions(admin: true, share: true, download: true));
    expect(find.text('/theirs.txt'), findsOneWidget);
    expect(find.text('Never expires · alice'), findsOneWidget);
    expect(find.text('Never expires · bob'), findsOneWidget);
    expect(paths(adapter), contains('/base/api/users'));
  });

  testWidgets('other accounts do not ask for the user list', (tester) async {
    final adapter = await pumpScreen(
        tester, const Permissions(share: true, download: true));
    expect(find.text('/mine.txt'), findsOneWidget);
    expect(find.text('Never expires'), findsNWidgets(2));
    expect(paths(adapter), ['/base/api/shares']);
  });

  testWidgets('links are still listed when the user list fails',
      (tester) async {
    await pumpScreen(
        tester, const Permissions(admin: true, share: true, download: true),
        usersStatus: 500);
    expect(find.text('/mine.txt'), findsOneWidget);
    expect(find.text('Never expires'), findsNWidgets(2));
  });
}
