// End-to-end test against a real File Browser server.
//
// Run it with test/e2e/run_e2e.sh, which builds and seeds the server, starts
// a basic-auth proxy in front of it and passes the addresses below. It drives
// the real UI and checks every result on the server through the API.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/app.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/providers/device_files_provider.dart';
import 'package:filebrowser_android/providers/preferences_provider.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/services/credential_store.dart';
import 'package:filebrowser_android/services/device_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const serverUrl = String.fromEnvironment('FB_E2E_URL');
const proxyUrl = String.fromEnvironment('FB_E2E_PROXY_URL');
const adminPass = String.fromEnvironment('FB_E2E_ADMIN_PASS');
const viewerPass = String.fromEnvironment('FB_E2E_VIEWER_PASS');
const proxyUser = String.fromEnvironment('FB_E2E_PROXY_USER');
const proxyPass = String.fromEnvironment('FB_E2E_PROXY_PASS');

/// When set, screenshots of the main screens are written to this directory.
const shotsDir = String.fromEnvironment('FB_E2E_SHOTS');
final _shotKey = GlobalKey();

/// Stands in for Android's document picker and "open with" chooser.
class FakeDeviceFiles implements DeviceFiles {
  FakeDeviceFiles(this.dir);

  final Directory dir;
  List<File> nextPick = [];
  final opened = <File>[];

  @override
  Future<List<File>> pickFiles() async {
    final picked = nextPick;
    nextPick = [];
    return picked;
  }

  @override
  Future<Directory> downloadDirectory() async =>
      Directory('${dir.path}/downloads')..createSync(recursive: true);

  @override
  Future<String?> open(File file) async {
    opened.add(file);
    return null;
  }
}

late SharedPreferences prefs;
late MemoryCredentialStore store;
late FakeDeviceFiles device;
late FileBrowserApi admin;

Future<void> launch(WidgetTester tester) async {
  // Lay the app out like a phone (1080x2340 at 420 dpi).
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      credentialStoreProvider.overrideWithValue(store),
      deviceFilesProvider.overrideWithValue(device),
    ],
    child: RepaintBoundary(key: _shotKey, child: const FileBrowserApp()),
  ));
  await tester.pump();
}

/// Saves what is on screen as `<shotsDir>/<name>.png`.
Future<void> screenshot(WidgetTester tester, String name) async {
  if (shotsDir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 500));
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image =
      await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$shotsDir/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

/// Pumps frames until [finder] matches (real network calls take a while).
Future<void> waitFor(WidgetTester tester, Finder finder,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  final texts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .join(' | ');
  final fields = find
      .byType(EditableText)
      .evaluate()
      .map((e) => (e.widget as EditableText).controller.text)
      .join(' | ');
  throw TestFailure('Timed out waiting for $finder\n'
      'Visible texts: $texts\nText fields: $fields');
}

Future<void> waitUntil(
    WidgetTester tester, Future<bool> Function() check, String what,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (await check()) return;
  }
  throw TestFailure('Timed out waiting until $what');
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await waitFor(tester, finder);
  // Menus and dialogs animate in; tap once they are in place.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  // Let route and sheet transitions finish so covered screens go offstage.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> back(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Swipes [finder] to the left like a finger does, in many small moves.
///
/// `tester.drag` jumps past the touch slop in a single move. Android reports
/// its own, smaller slops (8 px to start a drag, 16 px to start a pan), so
/// that jump crosses both at once and the image viewer's InteractiveViewer
/// wins the gesture over the PageView around it. Small moves cross the drag
/// slop first, as a real swipe does.
Future<void> swipeLeft(WidgetTester tester, Finder finder,
    {double distance = 700}) async {
  const step = 5.0;
  final gesture = await tester.startGesture(tester.getCenter(finder));
  for (var moved = 0.0; moved < distance; moved += step) {
    await gesture.moveBy(const Offset(-step, 0));
  }
  await gesture.up();
}

