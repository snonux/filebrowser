import 'dart:async';

import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/navigation_key.dart';
import 'package:filebrowser_android/widgets/share_link_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int unixSeconds(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

  test('shareExpiryText tells a live link from an expired one', () {
    ShareLink link(int expire) =>
        ShareLink(hash: 'h', path: '/f', expire: expire);
    final now = DateTime.now();
    expect(shareExpiryText(link(0)), 'Never expires');
    expect(shareExpiryText(link(unixSeconds(now.add(const Duration(days: 1))))),
        startsWith('Expires '));
    expect(
        shareExpiryText(
            link(unixSeconds(now.subtract(const Duration(days: 1))))),
        startsWith('Expired '));
  });

  group('delete button', () {
    Finder deleteButton() => find.ancestor(
        of: find.byTooltip('Delete link for h1'),
        matching: find.byType(IconButton));

    Future<void> pumpTile(
        WidgetTester tester, Future<void> Function() onDelete) {
      return tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: appMessengerKey,
        home: Scaffold(
          body: ShareLinkTile(
            api: FileBrowserApi(baseUrl: 'http://fb.local'),
            link: const ShareLink(hash: 'h1', path: '/f', expire: 0),
            title: '/f',
            label: 'h1',
            onDelete: onDelete,
          ),
        ),
      ));
    }

    testWidgets('is off while a delete is under way', (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await pumpTile(tester, () {
        calls++;
        return pending.future;
      });
      await tester.tap(deleteButton());
      await tester.pump();
      expect(tester.widget<IconButton>(deleteButton()).onPressed, isNull);
      // A second tap does not ask the server again.
      await tester.tap(deleteButton(), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      pending.complete();
      await tester.pump();
      expect(tester.widget<IconButton>(deleteButton()).onPressed, isNotNull);
    });

    testWidgets('survives the tile being removed meanwhile', (tester) async {
      final pending = Completer<void>();
      await pumpTile(tester, () => pending.future);
      await tester.tap(deleteButton());
      await tester.pump();
      // The list drops the tile once its link is deleted.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
