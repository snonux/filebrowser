import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:filebrowser_android/api/filebrowser_api.dart';
import 'package:filebrowser_android/models/models.dart';
import 'package:filebrowser_android/providers/device_files_provider.dart';
import 'package:filebrowser_android/providers/file_operations_provider.dart';
import 'package:filebrowser_android/providers/session_provider.dart';
import 'package:filebrowser_android/providers/transfers_provider.dart';
import 'package:filebrowser_android/services/device_files.dart';
import 'package:filebrowser_android/services/file_operations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/fake_adapter.dart';

class TestSessionController extends SessionController {
  TestSessionController(this.initial);
  final Session initial;
  @override
  Future<Session?> build() async => initial;
  void change(Session? session) => state = AsyncData(session);
}

class TestDeviceFiles implements DeviceFiles {
  TestDeviceFiles(this.dir);
  final Directory dir;
  Completer<Directory>? directory;
  Completer<List<File>>? picked;
  Object? directoryError;
  @override
  Future<Directory> downloadDirectory() async {
    if (directoryError != null) throw directoryError!;
    return directory == null ? dir : await directory!.future;
  }

  @override
  Future<List<File>> pickFiles() async =>
      picked == null ? [] : await picked!.future;
  @override
  Future<Directory> offlineDirectory() async =>
      Directory('${dir.path}/offline');
  @override
  Future<String?> open(File file) async => null;
  @override
  Future<Directory> editDirectory() async => Directory('${dir.path}/edit');
  @override
  Future<String?> editorName() async => null;
  @override
  Future<String?> edit(File file) async => null;
}

FileItem item(String path) => FileItem(
    path: path,
    name: 'report.txt',
    size: 4,
    modified: DateTime(2026),
    isDir: false,
    type: 'text');

