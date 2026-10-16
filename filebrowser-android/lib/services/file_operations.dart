import 'dart:io';

import 'package:dio/dio.dart';

import '../api/filebrowser_api.dart';
import '../api/paths.dart';
import '../models/models.dart';
import '../providers/session_provider.dart';
import '../providers/transfers_provider.dart';
import 'device_files.dart';

enum OperationStatus { success, failed, conflict, cancelled, skipped }

/// Presentation decides how to display a failure or resolve a conflict.
class OperationResult<T> {
  const OperationResult(this.status, {this.value, this.error});
  final OperationStatus status;
  final T? value;
  final ApiException? error;
  bool get succeeded => status == OperationStatus.success;
}

/// Owns account-bound operations and download names across all screens.
class FileOperations {
  FileOperations({required this.deviceFiles, required this.transfers});

  final DeviceFiles deviceFiles;
  final TransfersNotifier transfers;
  final _active = <FileOperation>{};
  final _destinations = <String>{};
  bool _disposed = false;

  FileOperation begin(Session? session) {
    final operation = FileOperation._(this, session);
    _active.add(operation);
    if (session == null || _disposed) operation.cancel();
    return operation;
  }

  void sessionChanged(Session? session) {
    for (final operation in _active) {
      if (!identical(operation._session?.api, session?.api)) {
        operation.cancel();
      }
    }
  }

  void dispose() {
    _disposed = true;
    for (final operation in _active) {
      operation.cancel();
    }
  }

  /// A free path for [name] in [dir] (`name (1).ext` when taken), held
  /// until the caller releases it from [_destinations].
  FileSystemEntity _reserve(Directory dir, String name, {bool folder = false}) {
    final dot = folder ? -1 : name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    FileSystemEntity at(String n) =>
        folder ? Directory('${dir.path}/$n') : File('${dir.path}/$n');
    var target = at(name);
    for (var i = 1;
        FileSystemEntity.typeSync(target.path) !=
                FileSystemEntityType.notFound ||
            _destinations.contains(target.absolute.path);
        i++) {
      target = at('$stem ($i)$ext');
    }
    _destinations.add(target.absolute.path);
    return target;
  }
}

/// Captured synchronously before a dialog, device picker or network await.
/// Same-account token renewal keeps the API identity; logout/switch cancels it.
class FileOperation {
  FileOperation._(this._owner, this._session);
  final FileOperations _owner;
  final Session? _session;
  final _cancel = CancelToken();

  bool get cancelled => _cancel.isCancelled;
  void cancel() => _cancel.cancel('Account changed');
  void close() {
    cancel();
    _owner._active.remove(this);
  }

  Future<OperationResult<T>> _request<T>(Future<T> Function() request) async {
    if (cancelled) return OperationResult<T>(OperationStatus.cancelled);
    try {
      final value = await request();
      return cancelled
          ? OperationResult<T>(OperationStatus.cancelled)
          : OperationResult<T>(OperationStatus.success, value: value);
    } catch (error) {
      if (cancelled) return OperationResult<T>(OperationStatus.cancelled);
      final apiError = ApiException.from(error);
      return OperationResult<T>(
          apiError.isConflict
              ? OperationStatus.conflict
              : OperationStatus.failed,
          error: apiError);
    }
  }

  Future<OperationResult<FileItem>> fetch(String path) => _request(
      () async => (await _session!.api.fetch(path, cancelToken: _cancel)).item);
  Future<OperationResult<void>> createFolder(String path) =>
      _request(() => _session!.api.createFolder(path, cancelToken: _cancel));
  Future<OperationResult<void>> createFile(String path) =>
      _request(() => _session!.api.createFile(path, cancelToken: _cancel));
  Future<OperationResult<void>> delete(String path) =>
      _request(() => _session!.api.delete(path, cancelToken: _cancel));
  Future<OperationResult<void>> transfer(String from, String to,
          {required bool copy, bool override = false}) =>
      _request(() => copy
          ? _session!.api
              .copy(from, to, override: override, cancelToken: _cancel)
          : _session!.api
              .move(from, to, override: override, cancelToken: _cancel));

  Future<OperationResult<List<File>>> pickUploads() =>
      _request(_owner.deviceFiles.pickFiles);

