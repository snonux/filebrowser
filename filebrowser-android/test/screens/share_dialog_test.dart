import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/navigation_key.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/screens/file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/fake_adapter.dart';

final _item = FileItem(
  path: '/docs/report.pdf',
  name: 'report.pdf',
  size: 10,
  modified: DateTime(2026),
  isDir: false,
  type: 'pdf',
);

/// A scripted server that keeps share links like the real one does.
class _ShareServer {
  _ShareServer([List<Map<String, dynamic>> links = const []])
      : links = [...links];

  final List<Map<String, dynamic>> links;

  /// When set, creating a link fails with this status.
  int? createStatus;
  int _next = 1;

  late final adapter = FakeAdapter(_handle);

  Iterable<RequestOptions> requests(String method) =>
      adapter.requests.where((r) => r.method == method);

  ResponseBody _handle(RequestOptions o) {
    final path = o.uri.path;
    if (o.method == 'GET') return reply(200, body: links);
    if (o.method == 'DELETE') {
      links.removeWhere((l) => path.endsWith('/${l['hash']}'));
      return reply(200);
    }
    if (createStatus != null) return reply(createStatus!);
    final body = jsonDecode(o.data as String) as Map<String, dynamic>;
    final link = {
      'hash': 'new${_next++}',
      'path': _item.path,
      'expire': body['expires'] == '' ? 0 : 4102444800,
      'hasPassword': body['password'] != '',
    };
    links.add(link);
    return reply(200, body: link);
  }
}

Map<String, dynamic> _link(String hash,
        {int expire = 0, bool hasPassword = false}) =>
    {
      'hash': hash,
      'path': _item.path,
      'expire': expire,
      'hasPassword': hasPassword
    };

