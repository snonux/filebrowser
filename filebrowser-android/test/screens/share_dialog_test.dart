import 'dart:async';
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

final _folder = FileItem(
  path: '/docs/album',
  name: 'album',
  size: 0,
  modified: DateTime(2026),
  isDir: true,
  type: '',
);

/// A scripted server that keeps share links like the real one does.
class _ShareServer {
  _ShareServer([List<Map<String, dynamic>> links = const []])
      : links = [...links];

  final List<Map<String, dynamic>> links;

  /// When set, creating a link fails with this status.
  int? createStatus;

  /// When set, listing the links fails with this status.
  int? listStatus;

  /// When set, deleting a link fails with this status.
  int? deleteStatus;
  int _next = 1;

  late final adapter = FakeAdapter(_handle);

  Iterable<RequestOptions> requests(String method) =>
      adapter.requests.where((r) => r.method == method);

  ResponseBody _handle(RequestOptions o) {
    final path = o.uri.path;
    if (o.method == 'GET') {
      return listStatus == null ? reply(200, body: links) : reply(listStatus!);
    }
    if (o.method == 'DELETE') {
      if (deleteStatus != null) return reply(deleteStatus!);
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

  /// Whether the platform refuses to copy.
  late bool clipboardFails;

  /// Shows a screen with one button that opens the item's actions menu, for
  /// an account with [perm] on a server at `http://fb.local/base`.
  Future<void> pumpApp(WidgetTester tester, _ShareServer server,
      {Permissions perm = const Permissions(share: true, download: true),
      FileItem? item}) async {
    clipboard = [];
    clipboardFails = false;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (clipboardFails) throw PlatformException(code: 'unavailable');
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
              onPressed: () =>
                  FileActions(context).showMenu(context, item ?? _item),
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

  testWidgets('a folder is listed and shared with a trailing slash',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server, item: _folder);
    await openShare(tester);
    await tap(tester, find.text('Create link'));
    // The web UI addresses folders this way, and the server matches a
    // non-admin's links by the exact path.
    expect(server.adapter.requests.map((r) => '${r.method} ${r.uri}'), [
      'GET http://fb.local/base/api/share/docs/album/',
      // Links stored without the slash, as version 0.1.0 made them.
      'GET http://fb.local/base/api/share/docs/album',
      'POST http://fb.local/base/api/share/docs/album/',
    ]);
  });

  testWidgets('a link with a password is marked as protected', (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Password (optional)'), 'pw');
    await tap(tester, find.text('Create link'));
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.byTooltip('No download link for new1: it has a password'),
        findsOneWidget);
  });

