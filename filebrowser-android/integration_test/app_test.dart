// End-to-end test against a real File Browser server.
//
// Run it with test/e2e/run_e2e.sh, which builds and seeds the server, starts
// a basic-auth proxy in front of it and passes the addresses below. It drives
// the real UI and checks every result on the server through the API.
import 'dart:async';
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
import 'package:filebrowser_android/providers/share_provider.dart';
import 'package:filebrowser_android/services/credential_store.dart';
import 'package:filebrowser_android/services/device_files.dart';
import 'package:filebrowser_android/services/share_receiver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const serverUrl = String.fromEnvironment('FB_E2E_URL');
const proxyUrl = String.fromEnvironment('FB_E2E_PROXY_URL');
const adminUser =
    String.fromEnvironment('FB_E2E_ADMIN_USER', defaultValue: 'admin');
const viewerUser =
    String.fromEnvironment('FB_E2E_VIEWER_USER', defaultValue: 'viewer');
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
  Future<Directory> offlineDirectory() async =>
      Directory('${dir.path}/offline')..createSync(recursive: true);

  @override
  Future<String?> open(File file) async {
    opened.add(file);
    return null;
  }
}

/// Stands in for Android's "Share" menu. Shares made before the app listens
/// wait for it, as a share that launches the app does.
class FakeShareReceiver implements ShareReceiver {
  final _queued = <SharedContent>[];
  final _controller = StreamController<SharedContent>.broadcast();

  @override
  Stream<SharedContent> get shares async* {
    while (_queued.isNotEmpty) {
      yield _queued.removeAt(0);
    }
    yield* _controller.stream;
  }

  void share(SharedContent content) =>
      _controller.hasListener ? _controller.add(content) : _queued.add(content);
}

/// A TCP forwarder to the server that can be shut, so the server looks
/// unreachable to the app (connections are refused) while the test still
/// talks to it directly.
class TcpGate {
  TcpGate._(this._target, ServerSocket listener)
      : _listener = listener,
        port = listener.port;

  final Uri _target;
  final int port;
  ServerSocket? _listener;
  final _sockets = <Socket>{};

  String get url => 'http://127.0.0.1:$port';

  static Future<TcpGate> start(Uri target) async {
    final gate = TcpGate._(
        target, await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    gate._serve();
    return gate;
  }

  void _serve() {
    _listener!.listen((client) async {
      _sockets.add(client);
      try {
        final upstream = await Socket.connect(_target.host, _target.port);
        _sockets.add(upstream);
        client.listen(upstream.add,
            onDone: upstream.destroy, onError: (_) => upstream.destroy());
        upstream.listen(client.add,
            onDone: client.destroy, onError: (_) => client.destroy());
      } on SocketException {
        client.destroy();
      }
    });
  }

  /// Refuses new connections and cuts the open ones.
  Future<void> shut() async {
    await _listener?.close();
    _listener = null;
    for (final s in _sockets) {
      s.destroy();
    }
    _sockets.clear();
  }

  /// Accepts connections again, on the same port.
  Future<void> open() async {
    _listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _serve();
  }

  Future<void> close() => shut();
}

late SharedPreferences prefs;
late MemoryCredentialStore store;
late FakeDeviceFiles device;
late FakeShareReceiver shares;
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
      shareReceiverProvider.overrideWithValue(shares),
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
  final fields = find.byType(EditableText).evaluate().map((e) {
    final field = e.widget as EditableText;
    return field.obscureText ? '[redacted]' : field.controller.text;
  }).join(' | ');
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
  WidgetController.hitTestWarningShouldBeFatal = true;

