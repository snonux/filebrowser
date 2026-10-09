import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/providers/files_provider.dart';
import 'package:filebrowser_android/providers/preferences_provider.dart';
import 'package:flutter_test/flutter_test.dart';

FileItem item(String name, {bool dir = false, int size = 0, int day = 1}) =>
    FileItem(
      path: '/$name',
      name: name,
      size: size,
      modified: DateTime(2026, 1, day),
      isDir: dir,
      type: dir ? '' : 'blob',
    );

void main() {
  final items = [
    item('b.txt', size: 5, day: 3),
    item('Zdir', dir: true),
    item('.dot', size: 1, day: 2),
    item('a.txt', size: 10, day: 1),
  ];
  List<String> names(List<FileItem> l) => l.map((i) => i.name).toList();

  test('folders first, then by name ignoring case', () {
    expect(names(sortItems(items, SortField.name, true, true)),
        ['Zdir', '.dot', 'a.txt', 'b.txt']);
    expect(names(sortItems(items, SortField.name, false, true)),
        ['Zdir', 'b.txt', 'a.txt', '.dot']);
  });

  test('by size and date', () {
    expect(names(sortItems(items, SortField.size, false, true)),
        ['Zdir', 'a.txt', 'b.txt', '.dot']);
    expect(names(sortItems(items, SortField.modified, true, true)),
        ['Zdir', 'a.txt', '.dot', 'b.txt']);
  });

  test('hides dotfiles', () {
    expect(names(sortItems(items, SortField.name, true, false)),
        ['Zdir', 'a.txt', 'b.txt']);
  });
}
