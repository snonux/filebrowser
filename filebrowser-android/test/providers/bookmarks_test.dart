import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/providers/bookmarks_provider.dart';
import 'package:filebrowser_android/providers/preferences_provider.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session session(String user, {String url = 'https://files.example'}) => Session(
      api: FileBrowserApi(baseUrl: url),
      user: UserInfo.fromJson({'id': 1, 'username': user}),
    );

/// A session that tests switch by hand.
class FakeSession extends SessionController {
  FakeSession(this.initial);

  final Session? initial;

  @override
  Future<Session?> build() async => initial;

  void signIn(Session? session) => state = AsyncData(session);
}

FileItem item(String path, {bool dir = false, String type = ''}) => FileItem(
      path: path,
      name: path.substring(path.lastIndexOf('/') + 1),
      size: 0,
      modified: DateTime(2026),
      isDir: dir,
      type: type,
    );

void main() {
  late SharedPreferences prefs;
  late ProviderContainer container;
  late FakeSession fake;

  Future<void> start(Session? initial) async {
    fake = FakeSession(initial);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(() => fake),
    ]);
    addTearDown(container.dispose);
    container.listen(bookmarksProvider, (_, __) {});
    await container.read(sessionProvider.future);
  }

  BookmarksNotifier notifier() => container.read(bookmarksProvider.notifier);
  List<String> paths() =>
      [for (final b in container.read(bookmarksProvider)) b.path];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('server bookmarks belong to their account, phone ones to all', () async {
    await start(session('alice'));
    await notifier().addServer(item('/projects', dir: true));
    await notifier().addServer(item('/readme.md', type: 'text'));
    await notifier().addPhone(item('/storage/emulated/0/Download', dir: true));
    // Adding twice keeps one.
    await notifier().addServer(item('/projects', dir: true));
    expect(
        paths(), ['/projects', '/readme.md', '/storage/emulated/0/Download']);
    final readme = notifier().find(BookmarkPlace.server, '/readme.md')!;
    expect(readme.item.isText, isTrue);
    expect(notifier().find(BookmarkPlace.phone, '/readme.md'), isNull);

    fake.signIn(session('bob'));
    await pumpEventQueue();
    expect(paths(), ['/storage/emulated/0/Download']);
    fake.signIn(session('alice', url: 'https://other.example'));
    await pumpEventQueue();
    expect(paths(), ['/storage/emulated/0/Download']);

    fake.signIn(session('alice'));
    await pumpEventQueue();
    expect(
        paths(), ['/projects', '/readme.md', '/storage/emulated/0/Download']);
  });

  test('kept between launches', () async {
    await start(session('alice'));
    await notifier().addServer(item('/', dir: true));
    await notifier().addPhone(item('/sdcard/a.pdf', type: 'pdf'));
    container.dispose();

    await start(session('alice'));
    final bookmarks = container.read(bookmarksProvider);
    expect(bookmarks.map((b) => b.name), ['Home', 'a.pdf']);
    expect(bookmarks.last.onPhone, isTrue);
    expect(bookmarks.last.item.isPdf, isTrue);
  });

  test('follow renames and moves, also of the folder they are in', () async {
    await start(session('alice'));
    await notifier().addServer(item('/a', dir: true));
    await notifier().addServer(item('/a/b/c.txt', type: 'text'));
    await notifier().addServer(item('/ab', dir: true));
    await notifier().addPhone(item('/a', dir: true));

    await notifier().moved(BookmarkPlace.server, '/a', '/x/y');
    expect(paths(), ['/x/y', '/x/y/b/c.txt', '/ab', '/a']);
    expect(container.read(bookmarksProvider).first.name, 'y');
    expect(container.read(bookmarksProvider)[1].name, 'c.txt');

    await notifier().moved(BookmarkPlace.phone, '/a', '/z');
    expect(paths(), ['/x/y', '/x/y/b/c.txt', '/ab', '/z']);
  });

  test('deleting an item drops its bookmarks and those inside it', () async {
    await start(session('alice'));
    await notifier().addServer(item('/a', dir: true));
    await notifier().addServer(item('/a/b.txt'));
    await notifier().addServer(item('/ab.txt'));
    await notifier().addPhone(item('/a/b.txt'));

    await notifier().deleted(BookmarkPlace.server, '/a');
    expect(paths(), ['/ab.txt', '/a/b.txt']);
    await notifier().remove(container.read(bookmarksProvider).last);
    expect(paths(), ['/ab.txt']);
  });

  test('another account\'s bookmarks are not touched', () async {
    await start(session('alice'));
    await notifier().addServer(item('/a', dir: true));
    fake.signIn(session('bob'));
    await pumpEventQueue();
    await notifier().addServer(item('/a', dir: true));
    await notifier().deleted(BookmarkPlace.server, '/a');
    expect(paths(), isEmpty);

    fake.signIn(session('alice'));
    await pumpEventQueue();
    expect(paths(), ['/a']);
  });

  test(
      'signed out, only phone bookmarks show and none can be added '
      'for the server', () async {
    await start(null);
    await notifier().addServer(item('/a', dir: true));
    await notifier().addPhone(item('/sdcard/b', dir: true));
    expect(paths(), ['/sdcard/b']);
  });
}
