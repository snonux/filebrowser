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

class MutableSession extends SessionController {
  MutableSession(this.initial);
  final Session initial;
  @override
  Future<Session?> build() async => initial;
  void change(Session? session) => state = AsyncData(session);
}

void main() {
  final item = FileItem(
      path: '/report.txt',
      name: 'report.txt',
      size: 4,
      modified: DateTime(2026),
      isDir: false,
      type: 'text');
  for (final logout in [true, false]) {
    for (final action in ['New folder', 'New file', 'Rename', 'Delete']) {
      testWidgets(
          '$action captures account before dialog; ${logout ? 'logout' : 'switch'} cancels',
          (tester) async {
        final oldAdapter = FakeAdapter((_) => reply(200));
        final newAdapter = FakeAdapter((_) => reply(200));
        Session session(FakeAdapter adapter, String name) => Session(
            api: FileBrowserApi(
                baseUrl: 'http://$name.local',
                dio: Dio()..httpClientAdapter = adapter)
              ..token = '$name.token.sig',
            user: UserInfo(id: 1, username: name, perm: const Permissions()));
        final alice = session(oldAdapter, 'alice'),
            bob = session(newAdapter, 'bob');
        final sessions = MutableSession(alice);
        final container = ProviderContainer(
            overrides: [sessionProvider.overrideWith(() => sessions)]);
        await container.read(sessionProvider.future);
        addTearDown(() {
          container.dispose();
          alice.api.dio.close(force: true);
          bob.api.dio.close(force: true);
        });
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
                scaffoldMessengerKey: appMessengerKey,
                home: Scaffold(
                    body: Builder(
                        builder: (context) => TextButton(
                              child: const Text('Start'),
                              onPressed: () {
                                final actions = FileActions(context);
                                switch (action) {
                                  case 'New folder':
                                    actions.createFolder(context, '/');
                                  case 'New file':
                                    actions.createFile(context, '/');
                                  case 'Rename':
                                    actions.rename(context, item);
                                  case 'Delete':
                                    actions.delete(context, [item]);
                                }
                              },
                            ))))));
        await tester.tap(find.text('Start'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        sessions.change(logout ? null : bob);
        if (action != 'Delete') {
          await tester.enterText(find.byType(TextField), 'new.txt');
        }
        await tester.tap(find.widgetWithText(
            FilledButton,
            switch (action) {
              'New folder' || 'New file' => 'Create',
              'Rename' => 'Rename',
              _ => 'Delete',
            }));
        await tester.pumpAndSettle();
        expect(oldAdapter.requests, isEmpty);
        expect(newAdapter.requests, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
