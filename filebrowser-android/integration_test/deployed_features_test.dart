// Additional native GUI checks for a seeded deployed server. Run with the
// same FB_E2E_* defines as app_test.dart; media/clip.mp4 is also required.
import 'dart:io';

import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/services/credential_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'app_test.dart' as e2e;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  setUpAll(() async {
    e2e.admin = FileBrowserApi(baseUrl: e2e.serverUrl);
    await e2e.admin.login(e2e.adminUser, e2e.adminPass);
    e2e.device = e2e.FakeDeviceFiles(
        await Directory.systemTemp.createTemp('fb-deployed-extra'));
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    e2e.prefs = await SharedPreferences.getInstance();
    e2e.store = MemoryCredentialStore();
  });
  Future<void> signIn(WidgetTester tester) async {
    await e2e.launch(tester);
    await e2e.login(tester,
        url: e2e.serverUrl, user: e2e.adminUser, password: e2e.adminPass);
    await e2e.waitFor(tester, find.text('readme.md'));
  }

  testWidgets('protected share validates lifetime and disables direct copying',
      (tester) async {
    for (final share in await e2e.admin.sharesFor('/readme.md')) {
      await e2e.admin.deleteShare(share.hash);
    }
    await signIn(tester);
    await e2e.itemAction(tester, 'readme.md', 'Share link');
    await e2e.enter(tester, 'Expires after', '-1');
    await e2e.tapText(tester, 'Create link');
    await e2e.waitFor(tester, find.textContaining('Enter a whole number'));
    await e2e.enter(tester, 'Expires after', '1');
    await e2e.tap(tester, find.byType(DropdownButton<String>));
    await e2e.tapText(tester, 'days');
    await e2e.enter(tester, 'Password (optional)', 'Protected-native-123!');
    await e2e.tapText(tester, 'Create link');
    await e2e.waitFor(tester, find.text('New link'));
    final shares = await e2e.admin.sharesFor('/readme.md');
    final share = shares.single;
    expect(share.hasPassword, isTrue);
    expect(share.expiresAt!.difference(DateTime.now()).inHours,
        greaterThanOrEqualTo(23));
    final protectedCopy =
        find.byTooltip('No download link for ${share.hash}: it has a password');
    await e2e.waitFor(tester, protectedCopy);
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: protectedCopy, matching: find.byType(IconButton)))
            .onPressed,
        isNull);
    await e2e.screenshot(tester, 'extra-protected-share');
    await e2e.tap(tester, find.byTooltip('Delete link for ${share.hash}'));
    await e2e.tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await e2e.waitFor(tester, find.text('Create link'));
    expect(await e2e.admin.sharesFor('/readme.md'), isEmpty);
  });

  testWidgets('multi-select copy, move conflicts and cancelled delete',
      (tester) async {
    final folder = '/Extra-${DateTime.now().millisecondsSinceEpoch}';
    await e2e.admin.createFolder('$folder/source');
    await e2e.admin.createFolder('$folder/destination');
    for (final name in ['one.txt', 'two.txt']) {
      await e2e.admin
          .createFile('$folder/source/$name', content: name.codeUnits);
    }
    await signIn(tester);
    await e2e.tapText(tester, folder.substring(1));
    await e2e.tapText(tester, 'source');
    await e2e.waitFor(tester, find.text('one.txt'));
    await tester.longPress(find.text('one.txt'));
    await tester.pump();
    await e2e.tap(tester, find.byTooltip('Select all'));
    await e2e.waitFor(tester, find.text('2 selected'));
    await e2e.tap(tester, find.byTooltip('Delete'));
    await e2e.tapText(tester, 'Cancel');
    expect(await e2e.exists('$folder/source/one.txt'), isTrue);
    expect(await e2e.exists('$folder/source/two.txt'), isTrue);
    await e2e.tap(tester, find.byTooltip('Copy to'));
    await e2e.tapText(tester, 'Parent folder');
    await e2e.tapText(tester, 'destination');
    await e2e.tapText(tester, 'Copy here');
    await e2e.waitFor(tester, find.textContaining('Copied 2 items'));
    for (final name in ['one.txt', 'two.txt']) {
      expect((await e2e.admin.fetch('$folder/destination/$name')).item.content,
          name);
      expect(await e2e.exists('$folder/source/$name'), isTrue);
    }
    await e2e.waitFor(tester, find.byTooltip('Actions for one.txt'));
    await e2e.itemAction(tester, 'one.txt', 'Move to…');
    await e2e.tapText(tester, 'Parent folder');
    await e2e.tapText(tester, 'destination');
    await e2e.tapText(tester, 'Move here');
    await e2e.waitFor(tester, find.text('"one.txt" exists'));
    await e2e.tapText(tester, 'Cancel');
    expect(await e2e.exists('$folder/source/one.txt'), isTrue);
    await e2e.itemAction(tester, 'one.txt', 'Move to…');
    await e2e.tapText(tester, 'Parent folder');
    await e2e.tapText(tester, 'destination');
    await e2e.tapText(tester, 'Move here');
    await e2e.tapText(tester, 'Replace');
    await e2e.waitUntil(tester,
        () async => !await e2e.exists('$folder/source/one.txt'), 'file moved');
    expect((await e2e.admin.fetch('$folder/destination/one.txt')).item.content,
        'one.txt');
    await e2e.screenshot(tester, 'extra-file-operations');
    await e2e.admin.delete(folder);
  });

  testWidgets('sorting, pull refresh, themes and editor discard',
      (tester) async {
    await signIn(tester);
    await e2e.tap(tester, find.byTooltip('Sort'));
    await e2e.tapText(tester, 'Size');
    expect(tester.getTopLeft(find.text('zz-last.txt')).dy,
        lessThan(tester.getTopLeft(find.text('readme.md')).dy));
    await e2e.tap(tester, find.byTooltip('Sort'));
    await e2e.tapText(tester, 'Last modified');
    await e2e.tap(tester, find.byTooltip('Sort'));
    await e2e.tapText(tester, 'Name');
    await e2e.admin.createFile('/aa-refresh.txt', content: [65]);
    expect(find.text('aa-refresh.txt'), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, 450));
    await e2e.waitFor(tester, find.text('aa-refresh.txt'));
    await e2e.admin.delete('/aa-refresh.txt');
    await e2e.tapText(tester, 'readme.md');
    await e2e.waitFor(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'unsaved text');
    await tester.pump();
    await e2e.back(tester);
    await e2e.waitFor(tester, find.text('Save changes?'));
    await e2e.tapText(tester, 'Cancel');
    expect(find.byType(TextField), findsOneWidget);
    await e2e.back(tester);
    await e2e.tapText(tester, 'Discard');
    expect((await e2e.admin.fetch('/readme.md')).item.content,
        contains('Seeded by the e2e test.'));
    await e2e.tap(tester, find.byTooltip('Open navigation menu'));
    await e2e.tapText(tester, 'Settings');
    for (final label in ['Dark', 'Light', 'System']) {
      await e2e.tapText(tester, label);
      await tester.pump(const Duration(milliseconds: 300));
      if (label != 'System') {
        expect(Theme.of(tester.element(find.text('Settings'))).brightness,
            label == 'Dark' ? Brightness.dark : Brightness.light);
      }
    }
    await e2e.waitFor(tester, find.text('Version'));
    await e2e.screenshot(tester, 'extra-settings');
  });

  testWidgets('native video controls and PDF page navigation', (tester) async {
    await signIn(tester);
    await e2e.tapText(tester, 'media');
    await e2e.tapText(tester, 'clip.mp4');
    await e2e.waitFor(tester, find.byTooltip('Pause').hitTestable());
    final player = tester
        .widget<VideoProgressIndicator>(find.byType(VideoProgressIndicator))
        .controller;
    await e2e.waitUntil(tester, () async {
      final position = await player.position;
      return position != null && position.inMilliseconds > 200;
    }, 'native video advances');
    await e2e.tap(tester, find.byTooltip('Pause').hitTestable());
    final before = (await player.position)!;
    await e2e.tap(tester, find.byTooltip('Forward 10 seconds'));
    await e2e.waitUntil(
        tester,
        () async =>
            (await player.position)! > before + const Duration(seconds: 9),
        'forward seek reaches native player');
    await e2e.tap(tester, find.byTooltip('Back 10 seconds'));
    await e2e.waitUntil(
        tester,
        () async =>
            (await player.position)! < before + const Duration(seconds: 2),
        'backward seek reaches native player');
    await e2e.tap(tester, find.byTooltip('Play').hitTestable());
    expect(player.value.isPlaying, isTrue);
    await e2e.screenshot(tester, 'extra-video');
    await e2e.back(tester);
    await e2e.tapText(tester, 'guide.pdf');
    await e2e.waitFor(tester, find.text('1 / 2'));
    final pdf = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await e2e.waitUntil(tester, () async => pdf.isReady, 'PDF viewer ready');
    await e2e.screenshot(tester, 'extra-pdf-before');
    // This short fixture leaves both pages partly visible at fit width.
    // Pinch like a reader would, then scroll until page two is current.
    final pdfCenter = tester.getCenter(find.byType(PdfViewer));
    final initialZoom = pdf.currentZoom;
    final zoomLeft =
        await tester.startGesture(pdfCenter - const Offset(30, 0), pointer: 3);
    final zoomRight =
        await tester.startGesture(pdfCenter + const Offset(30, 0), pointer: 4);
    for (var i = 0; i < 20; i++) {
      await zoomLeft.moveBy(const Offset(-3, 0));
      await zoomRight.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await zoomLeft.up();
    await zoomRight.up();
    await tester.pump();
    expect(pdf.currentZoom, greaterThan(initialZoom * 1.2));
    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PdfViewer)) + const Offset(0, 200));
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    await e2e.screenshot(tester, 'extra-pdf-after');
    await e2e.waitFor(tester, find.text('2 / 2'));
    await e2e.screenshot(tester, 'extra-pdf-page2');
  });

  testWidgets('image pinch zoom disables paging until zoomed out',
      (tester) async {
    await signIn(tester);
    await e2e.tapText(tester, 'photos');
    await e2e.tapText(tester, 'blue.png');
    await e2e.waitForImages(tester, 1);
    final viewer = find.byType(InteractiveViewer).first;
    final center = tester.getCenter(viewer);
    final left =
        await tester.startGesture(center - const Offset(30, 0), pointer: 1);
    final right =
        await tester.startGesture(center + const Offset(30, 0), pointer: 2);
    for (var i = 0; i < 20; i++) {
      await left.moveBy(const Offset(-3, 0));
      await right.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await left.up();
    await right.up();
    await tester.pump();
    final controller =
        tester.widget<InteractiveViewer>(viewer).transformationController!;
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.1));
    expect(tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>());
    await e2e.screenshot(tester, 'extra-image-zoom');
  });

  testWidgets('cancelled upload replacement, rename and checksum copying',
      (tester) async {
    const path = '/cancel-upload.txt';
    await e2e.admin.createFile(path, content: 'original bytes'.codeUnits);
    await signIn(tester);
    final picked = File('${e2e.device.dir.path}/cancel-upload.txt')
      ..writeAsStringSync('replacement bytes');
    e2e.device.nextPick = [picked];
    await e2e.tap(tester, find.byTooltip('Add'));
    await e2e.tapText(tester, 'Upload files');
    await e2e.waitFor(tester, find.text('"cancel-upload.txt" exists'));
    await e2e.tapText(tester, 'Cancel');
    await e2e.waitFor(tester, find.textContaining('Skipped'));
    expect((await e2e.admin.fetch(path)).item.content, 'original bytes');
    await e2e.tap(tester, find.byTooltip('Dismiss'));
    await e2e.itemAction(tester, 'cancel-upload.txt', 'Rename');
    await e2e.enter(tester, 'Name', 'renamed.txt');
    await e2e.tapText(tester, 'Cancel');
    expect(await e2e.exists('/renamed.txt'), isFalse);
    expect(await e2e.exists(path), isTrue);
    await e2e.itemAction(tester, 'cancel-upload.txt', 'Info');
    await e2e.tapText(tester, 'SHA-256');
    final checksum = await e2e.admin.checksum(path, 'sha256');
    await e2e.waitFor(tester, find.text(checksum));
    await e2e.tapText(tester, 'Copy checksum');
    expect((await Clipboard.getData('text/plain'))!.text, checksum);
    await e2e.tapText(tester, 'Close');
    await e2e.admin.delete(path);
  });
}
