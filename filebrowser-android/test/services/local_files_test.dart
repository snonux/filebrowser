import 'dart:io';

import 'package:filebrowser_android/services/local_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  const files = LocalFiles();
  String at(String name) => '${dir.path}/$name';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local-files-');
    File(at('notes.txt')).writeAsStringSync('hello');
    File(at('photo.JPG')).writeAsBytesSync([1, 2, 3]);
    Directory(at('docs/sub')).createSync(recursive: true);
    File(at('docs/sub/deep.md')).writeAsStringSync('deep');
  });
  tearDown(() => dir.delete(recursive: true));

  test('lists entries with sizes and types', () async {
    final items = {for (final i in await files.list(dir.path)) i.name: i};
    expect(items.keys, unorderedEquals(['notes.txt', 'photo.JPG', 'docs']));
    expect(items['notes.txt']!.size, 5);
    expect(items['notes.txt']!.type, 'text');
    expect(items['photo.JPG']!.isImage, isTrue);
    expect(items['docs']!.isDir, isTrue);
    expect(items['docs']!.path, at('docs'));
  });

  test('typeOf guesses from the extension', () {
    expect(LocalFiles.typeOf('a.pdf'), 'pdf');
    expect(LocalFiles.typeOf('a.MP4'), 'video');
    expect(LocalFiles.typeOf('a.flac'), 'audio');
    expect(LocalFiles.typeOf('Makefile'), 'blob');
  });

  test('createFolder refuses an existing name', () async {
    await files.createFolder(at('new'));
    expect(Directory(at('new')).existsSync(), isTrue);
    expect(() => files.createFolder(at('new')), throwsA(isA<LocalConflict>()));
  });

  test('copy copies folders recursively and asks before replacing', () async {
    await files.copy(at('docs'), at('copy'));
    expect(File(at('copy/sub/deep.md')).readAsStringSync(), 'deep');
    expect(File(at('docs/sub/deep.md')).existsSync(), isTrue);
    expect(() => files.copy(at('notes.txt'), at('photo.JPG')),
        throwsA(isA<LocalConflict>()));
    await files.copy(at('notes.txt'), at('photo.JPG'), override: true);
    expect(File(at('photo.JPG')).readAsStringSync(), 'hello');
  });

  test('move renames and refuses to move a folder into itself', () async {
    await files.move(at('notes.txt'), at('docs/notes.txt'));
    expect(File(at('notes.txt')).existsSync(), isFalse);
    expect(File(at('docs/notes.txt')).readAsStringSync(), 'hello');
    expect(() => files.move(at('docs'), at('docs/sub/docs')),
        throwsA(isA<FileSystemException>()));
  });

  test('delete removes folders with their contents', () async {
    await files.delete(at('docs'));
    expect(Directory(at('docs')).existsSync(), isFalse);
  });

  test('freeName numbers taken names', () async {
    expect(await files.freeName(dir.path, 'new.txt'), at('new.txt'));
    expect(await files.freeName(dir.path, 'notes.txt'), at('notes (1).txt'));
    File(at('notes (1).txt')).createSync();
    expect(await files.freeName(dir.path, 'notes.txt'), at('notes (2).txt'));
  });

  test('walk lists folders and files relative to the root', () async {
    final tree = await files.walk(at('docs'));
    expect(tree.folders, ['sub']);
    expect(tree.files, ['sub/deep.md']);
  });
}
