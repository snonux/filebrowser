import 'dart:async';

import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/navigation_key.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/screens/shares_screen.dart';
import 'package:filebrowser_android/widgets/app_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/fake_adapter.dart';

const _admin = Permissions(admin: true, share: true, download: true);
const _user = Permissions(share: true, download: true);

/// A scripted server with the account's share links and the user list.
class _Server {
  final links = <Map<String, dynamic>>[
    {'hash': 'h1', 'path': '/mine.txt', 'userID': 1, 'expire': 0},
    {'hash': 'h2', 'path': '/theirs.txt', 'userID': 7, 'expire': 0},
  ];

  /// What the server answers when asked for the links, the user list, or to
  /// delete a link.
  int sharesStatus = 200;
  int usersStatus = 200;
  int deleteStatus = 200;

  late final adapter = FakeAdapter(_handle);

  Iterable<String> get paths => adapter.requests.map((r) => r.uri.path);

  int count(String method, String path) => adapter.requests
      .where((r) => r.method == method && r.uri.path == path)
      .length;

  ResponseBody _handle(RequestOptions o) {
    final path = o.uri.path;
    if (o.method == 'DELETE') {
      if (deleteStatus != 200) return reply(deleteStatus);
      links.removeWhere((l) => path.endsWith('/${l['hash']}'));
      return reply(200);
    }
    if (path.endsWith('/api/usage/')) {
      return reply(200, body: {'used': 1, 'total': 2});
    }
    if (path.endsWith('/api/shares')) {
      return sharesStatus == 200
          ? reply(200, body: links)
          : reply(sharesStatus);
    }
    if (usersStatus != 200) return reply(usersStatus);
    return reply(200, body: [
      {'id': 1, 'username': 'alice'},
      {'id': 7, 'username': 'bob'},
    ]);
  }
}