void closeDrawer(WidgetTester tester) =>
    tester.state<ScaffoldState>(find.byType(Scaffold).last).closeDrawer();

/// Waits until [count] images have actually been decoded and painted.
Future<void> waitForImages(WidgetTester tester, int count) => waitUntil(
    tester,
    () async =>
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((r) => r.image != null)
            .length ==
        count,
    '$count images shown');

Future<void> tapText(WidgetTester tester, String text) =>
    tap(tester, find.text(text));

Future<void> enter(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextField, label);
  await waitFor(tester, field);
  await tester.enterText(field.first, text);
  await tester.pump();
}

/// Opens the ⋮ menu of [name] and taps [action].
Future<void> itemAction(WidgetTester tester, String name, String action) async {
  await tap(tester, find.byTooltip('Actions for $name'));
  await tapText(tester, action);
}

Future<void> login(WidgetTester tester,
    {required String url,
    required String user,
    required String password,
    bool stay = true}) async {
  await waitFor(tester, find.text('Sign in'));
  await enter(tester, 'Server address', url);
  await enter(tester, 'Username', user);
  await enter(tester, 'Password', password);
  final stayTile = find.widgetWithText(SwitchListTile, 'Stay signed in');
  if (tester.widget<SwitchListTile>(stayTile).value != stay) {
    await tap(tester, stayTile);
  }
  await tapText(tester, 'Sign in');
}

