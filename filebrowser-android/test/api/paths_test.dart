import 'package:filebrowser_android/api/paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizePath', () {
    expect(normalizePath(''), '/');
    expect(normalizePath('a//b/'), '/a/b');
  });

  test('joinPath, parentOf, baseName', () {
    expect(joinPath('/', 'x'), '/x');
    expect(joinPath('/a/', 'x'), '/a/x');
    expect(parentOf('/a/b'), '/a');
    expect(parentOf('/a'), '/');
    expect(parentOf('/'), '/');
    expect(baseName('/a/b.txt'), 'b.txt');
    expect(baseName('/'), '/');
  });

  test('isValidName', () {
    expect(isValidName('ok.txt'), isTrue);
    for (final bad in ['', '  ', 'a/b', '.', '..']) {
      expect(isValidName(bad), isFalse, reason: bad);
    }
  });
}
