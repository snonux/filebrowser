import 'package:filebrowser_android/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'api/fake_adapter.dart';

void main() {
  test('TokenClaims reads the user and expiry from a File Browser JWT', () {
    final claims = TokenClaims.parse(fakeToken(username: 'bob', id: 7));
    expect(claims.user.username, 'bob');
    expect(claims.user.id, 7);
    expect(claims.user.perm.create, isTrue);
    expect(claims.user.perm.delete, isFalse);
    expect(claims.user.hideDotfiles, isTrue);
    expect(claims.isExpired, isFalse);
    expect(
        TokenClaims.parse(fakeToken(ttl: const Duration(minutes: -1)))
            .isExpired,
        isTrue);
    expect(() => TokenClaims.parse('nope'), throwsFormatException);
  });

  test('Resource parses a listing', () {
    final r = Resource.fromJson({
      'path': '/d',
      'name': 'd',
      'isDir': true,
      'modified': '2026-10-09T18:00:00Z',
      'items': [
        {
          'path': '/d/a.png',
          'name': 'a.png',
          'size': 3,
          'type': 'image',
          'modified': '2026-10-09T18:00:00Z'
        },
      ],
    });
    expect(r.item.isDir, isTrue);
    expect(r.items.single.isImage, isTrue);
    expect(r.items.single.size, 3);
  });

  test('ShareLink expiry', () {
    expect(ShareLink.fromJson({'hash': 'h', 'expire': 0}).expiresAt, isNull);
    expect(ShareLink.fromJson({'hash': 'h', 'expire': 60}).expiresAt,
        DateTime.fromMillisecondsSinceEpoch(60000, isUtc: true));
  });

  test('parseShareExpiry accepts whole numbers the web UI allows', () {
    expect(parseShareExpiry(''), 0);
    expect(parseShareExpiry('  '), 0);
    expect(parseShareExpiry('0'), 0);
    expect(parseShareExpiry(' 12 '), 12);
    expect(parseShareExpiry('2147483647'), 2147483647);
  });

  test('parseShareExpiry rejects anything else', () {
    for (final bad in [
      '-1',
      '+3',
      '1.5',
      '1,5',
      '3 days',
      'abc',
      '0x10',
      '2147483648',
      '99999999999999999999999',
    ]) {
      expect(parseShareExpiry(bad), isNull, reason: bad);
    }
  });

  test('sortShareLinks puts permanent links first, then soonest expiry', () {
    ShareLink link(String hash, int expire) =>
        ShareLink(hash: hash, path: '/f', expire: expire);
    final sorted = sortShareLinks(
        [link('late', 900), link('never', 0), link('soon', 100)]);
    expect(sorted.map((l) => l.hash), ['never', 'soon', 'late']);
  });

  test('sharing needs both the share and the download permission', () {
    Permissions perm(bool share, bool download) =>
        Permissions.fromJson({'share': share, 'download': download});
    expect(perm(true, true).canShare, isTrue);
    expect(perm(true, false).canShare, isFalse);
    expect(perm(false, true).canShare, isFalse);
    expect(const Permissions().canShare, isFalse);
  });
}