void main() {
  late List<String> clipboard;

  /// Shows a screen with one button that opens the item's actions menu, for
  /// an account with [perm] on a server at `http://fb.local/base`.
  Future<void> pumpApp(WidgetTester tester, _ShareServer server,
      {Permissions perm =
          const Permissions(share: true, download: true)}) async {
    clipboard = [];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    final api = FileBrowserApi(
        baseUrl: 'http://fb.local/base/',
        dio: Dio()..httpClientAdapter = server.adapter)
      ..token = 'a.b.c';
    final session =
        Session(api: api, user: UserInfo(id: 1, username: 'alice', perm: perm));
    await tester.pumpWidget(ProviderScope(
      overrides: [requireSessionProvider.overrideWithValue(session)],
      child: MaterialApp(
        scaffoldMessengerKey: appMessengerKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => FileActions(context).showMenu(context, _item),
              child: const Text('menu'),
            ),
          ),
        ),
      ),
    ));
  }

  /// Lets requests answer and dialogs finish animating. The loading spinner
  /// never settles, so this pumps a fixed time instead of `pumpAndSettle`.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> openShare(WidgetTester tester) async {
    await tap(tester, find.text('menu'));
    await tap(tester, find.text('Share link'));
  }

  Map<String, dynamic> postedBody(_ShareServer server) =>
      jsonDecode(server.requests('POST').single.data as String)
          as Map<String, dynamic>;

  testWidgets('an item without links opens on the form and creates one',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    expect(server.requests('GET').single.uri.toString(),
        'http://fb.local/base/api/share/docs/report.pdf');
    expect(find.text('Create link'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Expires after'), '2');
    await tap(tester, find.text('hours'));
    // All four units of the web UI are offered.
    for (final unit in ['seconds', 'minutes', 'hours', 'days']) {
      expect(find.text(unit), findsWidgets, reason: unit);
    }
    await tap(tester, find.text('seconds').last);
    await tester.enterText(
        find.widgetWithText(TextField, 'Password (optional)'), ' pw ');
    await tap(tester, find.text('Create link'));

    expect(server.requests('POST').single.uri.toString(),
        'http://fb.local/base/api/share/docs/report.pdf');
    // The password is trimmed, as the web UI's field does.
    expect(postedBody(server),
        {'password': 'pw', 'expires': '2', 'unit': 'seconds'});
    // The link uses the configured address and is copied right away.
    expect(clipboard, ['http://fb.local/base/share/new1']);
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);
    expect(find.text('New link'), findsOneWidget);
  });

  testWidgets('an empty form creates a permanent link without a password',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Password (optional)'), '   ');
    await tap(tester, find.text('Create link'));
    expect(
        postedBody(server), {'password': '', 'expires': '', 'unit': 'hours'});
    expect(find.text('Never expires'), findsOneWidget);
  });

  testWidgets('an invalid expiry is reported and nothing is created',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    for (final bad in ['-1', '1.5', 'soon', '2147483648']) {
      await tester.enterText(
          find.widgetWithText(TextField, 'Expires after'), bad);
      await tap(tester, find.text('Create link'));
      expect(find.textContaining('Enter a whole number'), findsOneWidget,
          reason: bad);
    }
    expect(server.requests('POST'), isEmpty);
    expect(clipboard, isEmpty);

    // Correcting the field clears the error and creates the link.
    await tester.enterText(
        find.widgetWithText(TextField, 'Expires after'), '3');
    await tap(tester, find.text('Create link'));
    expect(postedBody(server)['expires'], '3');
    expect(find.textContaining('Enter a whole number'), findsNothing);
  });

  testWidgets('a server error keeps the form open and shows the reason',
      (tester) async {
    final server = _ShareServer()..createStatus = 403;
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.text('Create link'));
    expect(find.text('Create link'), findsOneWidget);
    expect(find.text('You do not have permission to do that'), findsOneWidget);
    expect(clipboard, isEmpty);
  });

  testWidgets('existing links are listed with copy, download link and delete',
      (tester) async {
    final server = _ShareServer([
      _link('late', expire: 4102444800),
      _link('open'),
      _link('locked', expire: 4102444700, hasPassword: true),
    ]);
    await pumpApp(tester, server);
    await openShare(tester);

    // Permanent links first, then by expiry, as in the web UI.
    final shown = tester
        .widgetList<Text>(find.textContaining('http://fb.local/base/share/'))
        .map((t) => t.data);
    expect(shown, [
      'http://fb.local/base/share/open',
      'http://fb.local/base/share/locked',
      'http://fb.local/base/share/late',
    ]);

    await tap(tester, find.byTooltip('Copy link for open'));
    await tap(tester, find.byTooltip('Copy download link for open'));
    expect(clipboard, [
      'http://fb.local/base/share/open',
      'http://fb.local/base/api/public/dl/open?inline=true',
    ]);

    // A direct download cannot carry the password.
    final locked =
        find.byTooltip('No download link for locked: it has a password');
    expect(
        tester
            .widget<IconButton>(
                find.ancestor(of: locked, matching: find.byType(IconButton)))
            .onPressed,
        isNull);

    await tap(tester, find.byTooltip('Delete link for late'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.requests('DELETE').single.uri.toString(),
        'http://fb.local/base/api/share/late');
    expect(find.text('http://fb.local/base/share/late'), findsNothing);
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
  });

  testWidgets('cancelling a delete keeps the link', (tester) async {
    final server = _ShareServer([_link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.byTooltip('Delete link for open'));
    await tap(tester, find.text('Cancel'));
    expect(server.requests('DELETE'), isEmpty);
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
  });

  testWidgets('deleting the last link returns to the form', (tester) async {
    final server = _ShareServer([_link('only')]);
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.byTooltip('Delete link for only'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.links, isEmpty);
    expect(find.text('Create link'), findsOneWidget);
  });

  testWidgets('cancelling the form returns to the list when there is one',
      (tester) async {
    final server = _ShareServer([_link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.text('New link'));
    expect(find.text('Create link'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
    expect(server.requests('POST'), isEmpty);
  });

  testWidgets('sharing is not offered without the share permission',
      (tester) async {
    for (final perm in const [
      Permissions(download: true),
      // The server refuses shares from an account that may not download.
      Permissions(share: true),
    ]) {
      final server = _ShareServer();
      await pumpApp(tester, server, perm: perm);
      await tap(tester, find.text('menu'));
      expect(find.text('Info'), findsOneWidget);
      expect(find.text('Share link'), findsNothing);
      expect(server.adapter.requests, isEmpty);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
    }
  });
}