void main() {
  late List<String> clipboard;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settle(tester);
  }

  /// Shows [home] for an account with [perm] on [server].
  Future<void> pumpHome(WidgetTester tester, _Server server, Permissions perm,
      Widget home) async {
    clipboard = [];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    final api = FileBrowserApi(
        baseUrl: 'http://fb.local/base',
        dio: Dio()..httpClientAdapter = server.adapter)
      ..token = 'a.b.c';
    final session =
        Session(api: api, user: UserInfo(id: 1, username: 'alice', perm: perm));
    await tester.pumpWidget(ProviderScope(
      overrides: [requireSessionProvider.overrideWithValue(session)],
      child: MaterialApp(scaffoldMessengerKey: appMessengerKey, home: home),
    ));
    await settle(tester);
  }

  Future<void> pumpScreen(
          WidgetTester tester, _Server server, Permissions perm) =>
      pumpHome(tester, server, perm, const SharesScreen());

  testWidgets('an administrator sees whose link each one is', (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _admin);
    expect(find.text('/theirs.txt'), findsOneWidget);
    expect(find.text('Never expires · alice'), findsOneWidget);
    expect(find.text('Never expires · bob'), findsOneWidget);
    expect(server.paths, contains('/base/api/users'));
  });

  testWidgets('a link of an account that is not listed has no owner label',
      (tester) async {
    final server = _Server()
      ..links.addAll([
        {'hash': 'h3', 'path': '/deleted-user.txt', 'userID': 99, 'expire': 0},
        // No owner id at all, as a malformed record would have.
        {'hash': 'h4', 'path': '/nobody.txt', 'expire': 0},
      ]);
    await pumpScreen(tester, server, _admin);
    expect(find.text('/deleted-user.txt'), findsOneWidget);
    expect(find.text('/nobody.txt'), findsOneWidget);
    expect(find.text('Never expires'), findsNWidgets(2));
    expect(find.textContaining(' · '), findsNWidgets(2));
  });

  testWidgets('other accounts do not ask for the user list', (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    expect(find.text('/mine.txt'), findsOneWidget);
    expect(find.text('Never expires'), findsNWidgets(2));
    expect(server.paths, ['/base/api/shares']);
  });

  testWidgets('links are still listed when the user list fails',
      (tester) async {
    final server = _Server()..usersStatus = 500;
    await pumpScreen(tester, server, _admin);
    expect(find.text('/mine.txt'), findsOneWidget);
    expect(find.text('Never expires'), findsNWidgets(2));
  });

  testWidgets('an account without links is told so', (tester) async {
    final server = _Server()..links.clear();
    await pumpScreen(tester, server, _user);
    expect(find.text('No share links'), findsOneWidget);
  });

  testWidgets('a list that cannot be loaded shows the reason', (tester) async {
    final server = _Server()..sharesStatus = 403;
    await pumpScreen(tester, server, _user);
    expect(find.text('You do not have permission to do that'), findsOneWidget);
    expect(find.text('/mine.txt'), findsNothing);
    expect(find.text('No share links'), findsNothing);
  });

  testWidgets('copies the link with the configured address', (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    await tap(tester, find.byTooltip('Copy link for /mine.txt'));
    expect(clipboard, ['http://fb.local/base/share/h1']);
    expect(find.text('Link copied'), findsOneWidget);
    // The download link is only offered in an item's own share dialog.
    expect(find.byTooltip('Copy download link for /mine.txt'), findsNothing);
  });

  testWidgets('deletes a link after confirmation and lists the rest',
      (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    await tap(tester, find.byTooltip('Delete link for /mine.txt'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.count('DELETE', '/base/api/share/h1'), 1);
    expect(server.count('GET', '/base/api/shares'), 2);
    expect(find.text('/mine.txt'), findsNothing);
    expect(find.text('/theirs.txt'), findsOneWidget);
  });

  testWidgets('a cancelled delete asks the server nothing', (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    await tap(tester, find.byTooltip('Delete link for /mine.txt'));
    await tap(tester, find.text('Cancel'));
    expect(server.adapter.requests.where((r) => r.method == 'DELETE'), isEmpty);
    // Nothing changed, so the list is not fetched again either.
    expect(server.count('GET', '/base/api/shares'), 1);
    expect(find.text('/mine.txt'), findsOneWidget);
  });

  testWidgets('a failed delete fetches the list again', (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    // The link is already gone on the server.
    server.links.removeWhere((l) => l['hash'] == 'h1');
    server.deleteStatus = 404;
    await tap(tester, find.byTooltip('Delete link for /mine.txt'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.count('GET', '/base/api/shares'), 2);
    expect(find.text('/mine.txt'), findsNothing);
    expect(find.text('/theirs.txt'), findsOneWidget);
  });

  testWidgets('the delete button stays off until the row is gone',
      (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    final refetch = Completer<void>();
    server.adapter.hold = (o) => o.method == 'GET' ? refetch.future : null;
    await tap(tester, find.byTooltip('Delete link for /mine.txt'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    // Deleted on the server, but the new list has not arrived yet.
    expect(server.count('DELETE', '/base/api/share/h1'), 1);
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for /mine.txt'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNull);

    refetch.complete();
    await settle(tester);
    expect(find.text('/mine.txt'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for /theirs.txt'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNotNull);
  });

  testWidgets('a running delete stays with its link when the list changes',
      (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    IconButton deleteButton(String path) =>
        tester.widget<IconButton>(find.ancestor(
            of: find.byTooltip('Delete link for $path'),
            matching: find.byType(IconButton)));
    // The delete of the second link is under way while the first one is
    // deleted and its row removed, which moves the second row up.
    final second = Completer<void>();
    server.adapter.hold = (o) =>
        o.method == 'DELETE' && o.uri.path.endsWith('/h2')
            ? second.future
            : null;
    await tap(tester, find.byTooltip('Delete link for /theirs.txt'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tap(tester, find.byTooltip('Delete link for /mine.txt'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(find.text('/mine.txt'), findsNothing);
    expect(deleteButton('/theirs.txt').onPressed, isNull);

    second.complete();
    await settle(tester);
    expect(find.text('No share links'), findsOneWidget);
    expect(server.count('DELETE', '/base/api/share/h2'), 1);
  });

  testWidgets('leaving the screen while a link is deleted is harmless',
      (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    final deleted = Completer<void>();
    server.adapter.hold = (o) => o.method == 'DELETE' ? deleted.future : null;
    await tap(tester, find.byTooltip('Delete link for /mine.txt'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpWidget(const SizedBox());

    deleted.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    // The screen is gone, so nothing is fetched for it.
    expect(server.count('GET', '/base/api/shares'), 1);
  });

  testWidgets('pulling down fetches the links and the owners again',
      (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _admin);
    server.links.removeWhere((l) => l['hash'] == 'h2');
    await tester.fling(find.text('/mine.txt'), const Offset(0, 400), 1000);
    await settle(tester);
    await settle(tester);
    expect(server.count('GET', '/base/api/shares'), 2);
    expect(server.count('GET', '/base/api/users'), 2);
    expect(find.text('/theirs.txt'), findsNothing);
    expect(find.text('/mine.txt'), findsOneWidget);
  });

  testWidgets('a refresh that fails shows the reason', (tester) async {
    final server = _Server();
    await pumpScreen(tester, server, _user);
    server.sharesStatus = 500;
    await tester.fling(find.text('/mine.txt'), const Offset(0, 400), 1000);
    await settle(tester);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(server.count('GET', '/base/api/shares'), 2);
    expect(find.text('/mine.txt'), findsNothing);
    expect(find.textContaining('500'), findsOneWidget);
  });

  group('drawer', () {
    Future<void> pumpDrawer(WidgetTester tester, Permissions perm) async {
      final scaffold = GlobalKey<ScaffoldState>();
      await pumpHome(tester, _Server(), perm,
          Scaffold(key: scaffold, drawer: const AppDrawer(currentPath: '/')));
      scaffold.currentState!.openDrawer();
      await settle(tester);
      expect(find.text('Settings'), findsOneWidget);
    }

    testWidgets('lists the share links for an account that may share',
        (tester) async {
      await pumpDrawer(tester, _user);
      expect(find.text('Share links'), findsOneWidget);
    });

    testWidgets('hides them without the share or the download permission',
        (tester) async {
      for (final perm in const [
        Permissions(download: true),
        Permissions(share: true),
      ]) {
        await pumpDrawer(tester, perm);
        expect(find.text('Share links'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