void main() {
  late Directory dir;
  late TestDeviceFiles device;
  late ProviderContainer container;
  late TestSessionController sessions;
  late FileOperations operations;
  late Session alice, bob;
  late FakeAdapter oldAdapter, newAdapter;
  Session account(FakeAdapter adapter, String name) => Session(
      api: FileBrowserApi(
          baseUrl: 'http://$name.local',
          dio: Dio()..httpClientAdapter = adapter)
        ..token = '$name.token.sig',
      user: UserInfo(id: 1, username: name, perm: const Permissions()));
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('file-operations-');
    device = TestDeviceFiles(dir);
    oldAdapter = FakeAdapter((_) => reply(200, body: 'data'));
    newAdapter = FakeAdapter((_) => reply(200, body: 'new!'));
    alice = account(oldAdapter, 'alice');
    bob = account(newAdapter, 'bob');
    sessions = TestSessionController(alice);
    container = ProviderContainer(overrides: [
      sessionProvider.overrideWith(() => sessions),
      deviceFilesProvider.overrideWithValue(device),
    ]);
    await container.read(sessionProvider.future);
    operations = container.read(fileOperationsProvider);
  });
  tearDown(() async {
    container.dispose();
    alice.api.dio.close(force: true);
    bob.api.dio.close(force: true);
    await dir.delete(recursive: true);
  });
  FileOperation begin() =>
      operations.begin(container.read(sessionProvider).valueOrNull);
  for (final logout in [false, true]) {
    test('${logout ? 'logout' : 'switch'} during download directory selection',
        () async {
      device.directory = Completer<Directory>();
      final operation = begin();
      final pending = operation.download(item('/report.txt'));
      sessions.change(logout ? null : bob);
      device.directory!.complete(dir);
      expect((await pending).status, OperationStatus.cancelled);
      expect(oldAdapter.requests, isEmpty);
      expect(newAdapter.requests, isEmpty);
      expect(container.read(transfersProvider), isEmpty);
      operation.close();
    });
    test('${logout ? 'logout' : 'switch'} during upload picker', () async {
      final file = await File('${dir.path}/report.txt').writeAsString('data');
      device.picked = Completer<List<File>>();
      final operation = begin();
      final pending = operation.pickUploads();
      sessions.change(logout ? null : bob);
      device.picked!.complete([file]);
      expect((await pending).status, OperationStatus.cancelled);
      expect(
          (await operation.upload(file, '/', replace: (_) async => true))
              .status,
          OperationStatus.cancelled);
      expect(oldAdapter.requests, isEmpty);
      expect(newAdapter.requests, isEmpty);
      operation.close();
    });
    test(
        '${logout ? 'logout' : 'switch'} during upload replacement confirmation',
        () async {
      oldAdapter = FakeAdapter((_) => reply(409));
      alice.api.dio.httpClientAdapter = oldAdapter;
      final file = await File('${dir.path}/report.txt').writeAsString('data');
      final asked = Completer<void>(), decision = Completer<bool>();
      final operation = begin();
      final pending = operation.upload(file, '/', replace: (_) {
        asked.complete();
        return decision.future;
      });
      await asked.future;
      sessions.change(logout ? null : bob);
      decision.complete(true);
      expect((await pending).status, OperationStatus.cancelled);
      expect(oldAdapter.requests, hasLength(1));
      expect(newAdapter.requests, isEmpty);
      expect(container.read(transfersProvider).single.error, 'Cancelled');
      operation.close();
    });
    test(
        '${logout ? 'logout' : 'switch'} during download cleans partial file and reservation',
        () async {
      final started = Completer<void>(), answer = Completer<void>();
      oldAdapter.hold = (_) {
        started.complete();
        return answer.future;
      };
      final operation = begin();
      final pending = operation.download(item('/report.txt'));
      await started.future;
      sessions.change(logout ? null : bob);
      answer.complete();
      expect((await pending).status, OperationStatus.cancelled);
      expect(dir.listSync(), isEmpty);
      expect(newAdapter.requests, isEmpty);
      expect(container.read(transfersProvider).single.error, 'Cancelled');
      operation.close();
      sessions.change(bob);
      final fresh = begin();
      final next = await fresh.download(item('/report.txt'));
      expect(next.value!.path, '${dir.path}/report.txt');
      fresh.close();
    });
  }
  test(
      'concurrent same-name downloads reserve different paths before files exist',
      () async {
    final started = Completer<void>(), answers = Completer<void>();
    oldAdapter = FakeAdapter((options) =>
        reply(200, body: options.path.endsWith('/first') ? '1111' : '2222'));
    alice.api.dio.httpClientAdapter = oldAdapter;
    oldAdapter.hold = (_) {
      if (oldAdapter.requests.length == 2) started.complete();
      return answers.future;
    };
    final one = begin(), two = begin();
    final first = one.download(item('/first')),
        second = two.download(item('/second'));
    await started.future;
    answers.complete();
    final results = await Future.wait([first, second]);
    expect(results.every((r) => r.succeeded), isTrue);
    expect(results[0].value!.path, '${dir.path}/report.txt');
    expect(results[1].value!.path, '${dir.path}/report (1).txt');
    expect(await results[0].value!.readAsString(), '1111');
    expect(await results[1].value!.readAsString(), '2222');
    expect(
        container
            .read(transfersProvider)
            .every((t) => t.status == TransferStatus.done),
        isTrue);
    one.close();
    two.close();
  });
  test('failed download releases reservation without deleting existing file',
      () async {
    final existing = await File('${dir.path}/report.txt').writeAsString('keep');
    alice.api.dio.httpClientAdapter = FakeAdapter((_) => reply(500));
    final operation = begin();
    expect((await operation.download(item('/report.txt'))).status,
        OperationStatus.failed);
    expect(await existing.readAsString(), 'keep');
    expect(File('${dir.path}/report (1).txt').existsSync(), isFalse);
    alice.api.dio.httpClientAdapter =
        FakeAdapter((_) => reply(200, body: 'data'));
    expect((await operation.download(item('/report.txt'))).value!.path,
        '${dir.path}/report (1).txt');
    operation.close();
  });
  test('device failure is typed and creates no transfer', () async {
    device.directoryError = const FileSystemException('no folder');
    final operation = begin();
    final result = await operation.download(item('/report.txt'));
    expect(result.status, OperationStatus.failed);
    expect(result.error!.message, contains('no folder'));
    expect(container.read(transfersProvider), isEmpty);
    operation.close();
  });
  test('same API token renewal keeps held operation usable', () async {
    device.directory = Completer<Directory>();
    final operation = begin();
    final pending = operation.download(item('/report.txt'));
    alice.api.token = 'renewed.token.sig';
    sessions.change(Session(api: alice.api, user: alice.user));
    device.directory!.complete(dir);
    expect((await pending).succeeded, isTrue);
    expect(oldAdapter.sentHeaders.single['X-Auth'], 'renewed.token.sig');
    operation.close();
  });
  test('mutation captured before UI wait cannot run after account switch',
      () async {
    final operation = begin();
    sessions.change(bob);
    expect((await operation.createFolder('/new')).status,
        OperationStatus.cancelled);
    expect((await operation.transfer('/from', '/to', copy: false)).status,
        OperationStatus.cancelled);
    expect((await operation.delete('/from')).status, OperationStatus.cancelled);
    expect(oldAdapter.requests, isEmpty);
    expect(newAdapter.requests, isEmpty);
    operation.close();
  });
  test('upload conflict decline records skipped on one transfer', () async {
    alice.api.dio.httpClientAdapter = FakeAdapter((_) => reply(409));
    final file = await File('${dir.path}/report.txt').writeAsString('data');
    final operation = begin();
    expect(
        (await operation.upload(file, '/', replace: (_) async => false)).status,
        OperationStatus.skipped);
    expect(container.read(transfersProvider).single.error, 'Skipped');
    operation.close();
  });
  test('switch cancels held mutation request and does not use the new account',
      () async {
    final started = Completer<void>(), answer = Completer<void>();
    oldAdapter.hold = (_) {
      started.complete();
      return answer.future;
    };
    final operation = begin();
    final pending = operation.createFile('/new.txt');
    await started.future;
    final cancelToken = oldAdapter.requests.single.cancelToken!;
    expect(cancelToken.isCancelled, isFalse);
    sessions.change(bob);
    expect(cancelToken.isCancelled, isTrue);
    expect((await pending).status, OperationStatus.cancelled);
    answer.complete();
    expect(oldAdapter.sentHeaders.single['X-Auth'], 'alice.token.sig');
    expect(newAdapter.requests, isEmpty);
    operation.close();
  });

  test('logout cancels held tus creation before any upload chunk', () async {
    final started = Completer<void>(), answer = Completer<void>();
    oldAdapter.hold = (_) {
      started.complete();
      return answer.future;
    };
    final file = await File('${dir.path}/report.txt').writeAsString('data');
    final operation = begin();
    final pending = operation.upload(file, '/', replace: (_) async => true);
    await started.future;
    sessions.change(null);
    expect(oldAdapter.requests.single.cancelToken!.isCancelled, isTrue);
    expect((await pending).status, OperationStatus.cancelled);
    answer.complete();
    expect(oldAdapter.requests.single.method, 'POST');
    expect(container.read(transfersProvider).single.error, 'Cancelled');
    operation.close();
  });

  test('provider disposal during held download cancels and cleans safely',
      () async {
    final started = Completer<void>(), answer = Completer<void>();
    oldAdapter.hold = (_) {
      started.complete();
      return answer.future;
    };
    final operation = begin();
    final pending = operation.download(item('/report.txt'));
    await started.future;
    container.dispose();
    answer.complete();
    expect((await pending).status, OperationStatus.cancelled);
    expect(dir.listSync(), isEmpty);
    operation.close();
  });
}
