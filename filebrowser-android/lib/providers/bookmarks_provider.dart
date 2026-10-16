import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/paths.dart';
import '../models/models.dart';
import 'preferences_provider.dart';
import 'session_provider.dart';

/// Where a bookmarked item lives.
enum BookmarkPlace { server, phone }

/// A file or folder the user wants to reach quickly: on the server (for the
/// account that bookmarked it) or on the phone's own storage.
class Bookmark {
  const Bookmark({
    required this.place,
    required this.path,
    required this.name,
    required this.isDir,
    this.type = '',
    this.account = '',
  });

  factory Bookmark.server(FileItem item, String account) => Bookmark(
        place: BookmarkPlace.server,
        path: normalizePath(item.path),
        name: item.path == '/' ? 'Home' : item.name,
        isDir: item.isDir,
        type: item.type,
        account: account,
      );

  factory Bookmark.phone(FileItem item) => Bookmark(
        place: BookmarkPlace.phone,
        path: normalizePath(item.path),
        name: item.name,
        isDir: item.isDir,
        type: item.type,
      );

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        place: BookmarkPlace.values.byName(json['place'] as String),
        path: json['path'] as String,
        name: json['name'] as String? ?? '',
        isDir: json['isDir'] as bool? ?? false,
        type: json['type'] as String? ?? '',
        account: json['account'] as String? ?? '',
      );

  final BookmarkPlace place;
  final String path;
  final String name;
  final bool isDir;

  /// The server's type of a file (see [FileItem.type]), so it opens in the
  /// right viewer without asking the server first.
  final String type;

  /// The server and user (see [accountKey]) of a server bookmark; empty for
  /// one on the phone.
  final String account;

  bool get onPhone => place == BookmarkPlace.phone;

  /// The item as far as the bookmark knows it.
  FileItem get item => FileItem(
        path: path,
        name: name,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        isDir: isDir,
        type: type,
      );

  Bookmark _movedTo(String newPath) => Bookmark(
        place: place,
        path: newPath,
        name: newPath == '/' ? 'Home' : baseName(newPath),
        isDir: isDir,
        type: type,
        account: account,
      );

  bool _same(Bookmark other) =>
      place == other.place && account == other.account && path == other.path;

  Map<String, dynamic> toJson() => {
        'place': place.name,
        'path': path,
        'name': name,
        'isDir': isDir,
        'type': type,
        if (account.isNotEmpty) 'account': account,
      };
}

/// Identifies a server account for bookmarks: its address and user name.
String accountKey(Session session) =>
    '${session.api.baseUrl}\n${session.user.username}';

/// Whether [path] is [root] or inside it.
bool _within(String path, String root) =>
    path == root || root == '/' || path.startsWith('$root/');

/// The bookmarks of the signed-in account plus those on the phone, in the
/// order they were added. They are kept on the device.
class BookmarksNotifier extends Notifier<List<Bookmark>> {
  static const _key = 'bookmarks';

  /// The account whose server bookmarks are shown; empty when signed out.
  String _account = '';

  List<Bookmark> _all() {
    final raw = ref.read(sharedPreferencesProvider).getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(Bookmark.fromJson)
          .toList();
    } on Object {
      return [];
    }
  }

  List<Bookmark> _visible(List<Bookmark> all) => all
      .where((b) => b.onPhone || (_account.isNotEmpty && b.account == _account))
      .toList();

  Future<void> _save(List<Bookmark> all) async {
    state = _visible(all);
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, jsonEncode([for (final b in all) b.toJson()]));
  }

  @override
  List<Bookmark> build() {
    final session = ref.watch(sessionProvider.select((s) => s.valueOrNull));
    _account = session == null ? '' : accountKey(session);
    return _visible(_all());
  }

  /// The bookmark of [path] at [place] for the current account, if any.
  Bookmark? find(BookmarkPlace place, String path) {
    final p = normalizePath(path);
    for (final b in state) {
      if (b.place == place && b.path == p) return b;
    }
    return null;
  }

  /// Bookmarks a server item for the signed-in account.
  Future<void> addServer(FileItem item) async {
    if (_account.isEmpty) return;
    await _add(Bookmark.server(item, _account));
  }

  Future<void> addPhone(FileItem item) => _add(Bookmark.phone(item));

  Future<void> _add(Bookmark bookmark) async {
    final all = _all();
    if (all.any(bookmark._same)) return;
    await _save([...all, bookmark]);
  }

  Future<void> remove(Bookmark bookmark) async =>
      _save(_all()..removeWhere(bookmark._same));

  bool _mine(Bookmark b, BookmarkPlace place) =>
      b.place == place && (b.onPhone || b.account == _account);

  /// Follows the app's rename or move of [from] to [to], including
  /// bookmarks inside a moved folder.
  Future<void> moved(BookmarkPlace place, String from, String to) async {
    final f = normalizePath(from);
    final t = normalizePath(to);
    if (f == '/' || f == t) return;
    var changed = false;
    final all = _all();
    for (var i = 0; i < all.length; i++) {
      final b = all[i];
      if (_mine(b, place) && _within(b.path, f)) {
        all[i] = b._movedTo(t + b.path.substring(f.length));
        changed = true;
      }
    }
    if (changed) await _save(all);
  }

  /// Drops the bookmarks of [path], and of everything in it, after the app
  /// deleted it.
  Future<void> deleted(BookmarkPlace place, String path) async {
    final p = normalizePath(path);
    final all = _all();
    final before = all.length;
    all.removeWhere((b) => _mine(b, place) && _within(b.path, p));
    if (all.length != before) await _save(all);
  }
}

final bookmarksProvider =
    NotifierProvider<BookmarksNotifier, List<Bookmark>>(BookmarksNotifier.new);