Future<bool> exists(String path) async {
  try {
    await admin.fetch(path);
    return true;
  } on ApiException catch (e) {
    if (e.statusCode == 404) return false;
    rethrow;
  }
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    expect(serverUrl, isNotEmpty, reason: 'Run via test/e2e/run_e2e.sh');
    admin = FileBrowserApi(baseUrl: serverUrl);
    await admin.login('admin', adminPass);
    device = FakeDeviceFiles(await Directory.systemTemp.createTemp('fb-e2e'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = MemoryCredentialStore();
  });

  testWidgets('login, browse and every file operation', (tester) async {
    await launch(tester);

    // -- Login errors ---------------------------------------------------------
    await login(tester,
        url: serverUrl, user: 'admin', password: 'wrong-password');
    await waitFor(tester, find.text('Wrong username or password'));
    await screenshot(tester, '1-login');
    await login(tester, url: proxyUrl, user: 'admin', password: adminPass);
    await waitFor(tester, find.textContaining('Turn on "Proxy login"'));

    // -- Login and listing ----------------------------------------------------
    await login(tester, url: serverUrl, user: 'admin', password: adminPass);
    await waitFor(tester, find.text('readme.md'));
    expect(find.text('photos'), findsOneWidget);
    expect(find.text('projects'), findsOneWidget);
    expect(find.text('.hidden'), findsOneWidget);
    expect((await store.read()).password, adminPass);
    final loginToken = (await store.read()).token;

    // Hidden files toggle.
    await tap(tester, find.byTooltip('More'));
    await tap(tester, find.byType(CheckedPopupMenuItem<String>));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('.hidden'), findsNothing);
    await tap(tester, find.byTooltip('More'));
    await tap(tester, find.byType(CheckedPopupMenuItem<String>));
    await waitFor(tester, find.text('.hidden'));

    // Sorting: name descending puts zz-last.txt before readme.md, folders
    // stay on top.
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('readme.md'), lessThan(y('zz-last.txt')));
    await tap(tester, find.byTooltip('Sort'));
    await tapText(tester, 'Name');
    await tester.pump(const Duration(milliseconds: 300));
    expect(y('zz-last.txt'), lessThan(y('readme.md')));
    expect(y('projects'), lessThan(y('zz-last.txt')));
    await tap(tester, find.byTooltip('Sort'));
    await tapText(tester, 'Name');

    await screenshot(tester, '2-home');
    // Disk usage in the drawer.
    await tap(tester, find.byTooltip('Open navigation menu'));
    await waitFor(tester, find.textContaining(' used'));
    closeDrawer(tester);
    await tester.pump(const Duration(milliseconds: 500));

    // -- Create a folder and a text file --------------------------------------
    await tap(tester, find.byTooltip('Add'));
    await tapText(tester, 'New folder');
    await enter(tester, 'Name', 'Docs');
    await tapText(tester, 'Create');
    await waitFor(tester, find.text('Docs'));
    expect((await admin.fetch('/Docs')).item.isDir, isTrue);

    await tapText(tester, 'Docs');
    await waitFor(tester, find.text('This folder is empty'));
    await tap(tester, find.byTooltip('Add'));
    await tapText(tester, 'New file');
    await enter(tester, 'Name', 'notes.txt');
    await tapText(tester, 'Create');
    await waitFor(tester, find.byTooltip('Save'));
    await tester.enterText(find.byType(TextField), 'hello from android');
    await tester.pump();
    await screenshot(tester, '5-editor');
    await tap(tester, find.byTooltip('Save'));
    await waitFor(tester, find.text('Saved'));
    expect((await admin.fetch('/Docs/notes.txt')).item.content,
        'hello from android');
    await back(tester);
    await waitFor(tester, find.text('notes.txt'));

    // -- Uploads (tus) --------------------------------------------------------
    final rng = Random(42);
    final small = File('${device.dir.path}/small.bin')
      ..writeAsBytesSync(List.generate(1000, (_) => rng.nextInt(256)));
    // 25 MB: three tus chunks of 10 MB.
    final bigBytes = Uint8List(25 * 1024 * 1024 + 123);
    for (var i = 0; i < bigBytes.length; i += 4096) {
      bigBytes[i] = rng.nextInt(256);
    }
    final big = File('${device.dir.path}/big.bin')..writeAsBytesSync(bigBytes);
    device.nextPick = [small, big];
    await tap(tester, find.byTooltip('Add'));
    await tapText(tester, 'Upload files');
    await waitFor(tester, find.text('2 transfers finished'),
        timeout: const Duration(minutes: 2));
    expect(find.text('big.bin'), findsOneWidget);
    expect(await admin.checksum('/Docs/small.bin', 'sha256'),
        sha256Of(small.readAsBytesSync()));
    expect(await admin.checksum('/Docs/big.bin', 'sha256'), sha256Of(bigBytes));
    await tap(tester, find.byTooltip('Dismiss'));

    // Uploading the same name again asks before replacing.
    small.writeAsStringSync('replaced');
    device.nextPick = [small];
    await tap(tester, find.byTooltip('Add'));
    await tapText(tester, 'Upload files');
    await waitFor(tester, find.text('"small.bin" exists'));
    await tapText(tester, 'Replace');
    await waitFor(tester, find.text('1 transfer finished'));
    expect(await admin.checksum('/Docs/small.bin', 'sha256'),
        sha256Of(small.readAsBytesSync()));
    await tap(tester, find.byTooltip('Dismiss'));

    // -- Rename, copy, move ---------------------------------------------------
    const odd = 'a+b %20 c#1.bin';
    await itemAction(tester, 'small.bin', 'Rename');
    await enter(tester, 'Name', odd);
    await tap(tester, find.widgetWithText(FilledButton, 'Rename'));
    await waitFor(tester, find.text(odd));
    expect(await exists('/Docs/$odd'), isTrue);
    expect(await exists('/Docs/small.bin'), isFalse);

    await itemAction(tester, odd, 'Copy to…');
    await tapText(tester, 'Parent folder');
    await tapText(tester, 'Copy here');
    await waitFor(tester, find.textContaining('Copied 1 item'));
    expect(await exists('/$odd'), isTrue);
    expect(await exists('/Docs/$odd'), isTrue);

    await itemAction(tester, 'big.bin', 'Move to…');
    await tapText(tester, 'Parent folder');
    await tapText(tester, 'projects');
    await tapText(tester, 'Move here');
    await waitFor(tester, find.textContaining('Moved 1 item'));
    expect(await exists('/projects/big.bin'), isTrue);
    expect(await exists('/Docs/big.bin'), isFalse);
    expect(find.text('big.bin'), findsNothing);

    // -- Multi-select delete --------------------------------------------------
    await tester.longPress(find.text('notes.txt'));
    await tester.pump();
    await tapText(tester, odd);
    expect(find.text('2 selected'), findsOneWidget);
    await tap(tester, find.byTooltip('Delete'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await waitFor(tester, find.text('This folder is empty'));
    expect(await exists('/Docs/notes.txt'), isFalse);
    expect(await exists('/Docs/$odd'), isFalse);

    // Back home through the breadcrumbs; delete the copy there.
    await tapText(tester, 'Home');
    await waitFor(tester, find.text(odd));
    await itemAction(tester, odd, 'Delete');
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await waitUntil(tester, () async => !await exists('/$odd'), 'copy deleted');

    // -- Info and checksum ----------------------------------------------------
    await itemAction(tester, 'readme.md', 'Info');
    await tapText(tester, 'SHA-256');
    await waitFor(
        tester, find.text(await admin.checksum('/readme.md', 'sha256')));
    await tapText(tester, 'Close');

    // -- Images: thumbnails and the viewer ------------------------------------
    await tapText(tester, 'photos');
    await waitFor(tester, find.text('red.png'));
    await waitForImages(tester, 2);
    await screenshot(tester, '3-photos');
    await tapText(tester, 'blue.png');
    await waitFor(tester, find.text('1 / 2'));
    await waitForImages(tester, 1);
    await screenshot(tester, '4-viewer');
    await swipeLeft(tester, find.byType(PageView));
    await waitFor(tester, find.text('2 / 2'));
    expect(find.text('red.png'), findsOneWidget);
    await back(tester);
    await waitFor(tester, find.text('red.png'));

    // -- Downloads ------------------------------------------------------------
    await back(tester);
    await waitFor(tester, find.text('readme.md'));
    await itemAction(tester, 'readme.md', 'Download');
    final readme = File('${device.dir.path}/downloads/readme.md');
    await waitUntil(
        tester, () async => readme.existsSync(), 'readme downloaded');
    await waitFor(tester, find.textContaining('Saved readme.md'));
    expect(readme.readAsStringSync(), contains('Seeded by the e2e test.'));

    await itemAction(tester, 'photos', 'Download as zip');
    final zip = File('${device.dir.path}/downloads/photos.zip');
    await waitFor(tester, find.textContaining('Saved photos.zip'));
    expect(zip.readAsBytesSync().sublist(0, 2), [0x50, 0x4b]); // "PK"

    // Tapping a file the app cannot show downloads it and opens it elsewhere.
    await tapText(tester, 'projects');
    await tapText(tester, 'big.bin');
    await waitUntil(
        tester, () async => device.opened.isNotEmpty, 'big.bin opened');
    expect(device.opened.single.path, endsWith('/downloads/big.bin'));
    expect(
        sha256Of(device.opened.single.readAsBytesSync()), sha256Of(bigBytes));
    await back(tester);
    await waitFor(tester, find.text('readme.md'));

    // -- Search ---------------------------------------------------------------
    await tap(tester, find.byTooltip('Search'));
    await tester.enterText(find.byType(TextField), 'data');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await waitFor(tester, find.text('projects/app/data.bin'));
    // Submitting unfocused the field; focus it again before typing.
    await tap(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'readme');
    await tap(tester, find.byTooltip('Search'));
    await waitFor(tester, find.text('readme.md'));
    await tapText(tester, 'readme.md');
    await waitFor(tester, find.textContaining('Seeded by the e2e test.'));
    await back(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await back(tester);
    await waitFor(tester, find.text('zz-last.txt'));

    // -- Share links ----------------------------------------------------------
    await itemAction(tester, 'readme.md', 'Share link');
    await enter(tester, 'Expires after', '2');
    await screenshot(tester, '6-share');
    await tapText(tester, 'Create link');
    // The dialog returns to the item's links; the new one is in the clipboard
    // and points at the server address the app signed in to. The link is
    // listed before it is copied, so wait for the message that it was.
    await waitFor(tester, find.text('New link'));
    await waitFor(tester, find.text('Link created and copied'));
    final link = (await Clipboard.getData('text/plain'))!.text!;
    expect(link, startsWith('$serverUrl/share/'));
    expect(find.text(link), findsOneWidget);
    final hash = link.split('/').last;
    final public = await HttpClient()
        .getUrl(Uri.parse('$serverUrl/api/public/share/$hash'))
        .then((r) => r.close());
    expect(public.statusCode, 200);
    await public.drain<void>();

    // The download link serves the file itself, without signing in.
    await tap(tester, find.byTooltip('Copy download link for $hash'));
    // The message appears once the copy is done.
    await waitFor(tester, find.text('Download link copied'));
    final direct = (await Clipboard.getData('text/plain'))!.text!;
    expect(direct, '$serverUrl/api/public/dl/$hash?inline=true');
    final served =
        await HttpClient().getUrl(Uri.parse(direct)).then((r) => r.close());
    expect(served.statusCode, 200);
    expect(await served.transform(utf8.decoder).join(),
        contains('Seeded by the e2e test.'));
    await tapText(tester, 'Close');

    // Sharing the same file again lists the link instead of the empty form.
    await itemAction(tester, 'readme.md', 'Share link');
    await waitFor(tester, find.text(link));
    await tapText(tester, 'Close');

    // A folder is shared under the path the web UI uses for it, with a
    // trailing slash, so that both list the same links for it.
    await itemAction(tester, 'photos', 'Share link');
    await tapText(tester, 'Create link');
    await waitFor(tester, find.text('New link'));
    await waitFor(tester, find.text('Link created and copied'));
    expect((await admin.shares()).map((s) => s.path), contains('/photos/'));
    final folderHash =
        (await Clipboard.getData('text/plain'))!.text!.split('/').last;
    // Both public addresses of the folder work: its page and its archive.
    for (final address in [
      '$serverUrl/api/public/share/$folderHash',
      '$serverUrl/api/public/dl/$folderHash?inline=true',
    ]) {
      final answer =
          await HttpClient().getUrl(Uri.parse(address)).then((r) => r.close());
      expect(answer.statusCode, 200, reason: address);
      await answer.drain<void>();
    }
    // Deleting the folder's only link leaves the form, which Cancel closes.
    await tap(tester, find.byTooltip('Delete link for $folderHash'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await waitFor(tester, find.text('Create link'));
    await tapText(tester, 'Cancel');

    await tap(tester, find.byTooltip('Open navigation menu'));
    await tapText(tester, 'Share links');
    await waitFor(tester, find.text('/readme.md'));
    expect(find.textContaining('Expires'), findsOneWidget);
    await tap(tester, find.byTooltip('Delete link for /readme.md'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await waitFor(tester, find.text('No share links'));
    expect(await admin.shares(), isEmpty);
    await back(tester);

    // -- Settings -------------------------------------------------------------
    await tap(tester, find.byTooltip('Open navigation menu'));
    await tapText(tester, 'Settings');
    await tapText(tester, 'Dark');
    await tester.pump(const Duration(milliseconds: 500));
    await screenshot(tester, '7-settings-dark');
    expect(Theme.of(tester.element(find.text('Settings'))).brightness,
        Brightness.dark);
    expect(prefs.getString('themeMode'), 'dark');

    // The server asks for renewal on every response (50 minute tokens), so
    // the app has swapped the login token for a renewed one by now.
    final renewed = (await store.read()).token!;
    expect(renewed, isNot(loginToken));
    expect(TokenClaims.parse(renewed).user.username, 'admin');

    // -- Session restore across an app restart --------------------------------
    final tokenBefore = (await store.read()).token;
    await launch(tester);
    await waitFor(tester, find.text('readme.md'));
    expect((await store.read()).token, isNotNull);
    expect(tokenBefore, isNotNull);

    // A token the server rejects is replaced by logging in again with the
    // remembered password.
    final bad = '${tokenBefore!.substring(0, tokenBefore.length - 4)}AAAA';
    await store.writeToken(bad);
    await launch(tester);
    await waitFor(tester, find.text('readme.md'));
    await waitUntil(tester, () async => (await store.read()).token != bad,
        'token replaced');

    // -- Log out --------------------------------------------------------------
    await tap(tester, find.byTooltip('Open navigation menu'));
    await tapText(tester, 'Settings');
    await tapText(tester, 'Log out');
    await tap(tester, find.widgetWithText(FilledButton, 'Log out'));
    await waitFor(tester, find.text('Sign in'));
    expect((await store.read()).token, isNull);
    expect((await store.read()).password, isNull);
  });

  testWidgets('expired session without a saved password returns to login',
      (tester) async {
    await launch(tester);
    await login(tester,
        url: serverUrl, user: 'admin', password: adminPass, stay: false);
    await waitFor(tester, find.text('readme.md'));
    expect((await store.read()).password, isNull);
    final token = (await store.read()).token!;
    await store.writeToken('${token.substring(0, token.length - 4)}AAAA');
    await launch(tester);
    await waitFor(tester, find.text('Sign in'));
  });

  testWidgets('read-only account sees no write actions', (tester) async {
    await launch(tester);
    await login(tester, url: serverUrl, user: 'viewer', password: viewerPass);
    await waitFor(tester, find.text('readme.md'));
    expect(find.byTooltip('Add'), findsNothing);
    await tap(tester, find.byTooltip('Actions for readme.md'));
    await waitFor(tester, find.text('Download'));
    for (final action in [
      'Rename',
      'Copy to…',
      'Move to…',
      'Share link',
      'Delete'
    ]) {
      expect(find.text(action), findsNothing, reason: action);
    }
    expect(find.text('Info'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));

    // Opening a text file is read-only.
    await tapText(tester, 'readme.md');
    await waitFor(tester, find.textContaining('Seeded by the e2e test.'));
    expect(find.byTooltip('Save'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
  });

  testWidgets('through a basic-auth reverse proxy', (tester) async {
    await launch(tester);
    await waitFor(tester, find.text('Sign in'));
    await tap(tester, find.widgetWithText(SwitchListTile, 'Proxy login'));
    await enter(tester, 'Proxy username', proxyUser);
    await enter(tester, 'Proxy password', 'wrong');
    await login(tester, url: proxyUrl, user: 'admin', password: adminPass);
    await waitFor(
        tester, find.text('The proxy rejected its username or password'));

    await enter(tester, 'Proxy password', proxyPass);
    await login(tester, url: proxyUrl, user: 'admin', password: adminPass);
    await waitFor(tester, find.text('readme.md'));
    expect(prefs.getString('proxyUsername'), proxyUser);
    expect((await store.read()).proxyPassword, proxyPass);

    // Thumbnails carry the proxy credentials too.
    await tapText(tester, 'photos');
    await waitForImages(tester, 2);

    // Uploads go through the proxy.
    final file = File('${device.dir.path}/via-proxy.txt')
      ..writeAsStringSync('through the proxy');
    device.nextPick = [file];
    await tap(tester, find.byTooltip('Add'));
    await tapText(tester, 'Upload files');
    await waitFor(tester, find.text('1 transfer finished'));
    expect((await admin.fetch('/photos/via-proxy.txt')).item.content,
        'through the proxy');
    await admin.delete('/photos/via-proxy.txt');
  });
}
