import 'package:filebrowser_android/services/external_edits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('edits to a file changed on the server go next to it', () {
    final at = DateTime(2026, 10, 4, 3, 42, 5);
    expect(conflictPath('/Docs/notes.md', at),
        '/Docs/notes (edited 2026-10-04 034205).md');
    expect(conflictPath('/README', at), '/README (edited 2026-10-04 034205)');
    expect(conflictPath('/.env', at), '/.env (edited 2026-10-04 034205)');
  });
}
