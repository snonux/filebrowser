import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Access to files on the device: picking uploads, the download folder, and
/// opening a downloaded file in another app. Tests replace it with a fake.
abstract interface class DeviceFiles {
  /// Lets the user pick files to upload. Returns an empty list on cancel.
  Future<List<File>> pickFiles();

  /// Folder that downloads are saved into.
  Future<Directory> downloadDirectory();

  /// Opens [file] in the app Android picks for its type. Returns an error
  /// message, or null on success.
  Future<String?> open(File file);
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
  Future<String?> open(File file) async {
    final result = await OpenFilex.open(file.path);
    return result.type == ResultType.done ? null : result.message;
  }
}
