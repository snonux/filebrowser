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
    expect(parseShareExpiry('', 'seconds'), 0);
    expect(parseShareExpiry('  ', 'seconds'), 0);
    expect(parseShareExpiry('0', 'seconds'), 0);
    expect(parseShareExpiry(' 12 ', 'seconds'), 12);
    expect(parseShareExpiry('2147483647', 'seconds'), 2147483647);
  });

  test('parseShareExpiry ignores surrounding whitespace and leading zeros', () {
    expect(parseShareExpiry('007', 'seconds'), 7);
    expect(parseShareExpiry('\t12\n', 'seconds'), 12);
  });

  test('parseShareExpiry rejects anything else', () {
    for (final bad in [
      '-1',
      '+3',
      '1.5',
      '1,5',
      '1 2',
      '3 days',
      'abc',
      '0x10',
      // Arabic-Indic digits: the server only reads ASCII ones.
      '\u0661\u0662',
      '2147483648',
      '99999999999999999999999',
    ]) {
      expect(parseShareExpiry(bad, 'seconds'), isNull, reason: bad);
    }
  });

  test('parseShareExpiry limits each unit to what the server can add', () {
    const longest = {
      'seconds': 2147483647,
      'minutes': 153722867,
      'hours': 2562047,
      'days': 106751,
    };
    for (final MapEntry(key: unit, value: max) in longest.entries) {
      expect(maxShareExpiryFor(unit), max, reason: unit);
      expect(parseShareExpiry('$max', unit), max, reason: unit);
      expect(parseShareExpiry('${max + 1}', unit), isNull, reason: unit);
    }
    // 200000 days would wrap around to a date in the past.
    expect(parseShareExpiry('200000', 'days'), isNull);
    expect(parseShareExpiry('200000', 'hours'), 200000);
  });

  test('sortShareLinks puts permanent links first, then soonest expiry', () {
    ShareLink link(String hash, int expire) =>
        ShareLink(hash: hash, path: '/f', expire: expire);
    final sorted = sortShareLinks(
        [link('late', 900), link('never', 0), link('soon', 100)]);
    expect(sorted.map((l) => l.hash), ['never', 'soon', 'late']);
  });

  test('sortShareLinks groups ties and leaves its input alone', () {
    ShareLink link(String hash, int expire) =>
        ShareLink(hash: hash, path: '/f', expire: expire);
    final input = [
      link('b', 100),
      link('never2', 0),
      link('a', 100),
      link('never1', 0),
    ];
    final sorted = sortShareLinks(input);
    expect(sorted.map((l) => l.hash).toSet(), {'never2', 'never1', 'b', 'a'});
    expect(sorted.take(2).every((l) => l.expire == 0), isTrue);
    expect(sorted.skip(2).every((l) => l.expire == 100), isTrue);
    expect(input.map((l) => l.hash), ['b', 'never2', 'a', 'never1']);
    expect(sortShareLinks(const []), isEmpty);
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
