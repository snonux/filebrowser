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

  /// When set, the next request for the list is answered with this instead
  /// of [links]: a snapshot taken before a later change.
  List<Map<String, dynamic>>? staleList;
  int _next = 1;

  late final adapter = FakeAdapter(_handle);

  Iterable<RequestOptions> requests(String method) =>
      adapter.requests.where((r) => r.method == method);

  ResponseBody _handle(RequestOptions o) {
    final path = o.uri.path;
    if (o.method == 'GET') {
      final stale = staleList;
      staleList = null;
      if (stale != null) return reply(200, body: stale);
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

  testWidgets('a finished delete does not close the form opened meanwhile',
      (tester) async {
    final server = _ShareServer([_link('a'), _link('b')]);
    await pumpApp(tester, server);
    await openShare(tester);
    final deleted = Completer<void>();
    server.adapter.hold = (o) => o.method == 'DELETE' ? deleted.future : null;
    await tap(tester, find.byTooltip('Delete link for a'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tap(tester, find.text('New link'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Password (optional)'), 'typing');

    deleted.complete();
    await settle(tester);
    // Still the form, with what was typed; the list behind it is up to date.
    expect(find.text('Create link'), findsOneWidget);
    expect(find.text('typing'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(find.text('http://fb.local/base/share/a'), findsNothing);
    expect(find.text('http://fb.local/base/share/b'), findsOneWidget);
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

  testWidgets('a link that a list already brought is not listed twice',
      (tester) async {
    final server = _ShareServer([_link('gone'), _link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    // A delete fails and fetches the list while a link is being created.
    // The server has stored the link already, so the list has it before
    // the answer to the create arrives.
    server.links.removeWhere((l) => l['hash'] == 'gone');
    server.deleteStatus = 404;
    server.staleList = [_link('open'), _link('new1')];
    final deleted = Completer<void>();
    final created = Completer<void>();
    server.adapter.hold = (o) => switch (o.method) {
          'DELETE' => deleted.future,
          'POST' => created.future,
          _ => null,
        };
    await tap(tester, find.byTooltip('Delete link for gone'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tap(tester, find.text('New link'));
    await tap(tester, find.text('Create link'));
    deleted.complete();
    await settle(tester);
    created.complete();
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
    expect(find.text('http://fb.local/base/share/gone'), findsNothing);
    expect(server.requests('POST'), hasLength(1));
  });

  testWidgets('a late list does not undo a link created meanwhile',
      (tester) async {
    final server = _ShareServer([_link('gone'), _link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    // The link is gone on the server, so its delete fails and the list is
    // fetched again; the answer is late and was taken before the link below
    // was created.
    server.links.removeWhere((l) => l['hash'] == 'gone');
    server.deleteStatus = 404;
    server.staleList = [_link('open')];
    final reload = Completer<void>();
    server.adapter.hold = (o) => o.method == 'GET' ? reload.future : null;
    await tap(tester, find.byTooltip('Delete link for gone'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tap(tester, find.text('New link'));
    await tap(tester, find.text('Create link'));
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);

    reload.complete();
    await settle(tester);
    expect(find.text('http://fb.local/base/share/new1'), findsOneWidget);
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
    // The outdated list was asked for again, so the link that the server no
    // longer has is gone as well.
    expect(server.requests('GET'), hasLength(3));
    expect(find.text('http://fb.local/base/share/gone'), findsNothing);
  });

  testWidgets('a late list does not bring back a link deleted meanwhile',
      (tester) async {
    final server = _ShareServer()..listStatus = 500;
    await pumpApp(tester, server);
    await openShare(tester);
    // Creating after a failed first load fetches the list; that answer is
    // late and still has the link that is deleted below.
    server.listStatus = null;
    server.staleList = [_link('new1')];
    final reload = Completer<void>();
    server.adapter.hold = (o) => o.method == 'GET' ? reload.future : null;
    await tap(tester, find.text('Create link'));
    await tap(tester, find.byTooltip('Delete link for new1'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.links, isEmpty);
    expect(find.text('Create link'), findsOneWidget);

    reload.complete();
    await settle(tester);
    // The outdated list was asked for again: failed, late, and now current.
    expect(server.requests('GET'), hasLength(3));
    await tap(tester, find.text('Cancel'));
    // Nothing is listed, so cancelling the form closed the dialog.
    expect(find.text('http://fb.local/base/share/new1'), findsNothing);
    expect(find.text('menu'), findsOneWidget);
    expect(find.text('New link'), findsNothing);
  });

  testWidgets('a failed delete whose reload fails too keeps the list',
      (tester) async {
    final server = _ShareServer([_link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    server
      ..deleteStatus = 500
      ..listStatus = 500;
    await tap(tester, find.byTooltip('Delete link for open'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(server.requests('GET'), hasLength(2));
    // Still the list, with the link and a delete button that works again.
    expect(find.text('http://fb.local/base/share/open'), findsOneWidget);
    expect(find.text('New link'), findsOneWidget);
    expect(find.text('Create link'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for open'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNotNull);
  });

  testWidgets('a late list that is asked for again shows the other links',
      (tester) async {
    final server = _ShareServer([_link('old')])..listStatus = 500;
    await pumpApp(tester, server);
    await openShare(tester);
    server.listStatus = null;
    final reload = Completer<void>();
    server.adapter.hold = (o) => o.method == 'GET' ? reload.future : null;
    await tap(tester, find.text('Create link'));
    // Deleting the new link outdates the list that is under way.
    await tap(tester, find.byTooltip('Delete link for new1'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));

    reload.complete();
    await settle(tester);
    // The link that was there all along is found after all, and the form
    // that the delete opened stays open.
    expect(find.text('Create link'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(find.text('http://fb.local/base/share/old'), findsOneWidget);
    expect(find.text('http://fb.local/base/share/new1'), findsNothing);
    expect(find.textContaining('there may be more than are listed here'),
        findsNothing);
  });

  testWidgets('a running delete stays with its link when another is deleted',
      (tester) async {
    final server = _ShareServer([
      _link('first', expire: 4102444700),
      _link('second', expire: 4102444800),
    ]);
    await pumpApp(tester, server);
    await openShare(tester);
    final held = Completer<void>();
    server.adapter.hold = (o) =>
        o.method == 'DELETE' && o.uri.path.endsWith('/second')
            ? held.future
            : null;
    await tap(tester, find.byTooltip('Delete link for second'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    // Removing the row above moves the second one up.
    await tap(tester, find.byTooltip('Delete link for first'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(find.text('http://fb.local/base/share/first'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for second'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNull);

    held.complete();
    await settle(tester);
    expect(server.links, isEmpty);
    expect(server.requests('DELETE'), hasLength(2));
    expect(find.text('Create link'), findsOneWidget);
  });

  testWidgets('closing the dialog while a link is deleted is harmless',
      (tester) async {
    final server = _ShareServer([_link('a'), _link('b')]);
    await pumpApp(tester, server);
    await openShare(tester);
    final deleted = Completer<void>();
    server.adapter.hold = (o) => o.method == 'DELETE' ? deleted.future : null;
    await tap(tester, find.byTooltip('Delete link for a'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tap(tester, find.text('Close'));
    expect(find.text('New link'), findsNothing);

    deleted.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(server.links.map((l) => l['hash']), ['b']);
  });

  testWidgets('closing the dialog before the links arrive is harmless',
      (tester) async {
    final server = _ShareServer([_link('a')]);
    await pumpApp(tester, server);
    final listed = Completer<void>();
    server.adapter.hold = (o) => o.method == 'GET' ? listed.future : null;
    await openShare(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Tapping beside the dialog dismisses it.
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    listed.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('http://fb.local/base/share/a'), findsNothing);
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
    // Nor can the form be left: the answer belongs to it.
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull);
    // Tapping beside the dialog still dismisses it.
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    expect(find.text('Create link'), findsNothing);

    created.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    // The link exists, so it is still copied and announced.
    expect(clipboard, ['http://fb.local/base/share/new1']);
    expect(find.text('Link created and copied'), findsOneWidget);
  });

  testWidgets('a create that fails after the dialog was closed is reported',
      (tester) async {
    final server = _ShareServer([_link('open')])..createStatus = 500;
    await pumpApp(tester, server);
    await openShare(tester);
    await tap(tester, find.text('New link'));
    final answered = Completer<void>();
    server.adapter.hold = (o) => o.method == 'POST' ? answered.future : null;
    await tap(tester, find.text('Create link'));
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    expect(find.text('Create link'), findsNothing);

    answered.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    // Said in a message, as there is no form left to show it on.
    expect(find.widgetWithText(SnackBar, 'Server error (500)'), findsOneWidget);
    expect(clipboard, isEmpty);
    expect(server.links, hasLength(1));
  });

  testWidgets('a refused delete keeps its button off until the list is back',
      (tester) async {
    final server = _ShareServer([_link('gone'), _link('open')]);
    await pumpApp(tester, server);
    await openShare(tester);
    server.links.removeWhere((l) => l['hash'] == 'gone');
    server.deleteStatus = 404;
    final reload = Completer<void>();
    server.adapter.hold = (o) => o.method == 'GET' ? reload.future : null;
    await tap(tester, find.byTooltip('Delete link for gone'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    // The delete is answered; the list that will drop the row is not yet.
    await tap(tester, find.text('New link'));
    await tap(tester, find.text('Cancel'));
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for gone'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNull);

    reload.complete();
    await settle(tester);
    expect(server.requests('DELETE'), hasLength(1));
    expect(find.byTooltip('Delete link for gone'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byTooltip('Delete link for open'),
                matching: find.byType(IconButton)))
            .onPressed,
        isNotNull);
  });

  testWidgets('a running delete keeps its button off across the form',
      (tester) async {
    final server = _ShareServer([_link('a'), _link('b')]);
    await pumpApp(tester, server);
    await openShare(tester);
    final deleted = Completer<void>();
    server.adapter.hold = (o) => o.method == 'DELETE' ? deleted.future : null;
    await tap(tester, find.byTooltip('Delete link for a'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    // Opening and leaving the form builds the list anew.
    await tap(tester, find.text('New link'));
    await tap(tester, find.text('Cancel'));
    IconButton deleteButton(String hash) =>
        tester.widget<IconButton>(find.ancestor(
            of: find.byTooltip('Delete link for $hash'),
            matching: find.byType(IconButton)));
    expect(deleteButton('a').onPressed, isNull);
    expect(deleteButton('b').onPressed, isNotNull);

    deleted.complete();
    await settle(tester);
    expect(server.requests('DELETE'), hasLength(1));
    expect(find.byTooltip('Delete link for a'), findsNothing);
    expect(deleteButton('b').onPressed, isNotNull);
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
