import 'dart:async';

import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/navigation_key.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/screens/file_actions.dart';
import 'package:flutter/material.dart';
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

void main() {
  Future<void> openInfo(WidgetTester tester, FakeAdapter adapter) async {
    final api = FileBrowserApi(
        baseUrl: 'http://fb.local/base/',
        dio: Dio()..httpClientAdapter = adapter)
      ..token = 'a.b.c';
    final session = Session(
        api: api,
        user: const UserInfo(id: 1, username: 'alice', perm: Permissions()));
    await tester.pumpWidget(ProviderScope(
      overrides: [requireSessionProvider.overrideWithValue(session)],
      child: MaterialApp(
        scaffoldMessengerKey: appMessengerKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => FileActions(context).info(context, _item),
              child: const Text('Info'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
  }

  FakeAdapter checksumAdapter() => FakeAdapter((_) => reply(200, body: {
        'checksums': {'sha256': 'test-checksum'}
      }));

  for (final barrier in [false, true]) {
    testWidgets(
        'checksum completing after ${barrier ? 'barrier' : 'Close'} dismissal is safe',
        (tester) async {
      final answered = Completer<void>();
      final adapter = checksumAdapter()..hold = (_) => answered.future;
      await openInfo(tester, adapter);
      await tester.tap(find.text('SHA-256'));
      await tester.pumpAndSettle();
      expect(adapter.requests, hasLength(1));
      expect(find.text('Computing…'), findsOneWidget);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Computing…'))
              .onPressed,
          isNull);

      if (barrier) {
        await tester.tapAt(const Offset(10, 10));
      } else {
        await tester.tap(find.text('Close'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      answered.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('test-checksum'), findsNothing);
    });
  }

  testWidgets('checksum appears when the dialog remains open', (tester) async {
    final answered = Completer<void>();
    final adapter = checksumAdapter()..hold = (_) => answered.future;
    await openInfo(tester, adapter);
    await tester.tap(find.text('SHA-256'));
    await tester.pumpAndSettle();
    expect(adapter.requests.single.uri.toString(),
        'http://fb.local/base/api/resources/docs/report.pdf?checksum=sha256');
    expect(find.text('Computing…'), findsOneWidget);

    answered.complete();
    await tester.pumpAndSettle();
    expect(find.text('test-checksum'), findsOneWidget);
    expect(find.text('Copy checksum'), findsOneWidget);
    expect(find.text('Computing…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed checksum shows the error and allows retry',
      (tester) async {
    var fail = true;
    final adapter = FakeAdapter((_) => fail
        ? reply(500)
        : reply(200, body: {
            'checksums': {'sha256': 'test-checksum'}
          }));
    await openInfo(tester, adapter);
    await tester.tap(find.text('SHA-256'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SnackBar, 'Server error (500)'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'SHA-256'))
            .onPressed,
        isNotNull);

    fail = false;
    await tester.tap(find.text('SHA-256'));
    await tester.pumpAndSettle();
    expect(adapter.requests, hasLength(2));
    expect(find.text('test-checksum'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed checksum after dismissal is reported safely',
      (tester) async {
    final answered = Completer<void>();
    final adapter = FakeAdapter((_) => reply(500))
      ..hold = (_) => answered.future;
    await openInfo(tester, adapter);
    await tester.tap(find.text('SHA-256'));
    await tester.pumpAndSettle();
    expect(adapter.requests, hasLength(1));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    answered.complete();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SnackBar, 'Server error (500)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