  Future<OperationResult<void>> upload(File file, String dir,
      {required Future<bool> Function(String name) replace}) async {
    if (cancelled) return const OperationResult(OperationStatus.cancelled);
    final name = file.uri.pathSegments.last;
    final id = _owner.transfers.start(TransferKind.upload, name);
    Future<OperationResult<void>> run(bool override) =>
        _request(() => _session!.api.upload(file, joinPath(dir, name),
                override: override,
                cancelToken: _cancel, onProgress: (sent, total) {
              if (!cancelled) _owner.transfers.progress(id, sent, total);
            }));
    var result = await run(false);
    if (result.status == OperationStatus.conflict) {
      final decision = await _request(() => replace(name));
      if (!decision.succeeded) {
        result = OperationResult(decision.status, error: decision.error);
      } else if (!decision.value!) {
        result = const OperationResult(OperationStatus.skipped);
      } else {
        result = await run(true);
      }
    }
    if (_owner._disposed) return result;
    if (result.succeeded) {
      _owner.transfers.finish(id);
    } else {
      _owner.transfers.fail(
          id,
          result.error?.message ??
              (result.status == OperationStatus.skipped
                  ? 'Skipped'
                  : 'Cancelled'));
    }
    return result;
  }

  /// Saves [item] (a file, or a folder as a zip) into the download folder.
  Future<OperationResult<File>> download(FileItem item) async {
    final Directory dir;
    try {
      dir = await _owner.deviceFiles.downloadDirectory();
    } catch (error) {
      return OperationResult(OperationStatus.failed,
          error: ApiException.from(error));
    }
    // The device dialog may have outlived the initiating account.
    if (cancelled) return const OperationResult(OperationStatus.cancelled);
    return _downloadFile(item, dir, archive: item.isDir);
  }

  /// Saves [item] into the phone folder [dir]: a file as is, a folder with
  /// everything in it. A name that is taken gets a ` (1)` suffix. Returns
  /// the new file or folder.
  Future<OperationResult<FileSystemEntity>> downloadInto(
      FileItem item, String dir) async {
    if (!item.isDir) return _downloadFile(item, Directory(dir));
    final Directory target;
    try {
      target =
          _owner._reserve(Directory(dir), item.name, folder: true) as Directory;
    } catch (error) {
      return OperationResult(OperationStatus.failed,
          error: ApiException.from(error));
    }
    try {
      target.createSync(recursive: true);
      final result = await _downloadTree(item.path, target);
      return result.succeeded
          ? OperationResult(OperationStatus.success, value: target)
          : OperationResult(result.status, error: result.error);
    } on FileSystemException catch (error) {
      return OperationResult(OperationStatus.failed,
          error: ApiException('$error'));
    } finally {
      _owner._destinations.remove(target.absolute.path);
    }
  }

  /// Downloads the contents of the server folder [path] into [dir].
  Future<OperationResult<void>> _downloadTree(
      String path, Directory dir) async {
    final listing =
        await _request(() => _session!.api.fetch(path, cancelToken: _cancel));
    if (!listing.succeeded) {
      return OperationResult(listing.status, error: listing.error);
    }
    for (final child in listing.value!.items) {
      if (cancelled) return const OperationResult(OperationStatus.cancelled);
      final OperationResult<dynamic> result;
      if (child.isDir) {
        final sub = Directory('${dir.path}/${child.name}');
        sub.createSync();
        result = await _downloadTree(child.path, sub);
      } else {
        result = await _downloadFile(child, dir);
      }
      if (!result.succeeded) {
        return OperationResult(result.status, error: result.error);
      }
    }
    return const OperationResult(OperationStatus.success);
  }

  /// Downloads one file (or, with [archive], a folder as a zip) into [dir]
  /// under a free name, with progress in the transfer bar.
  Future<OperationResult<File>> _downloadFile(FileItem item, Directory dir,
      {bool archive = false}) async {
    File? target;
    int? id;
    final name = archive ? '${item.name}.zip' : item.name;
    var result = await _request(() async {
      target = _owner._reserve(dir, name) as File;
      id = _owner.transfers.start(TransferKind.download, name);
      await _session!.api.download(item.path, target!.path,
          archive: archive ? 'zip' : null,
          cancelToken: _cancel, onProgress: (received, total) {
        if (!cancelled) {
          _owner.transfers
              .progress(id!, received, total < 0 ? item.size : total);
        }
      });
      return target!;
    });
    if (id != null && !_owner._disposed) {
      if (result.succeeded) {
        _owner.transfers.finish(id!);
      } else {
        _owner.transfers.fail(id!, result.error?.message ?? 'Cancelled');
      }
    }
    if (target != null) {
      try {
        if (!result.succeeded && target!.existsSync()) target!.deleteSync();
      } on FileSystemException catch (error) {
        result = OperationResult(OperationStatus.failed,
            error: ApiException('Cannot remove incomplete download: $error'));
      } finally {
        _owner._destinations.remove(target!.absolute.path);
      }
    }
    return result;
  }

  Future<OperationResult<String?>> open(File file) =>
      _request(() => _owner.deviceFiles.open(file));
}