  testWidgets('a lifetime the server cannot add is reported per unit',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    // 200000 hours are fine, 200000 days would wrap to a date in the past.
    await tester.enterText(
        find.widgetWithText(TextField, 'Expires after'), '200000');
    await tap(tester, find.text('hours'));
    await tap(tester, find.text('days').last);
    await tap(tester, find.text('Create link'));
    expect(find.text('Enter a whole number from 0 to 106751'), findsOneWidget);
    expect(server.requests('POST'), isEmpty);

    await tap(tester, find.text('days'));
    await tap(tester, find.text('hours').last);
    // The limit named belongs to the other unit, so the complaint goes.
    expect(find.textContaining('Enter a whole number'), findsNothing);
    await tap(tester, find.text('Create link'));
    expect(postedBody(server), {
      'password': '',
      'expires': '200000',
      'unit': 'hours',
    });
  });

  testWidgets('a list that cannot be loaded is reported, then loaded again',
      (tester) async {
    final server = _ShareServer([_link('old')])..listStatus = 500;
    await pumpApp(tester, server);
    await openShare(tester);
    // The form opens, saying that it is the list that is missing.
    expect(find.textContaining('Could not load the existing links'),
        findsOneWidget);
    expect(find.text('Create link'), findsOneWidget);

    server.listStatus = null;
    await tap(tester, find.text('Create link'));
    // The new link is not presented as the only one.
    expect(server.requests('GET'), hasLength(2));
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);
    expect(find.text('http://fb.local/base/share/old'), findsOneWidget);
    expect(find.textContaining('could not be loaded'), findsNothing);
  });

  testWidgets('a list that still cannot be loaded shows the new link',
      (tester) async {
    final server = _ShareServer()..listStatus = 403;
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.text('Create link'));
    expect(server.requests('GET'), hasLength(2));
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);
    expect(find.text('New link'), findsOneWidget);
    // The one link shown is not presented as the whole list.
    expect(find.textContaining('there may be more than are listed here'),
        findsOneWidget);
  });

  testWidgets('correcting the lifetime clears its error', (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    final field = find.widgetWithText(TextField, 'Expires after');
    await tester.enterText(field, 'soon');
    await tap(tester, find.text('Create link'));
    expect(find.textContaining('Enter a whole number'), findsOneWidget);
    await tester.enterText(field, '5');
    await settle(tester);
    expect(find.textContaining('Enter a whole number'), findsNothing);
    expect(server.requests('POST'), isEmpty);
  });

  testWidgets('a reload does not close the form opened meanwhile',
      (tester) async {
    final server = _ShareServer([_link('gone'), _link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    // The delete fails, so the list is fetched again; that answer is late.
    server.deleteStatus = 404;
    final reload = Completer<void>();
    server.adapter.hold = (o) =>
        o.method == 'GET' && server.requests('GET').length > 1
            ? reload.future
            : null;
    await tap(tester, find.byTooltip('Delete link for gone'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tap(tester, find.text('New link'));
    expect(find.text('Create link'), findsOneWidget);

    reload.complete();
    await settle(tester);
    expect(find.text('Create link'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Expires after'), findsOneWidget);
  });

  testWidgets('closing the dialog while a link is created is harmless',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    final created = Completer<void>();
    server.adapter.hold = (o) => o.method == 'POST' ? created.future : null;
    await tap(tester, find.text('Create link'));
    // No second request while the first is under way.
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Create link'))
            .onPressed,
        isNull);
    await tap(tester, find.text('Cancel'));
    expect(find.text('Create link'), findsNothing);

    created.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    // The link exists, so it is still copied and announced.
    expect(clipboard, ['http://fb.local/base/share/new1']);
    expect(find.text('Link created and copied'), findsOneWidget);
  });

  testWidgets('deleting one of several links leaves the others usable',
      (tester) async {
    final server = _ShareServer([_link('a'), _link('b'), _link('c')]);
    await pumpApp(tester, server);
    await openShare(tester);
    final first = tester
        .widgetList<Text>(find.textContaining('http://fb.local/base/share/'))
        .first
        .data!
        .split('/')
        .last;
    await tap(tester, find.byTooltip('Delete link for $first'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(find.byTooltip('Delete link for $first'), findsNothing);
    final rest = ['a', 'b', 'c']..remove(first);
    for (final hash in rest) {
      expect(
          tester
              .widget<IconButton>(find.ancestor(
                  of: find.byTooltip('Delete link for $hash'),
                  matching: find.byType(IconButton)))
              .onPressed,
          isNotNull,
          reason: hash);
    }
    await tap(tester, find.byTooltip('Delete link for ${rest.first}'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.links.map((l) => l['hash']), [rest.last]);
  });

  testWidgets('a failed copy still shows the link that was created',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    clipboardFails = true;
    await tap(tester, find.text('Create link'));
    expect(server.links, hasLength(1));
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);
    expect(
        find.text('Link created, but it could not be copied'), findsOneWidget);
    expect(find.text('Link created and copied'), findsNothing);

    await tap(tester, find.byTooltip('Copy link for new1'));
    expect(find.text('Could not copy the link'), findsOneWidget);
    expect(find.text('Link copied'), findsNothing);
    expect(clipboard, isEmpty);
  });

  testWidgets('a link that is already gone disappears after a failed delete',
      (tester) async {
    final server = _ShareServer([_link('gone'), _link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    // It expired on the server while the dialog was open.
    server.links.removeWhere((l) => l['hash'] == 'gone');
    server.deleteStatus = 404;
    await tap(tester, find.byTooltip('Delete link for gone'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.requests('DELETE'), hasLength(1));
    expect(server.requests('GET'), hasLength(2));
    expect(find.text('http://fb.local/base/share/gone'), findsNothing);
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
  });

  testWidgets('a delete the server refuses keeps the link', (tester) async {
    final server = _ShareServer([_link('open')])..deleteStatus = 500;
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.byTooltip('Delete link for open'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.links, hasLength(1));
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
    // The button works again for another try.
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for open'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNotNull);
  });

  testWidgets('cancelling the form of an item without links closes the dialog',
      (tester) async {
    final server = _ShareServer();
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.text('Cancel'));
    expect(find.text('Create link'), findsNothing);
    expect(find.text('menu'), findsOneWidget);
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
