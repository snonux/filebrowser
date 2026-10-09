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
}