  setUpAll(() async {
    expect(serverUrl, isNotEmpty, reason: 'Run via test/e2e/run_e2e.sh');
    admin = FileBrowserApi(baseUrl: serverUrl);
    await admin.login(adminUser, adminPass);
    device = FakeDeviceFiles(await Directory.systemTemp.createTemp('fb-e2e'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = MemoryCredentialStore();
    shares = FakeShareReceiver();
  });

  testWidgets('login, browse and every file operation', (tester) async {
    await launch(tester);

    // -- Login errors ---------------------------------------------------------
    await login(tester,
        url: serverUrl, user: adminUser, password: 'wrong-password');
    await waitFor(tester, find.text('Wrong username or password'));
    await screenshot(tester, '1-login');
    await login(tester, url: proxyUrl, user: adminUser, password: adminPass);
    await waitFor(tester, find.textContaining('Turn on "Proxy login"'));

    // -- Login and listing ----------------------------------------------------
    await login(tester, url: serverUrl, user: adminUser, password: adminPass);
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

    // -- PDF viewer and media player ------------------------------------------
    await tapText(tester, 'media');
    await tapText(tester, 'guide.pdf');
    await waitFor(tester, find.text('1 / 2'));
    await screenshot(tester, '8-pdf');
    await back(tester);
    // Action snackbars can remain visible with accessibility navigation.
    // Dismiss the download notification using its normal swipe gesture so it
    // does not cover the player's bottom controls.
    final notification = find.byType(SnackBar);
    if (notification.evaluate().isNotEmpty) {
      await tester.drag(notification, const Offset(0, 200));
      await waitUntil(tester, () async => notification.evaluate().isEmpty,
          'download notification dismissed');
    }
    await tapText(tester, 'tone.wav');
    if (Platform.isLinux) {
      // video_player has no Linux implementation, so the desktop build shows
      // the fallback, which hands the file to another app.
      await waitFor(tester, find.text('This file cannot be played here.'));
      await tapText(tester, 'Open with another app');
      await waitUntil(
          tester, () async => device.opened.length == 2, 'tone.wav opened');
      expect(device.opened.last.path, endsWith('/downloads/tone.wav'));
    } else {
      // A download snackbar can still cover the bottom controls after navigation.
      // Wait for a hittable control, then verify the real plugin paused while
      // the fixture still has time left, rather than merely reaching its end.
      final pause = find.byTooltip('Pause').hitTestable();
      await waitFor(tester, pause);
      final player = tester
          .widget<VideoProgressIndicator>(find.byType(VideoProgressIndicator))
          .controller;
      expect(player.value.isPlaying, isTrue);
      final startPosition = await player.position;
      expect(startPosition, isNotNull);
      await waitUntil(tester, () async {
        final position = await player.position;
        return position != null &&
            position - startPosition! >= const Duration(milliseconds: 200);
      }, 'native audio playback advances', timeout: const Duration(seconds: 5));
      final playingPosition = await player.position;
      expect(playingPosition, isNotNull);
      expect(playingPosition,
          lessThan(player.value.duration - const Duration(seconds: 5)));
      await tap(tester, pause);
      await waitFor(tester, find.byTooltip('Play').hitTestable());
      expect(player.value.isPlaying, isFalse);
      expect(player.value.isCompleted, isFalse);
      // Query the native player: the Dart value is updated optimistically and
      // its position timer stops as soon as pause is requested.
      final pausedPosition = await player.position;
      expect(pausedPosition, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      final laterPosition = await player.position;
      expect(laterPosition, isNotNull);
      expect((laterPosition! - pausedPosition!).abs(),
          lessThanOrEqualTo(const Duration(milliseconds: 200)));
      expect(laterPosition,
          lessThan(player.value.duration - const Duration(seconds: 5)));
    }
    await back(tester);
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
    await tester.pumpAndSettle();

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
    expect(TokenClaims.parse(renewed).user.username, adminUser);

    // -- Session restore across an app restart --------------------------------
    final tokenBefore = (await store.read()).token;
    await launch(tester);
    await waitFor(tester, find.text('readme.md'));
    expect((await store.read()).token, isNotNull);
    expect(tokenBefore, isNotNull);

    // A token the server rejects is replaced by logging in again with the
    // remembered password.
    final bad = '${tokenBefore!.substring(0, tokenBefore.length - 4)}AAAA';
    // Dispose the old session before replacing its persisted token: an
    // in-flight renewal must not race the simulated restart.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
        url: serverUrl, user: adminUser, password: adminPass, stay: false);
    await waitFor(tester, find.text('readme.md'));
    expect((await store.read()).password, isNull);
    final token = (await store.read()).token!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await store.writeToken('${token.substring(0, token.length - 4)}AAAA');
    await launch(tester);
    await waitFor(tester, find.text('Sign in'));
  });

  testWidgets('files kept offline open without the server', (tester) async {
    // The app reaches the server through this forwarder, which the test
    // closes to make the server unreachable.
    final gate = await TcpGate.start(Uri.parse(serverUrl));
    addTearDown(gate.close);
    await admin.createFolder('/kept/sub/');
    addTearDown(() => admin.delete('/kept').catchError((Object _) {}));
    await admin.createFile('/kept/note.txt',
        content: utf8.encode('kept for the plane'));
    await admin.copy('/photos/red.png', '/kept/sub/pic.png');
    await admin.copy('/projects/app/data.bin', '/kept/sub/data.bin');

    await launch(tester);
    await login(tester, url: gate.url, user: adminUser, password: adminPass);
    await waitFor(tester, find.text('kept'));
    await itemAction(tester, 'kept', 'Make available offline');
    await waitFor(tester, find.text('kept is available offline'));
    await itemAction(tester, 'readme.md', 'Make available offline');
    await waitFor(tester, find.text('readme.md is available offline'));
    expect(find.byTooltip('Available offline'), findsNWidgets(2));
    // Inside a kept folder the menu says what keeps an item offline.
    await tapText(tester, 'kept');
    await itemAction(tester, 'note.txt', 'Available offline');
    expect(find.text('Kept with kept'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // Closes the menu.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await back(tester);

    // -- The server goes away -------------------------------------------------
    await gate.shut();
    await tap(tester, find.byTooltip('More'));
    await tapText(tester, 'Refresh');
    await waitFor(tester, find.textContaining('The server cannot be reached'));
    await screenshot(tester, '9-offline');
    expect(find.text('kept'), findsOneWidget);
    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('photos'), findsNothing);

    await tapText(tester, 'kept');
    await waitFor(tester, find.text('note.txt'));
    await tapText(tester, 'note.txt');
    await waitFor(tester, find.text('kept for the plane'));
    expect(find.textContaining('This is the offline copy'), findsOneWidget);
    await back(tester);

    await tapText(tester, 'sub');
    await waitFor(tester, find.text('data.bin'));
    await waitForImages(tester, 1); // The thumbnail, from the copy.
    await tapText(tester, 'data.bin');
    await waitUntil(tester, () async => device.opened.isNotEmpty,
        'the copy handed to another app');
    expect(sha256Of(device.opened.last.readAsBytesSync()),
        await admin.checksum('/kept/sub/data.bin', 'sha256'));
    await tapText(tester, 'pic.png');
    await waitFor(tester, find.text('1 / 1'));
    await waitForImages(tester, 1);
    await back(tester);

    // The list of everything kept, also without the server.
    await tapText(tester, 'Home');
    await tap(tester, find.byTooltip('Open navigation menu'));
    await tapText(tester, 'Available offline');
    await waitFor(tester, find.textContaining('4 files'));
    await tap(tester, find.byTooltip('Remove offline copy of readme.md'));
    await waitFor(tester, find.textContaining('3 files'));
    expect(find.text('readme.md'), findsNothing);
    await back(tester);

    // -- Back online: deleting a kept folder drops its copies ----------------
    await gate.open();
    await tap(tester, find.byTooltip('More'));
    await tapText(tester, 'Refresh');
    await waitFor(tester, find.text('photos'));
    expect(find.textContaining('The server cannot be reached'), findsNothing);
    await itemAction(tester, 'kept', 'Delete');
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await waitUntil(tester, () async => !await exists('/kept'), 'kept deleted');
    await tap(tester, find.byTooltip('Open navigation menu'));
    await tapText(tester, 'Available offline');
    await waitFor(tester, find.textContaining('Nothing is available offline'));
    final left = Directory('${device.dir.path}/offline')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => !f.path.endsWith('index.json'));
    expect(left, isEmpty);
  });

  testWidgets('files and text shared from other apps are uploaded',
      (tester) async {
    addTearDown(() async {
      for (final name in ['Trip plan.md', 'shared-a.txt', 'shared-b.bin']) {
        await admin.delete('/projects/$name').catchError((Object _) {});
      }
    });

    // -- Text shared while the app was closed, uploaded after sign-in -------
    const trip = '# Trip plan\n\n- [ ] book the train\n';
    shares.share(const SharedContent(text: trip));
    await launch(tester);
    await login(tester, url: serverUrl, user: adminUser, password: adminPass);
    await waitFor(tester, find.text('Upload to File Browser'));
    final name = find.widgetWithText(TextField, 'File name');
    expect(tester.widget<TextField>(name).controller!.text, 'Trip plan.md');
    await tapText(tester, 'Plain text');
    expect(tester.widget<TextField>(name).controller!.text, 'Trip plan.txt');
    await tapText(tester, 'Markdown');
    expect(tester.widget<TextField>(name).controller!.text, 'Trip plan.md');
    await screenshot(tester, '10-share-text');
    await tapText(tester, 'Upload to folder');
    await tapText(tester, 'projects');
    await tap(tester, find.widgetWithText(FilledButton, 'Upload here'));
    await tap(tester, find.widgetWithText(FilledButton, 'Upload'));
    await waitFor(tester, find.text('Trip plan.md'));
    expect((await admin.fetch('/projects/Trip plan.md')).item.content, trip);

    // -- Files shared while the app is open; the folder is remembered -------
    final dir = Directory('${device.dir.path}/shared')
      ..createSync(recursive: true);
    final a = File('${dir.path}/shared-a.txt')..writeAsStringSync('first');
    final bytes = List<int>.generate(70000, (i) => i * 7 % 256);
    final b = File('${dir.path}/shared-b.bin')..writeAsBytesSync(bytes);
    shares.share(SharedContent(files: [a, b], dir: dir));
    await waitFor(tester, find.text('shared-b.bin'));
    expect(find.text('/projects'), findsOneWidget);
    await tap(tester, find.widgetWithText(FilledButton, 'Upload'));
    await waitFor(tester, find.text('Uploaded 2 files'));
    await waitFor(tester, find.text('shared-a.txt'));
    expect((await admin.fetch('/projects/shared-a.txt')).item.content, 'first');
    expect(await admin.checksum('/projects/shared-b.bin', 'sha256'),
        sha256Of(bytes));
    expect(dir.existsSync(), isFalse, reason: 'copies removed after upload');

    // -- Plain text named after its subject; cancelling uploads nothing -----
    shares.share(const SharedContent(
        text: 'Call the plumber on Monday.', subject: 'Note: house'));
    await waitFor(tester, find.text('Upload to File Browser'));
    expect(tester.widget<TextField>(name).controller!.text, 'Note house.txt');
    await tap(tester, find.byTooltip('Cancel'));
    await waitFor(tester, find.text('readme.md'));
    expect(await exists('/projects/Note house.txt'), isFalse);
  });

  testWidgets('read-only account sees no write actions', (tester) async {
    await launch(tester);
    await login(tester, url: serverUrl, user: viewerUser, password: viewerPass);
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
    await tester.tapAt(const Offset(10, 10)); // Closes the menu.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
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
    await login(tester, url: proxyUrl, user: adminUser, password: adminPass);
    await waitFor(
        tester, find.text('The proxy rejected its username or password'));

    await enter(tester, 'Proxy password', proxyPass);
    await login(tester, url: proxyUrl, user: adminUser, password: adminPass);
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
