import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'local_files.dart';

/// Access to files on the device: picking uploads, the download folder, and
/// opening a downloaded file in another app. Tests replace it with a fake.
abstract interface class DeviceFiles {
  /// Lets the user pick files to upload. Returns an empty list on cancel.
  Future<List<File>> pickFiles();

  /// Folder that downloads are saved into.
  Future<Directory> downloadDirectory();

  /// Folder that copies of files marked "available offline" are kept in.
  Future<Directory> offlineDirectory();

  /// Opens [file] in the app Android picks for its type. Returns an error
  /// message, or null on success.
  Future<String?> open(File file);

  /// Folder that files are copied into while another app edits them.
  Future<Directory> editDirectory();

  /// The app "Edit in" hands text files to (TurboNotes), or null when it
  /// is not installed and the user picks one.
  Future<String?> editorName();

  /// Lets another app edit [file] in place (see [editDirectory]). Returns an
  /// error message, or null on success.
  Future<String?> edit(File file);

  /// The phone's storage volumes that "On this phone" browses.
  Future<List<StorageRoot>> storageRoots();

  /// Whether the app may read and write all of the phone's files.
  Future<bool> hasStorageAccess();

  /// Asks the user for [hasStorageAccess]: the system's "All files access"
  /// screen, or the storage permission prompt on Android 10 and older.
  /// Returns whether access was granted.
  Future<bool> requestStorageAccess();
}

class PlatformDeviceFiles implements DeviceFiles {
  @override
  Future<List<File>> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return const [];
    return result.files
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .toList();
  }

  @override
  Future<Directory> downloadDirectory() async {
    // On Android this is the app's own Download folder on shared storage,
    // which needs no storage permission and is visible to file managers
    // under Android/data/<app>/files/Download.
    final dir = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<Directory> offlineDirectory() async {
    // On Android the app's folder on shared storage, next to Download, so
    // other apps can open the copies the same way as downloads. It is removed
    // with the app.
    final base = Platform.isAndroid
        ? await getExternalStorageDirectory() ??
            await getApplicationSupportDirectory()
        : await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline');
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<String?> open(File file) async {
    final result = await OpenFilex.open(file.path);
    return result.type == ResultType.done ? null : result.message;
  }

  static const _edit = MethodChannel('org.buetow.filebrowser/edit');

  @override
  Future<Directory> editDirectory() async {
    // The cache directory, which the app's EditProvider serves from.
    final dir = Directory('${(await getTemporaryDirectory()).path}/edit');
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<String?> editorName() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _edit.invokeMethod<String>('editorName');
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<String?> edit(File file) async {
    if (!Platform.isAndroid) return open(file);
    try {
      return await _edit.invokeMethod<String>('edit', {'path': file.path});
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  static const _storage = MethodChannel('org.buetow.filebrowser/storage');

  @override
  Future<List<StorageRoot>> storageRoots() async {
    if (!Platform.isAndroid) {
      final home = Platform.environment['HOME'] ?? Directory.current.path;
      return [StorageRoot(name: 'Home', path: home)];
    }
    final roots = await _storage.invokeListMethod<Map>('roots') ?? const [];
    return [
      for (final root in roots)
        StorageRoot(name: root['name'] as String, path: root['path'] as String),
    ];
  }

  @override
  Future<bool> hasStorageAccess() async {
    if (!Platform.isAndroid) return true;
    return await _storage.invokeMethod<bool>('hasAccess') ?? false;
  }

  @override
  Future<bool> requestStorageAccess() async {
    if (!Platform.isAndroid) return true;
    return await _storage.invokeMethod<bool>('requestAccess') ?? false;
  }
}
