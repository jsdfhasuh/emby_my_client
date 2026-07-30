import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/downloads/download_executor.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/downloads/download_preflight.dart';
import 'package:emby_my_client/downloads/download_repository.dart';
import 'package:emby_my_client/downloads/download_service.dart';
import 'package:emby_my_client/downloads/download_settings.dart';
import 'package:emby_my_client/downloads/download_transport.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('downloads and commits an original media file atomically', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(
        _mediaBytes,
        headers: {
          'content-length': '${_mediaBytes.length}',
          'content-type': 'video/x-matroska',
          'etag': '"media-v1"',
        },
      ),
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final completed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.completed,
    );
    final offline = await harness.service.offlineItem(_item.id);

    expect(transport.calls, hasLength(1));
    expect(transport.calls.single.offset, 0);
    expect(completed.downloadedBytes, _mediaBytes.length);
    expect(completed.etag, '"media-v1"');
    expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
    expect(await File(completed.tempPath).exists(), isFalse);
    expect(offline?.localMediaPath, completed.finalPath);
    expect(offline?.metadata.name, _item.name);
  });

  test('pauses and resumes with Range and If-Range', () async {
    final transport = _FakeTransport(
      handler: (call) async {
        if (call.offset == 0 && call.index == 0) {
          return DownloadResponse(
            statusCode: 200,
            headers: {
              'content-length': '${_mediaBytes.length}',
              'content-type': 'video/x-matroska',
              'etag': '"media-v1"',
            },
            stream: _pauseAfter(_mediaBytes.sublist(0, 4), call.cancelToken),
          );
        }
        return _response(
          _mediaBytes.sublist(call.offset),
          statusCode: 206,
          headers: {
            'content-length': '${_mediaBytes.length - call.offset}',
            'content-range':
                'bytes ${call.offset}-${_mediaBytes.length - 1}/'
                '${_mediaBytes.length}',
            'content-type': 'video/x-matroska',
            'etag': '"media-v1"',
          },
        );
      },
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    final task = await harness.service.enqueue(_item);
    await _waitUntil(
      () => harness.service.taskForItem(_item.id)?.downloadedBytes == 4,
    );
    await harness.service.pause(task.id);
    await harness.service.resume(task.id);
    final completed = await _waitForTask(
      harness.service,
      (candidate) => candidate.status == DownloadStatus.completed,
    );

    expect(transport.calls, hasLength(2));
    expect(transport.calls[1].offset, 4);
    expect(transport.calls[1].etag, '"media-v1"');
    expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
  });

  test('restarts from zero when the server ignores a Range request', () async {
    final transport = _FakeTransport(
      handler: (call) async {
        if (call.index == 0) {
          return DownloadResponse(
            statusCode: 200,
            headers: {
              'content-length': '${_mediaBytes.length}',
              'content-type': 'video/x-matroska',
              'etag': '"media-v1"',
            },
            stream: _pauseAfter(_mediaBytes.sublist(0, 5), call.cancelToken),
          );
        }
        return _response(
          _mediaBytes,
          headers: {
            'content-length': '${_mediaBytes.length}',
            'content-type': 'video/x-matroska',
            'etag': '"media-v1"',
          },
        );
      },
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    final task = await harness.service.enqueue(_item);
    await _waitUntil(
      () => harness.service.taskForItem(_item.id)?.downloadedBytes == 5,
    );
    await harness.service.pause(task.id);
    await harness.service.resume(task.id);
    final completed = await _waitForTask(
      harness.service,
      (candidate) => candidate.status == DownloadStatus.completed,
    );

    expect(transport.calls.map((call) => call.offset), [0, 5, 0]);
    expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
  });

  test(
    'does not retry another endpoint after authentication failure',
    () async {
      final transport = _FakeTransport(
        uriCount: 4,
        handler: (call) async {
          throw const EmbyApiException('expired', statusCode: 401);
        },
      );
      final harness = await _Harness.create(transport);
      addTearDown(harness.dispose);

      await harness.service.enqueue(_item);
      final failed = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.failed,
      );

      expect(transport.calls, hasLength(1));
      expect(failed.lastErrorCode, 'authenticationRequired');
    },
  );

  test('restores an interrupted running task as paused', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport, initialize: false);
    addTearDown(harness.dispose);
    final tempPath = '${harness.directory.path}${Platform.pathSeparator}x.part';
    await File(tempPath).writeAsBytes(_mediaBytes.sublist(0, 3));
    final task = _task(
      tempPath: tempPath,
      finalPath: '${harness.directory.path}${Platform.pathSeparator}x.mkv',
      status: DownloadStatus.running,
    );
    await harness.repository.saveTask(task);

    await harness.service.initialize();
    final restored = harness.service.taskForItem(task.itemId);

    expect(restored?.status, DownloadStatus.paused);
    expect(restored?.downloadedBytes, 3);
    expect(restored?.lastErrorCode, 'processInterrupted');
    expect(transport.calls, isEmpty);
  });

  test(
    'queues interrupted work when the Android executor is reopened',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final executor = _FakeExecutor(running: false);
      final harness = await _Harness.create(
        transport,
        initialize: false,
        executor: executor,
      );
      addTearDown(harness.dispose);
      final tempPath =
          '${harness.directory.path}${Platform.pathSeparator}resume.part';
      await File(tempPath).writeAsBytes(_mediaBytes.sublist(0, 3));
      final task = _task(
        tempPath: tempPath,
        finalPath:
            '${harness.directory.path}${Platform.pathSeparator}resume.mkv',
        status: DownloadStatus.paused,
      ).copyWith(lastErrorCode: 'processInterrupted');
      await harness.repository.saveTask(task);

      await harness.service.initialize();
      final restored = harness.service.taskForItem(task.itemId);

      expect(restored?.status, DownloadStatus.queued);
      expect(restored?.downloadedBytes, 3);
      expect(restored?.lastErrorCode, isNull);
      expect(executor.starts, 1);
      expect(transport.calls, isEmpty);
    },
  );

  test(
    'queues a stale running task when the Android executor is reopened',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final executor = _FakeExecutor(running: false);
      final harness = await _Harness.create(
        transport,
        initialize: false,
        executor: executor,
      );
      addTearDown(harness.dispose);
      final tempPath =
          '${harness.directory.path}${Platform.pathSeparator}stale.part';
      await File(tempPath).writeAsBytes(_mediaBytes.sublist(0, 4));
      final task = _task(
        tempPath: tempPath,
        finalPath:
            '${harness.directory.path}${Platform.pathSeparator}stale.mkv',
        status: DownloadStatus.running,
      );
      await harness.repository.saveTask(task);

      await harness.service.initialize();
      final restored = harness.service.taskForItem(task.itemId);

      expect(restored?.status, DownloadStatus.queued);
      expect(restored?.downloadedBytes, 4);
      expect(restored?.lastErrorCode, isNull);
      expect(executor.starts, 1);
      expect(transport.calls, isEmpty);
    },
  );

  test('finishes an interrupted cancellation instead of resuming it', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final executor = _FakeExecutor(running: false);
    final harness = await _Harness.create(
      transport,
      initialize: false,
      executor: executor,
    );
    addTearDown(harness.dispose);
    final tempPath =
        '${harness.directory.path}${Platform.pathSeparator}cancel.part';
    final finalPath =
        '${harness.directory.path}${Platform.pathSeparator}cancel.mkv';
    await File(tempPath).writeAsBytes(_mediaBytes.sublist(0, 3));
    final task = _task(
      tempPath: tempPath,
      finalPath: finalPath,
      status: DownloadStatus.cancelling,
    );
    await harness.repository.saveTask(task);

    await harness.service.initialize();

    expect(harness.service.taskForItem(task.itemId), isNull);
    expect(await File(tempPath).exists(), isFalse);
    expect(await harness.repository.listTasks(_scope), isEmpty);
    expect(executor.starts, 0);
    expect(transport.calls, isEmpty);
  });

  test('deletes registered relative paths inside the download root', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final executor = _FakeExecutor(running: false);
    final harness = await _Harness.create(
      transport,
      initialize: false,
      executor: executor,
    );
    addTearDown(harness.dispose);
    final relativeTemp = path.join('parts', 'relative.part');
    final relativeFinal = path.join('media', 'relative.mkv');
    final relativeAsset = path.join('media', 'assets', 'poster.jpg');
    final tempFile = File(path.join(harness.directory.path, relativeTemp));
    final assetFile = File(path.join(harness.directory.path, relativeAsset));
    await tempFile.parent.create(recursive: true);
    await assetFile.parent.create(recursive: true);
    await tempFile.writeAsBytes(_mediaBytes.sublist(0, 3));
    await assetFile.writeAsBytes(const [1, 2, 3]);
    final baseTask = _task(
      tempPath: relativeTemp,
      finalPath: relativeFinal,
      status: DownloadStatus.cancelling,
    );
    final task = baseTask.copyWith(
      metadata: baseTask.metadata.copyWith(primaryImagePath: relativeAsset),
    );
    await harness.repository.saveTask(task);

    await harness.service.initialize();

    expect(await tempFile.exists(), isFalse);
    expect(await assetFile.exists(), isFalse);
    expect(await harness.repository.listTasks(_scope), isEmpty);
  });

  test('never deletes paths that escape the download root', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport, initialize: false);
    final outside = await Directory.systemTemp.createTemp(
      'emby-download-outside-',
    );
    addTearDown(harness.dispose);
    addTearDown(() => outside.delete(recursive: true));
    final outsideTemp = File(path.join(outside.path, 'outside.part'));
    final outsideFinal = File(path.join(outside.path, 'outside.mkv'));
    final outsideAsset = File(path.join(outside.path, 'outside.jpg'));
    final relativeTemp = path.relative(
      outsideTemp.path,
      from: harness.directory.path,
    );
    final relativeFinal = path.relative(
      outsideFinal.path,
      from: harness.directory.path,
    );
    final baseTask = _task(
      tempPath: relativeTemp,
      finalPath: relativeFinal,
      status: DownloadStatus.paused,
    );
    final task = baseTask.copyWith(
      metadata: baseTask.metadata.copyWith(primaryImagePath: outsideAsset.path),
    );
    await harness.repository.saveTask(task);
    await harness.service.initialize();
    for (final file in [outsideTemp, outsideFinal, outsideAsset]) {
      await file.writeAsBytes(const [1, 2, 3]);
    }

    await harness.service.delete(task.id);

    expect(await outsideTemp.exists(), isTrue);
    expect(await outsideFinal.exists(), isTrue);
    expect(await outsideAsset.exists(), isTrue);
    expect(await harness.repository.listTasks(_scope), isEmpty);
  });

  test(
    'migrates a completed relative media path for offline playback',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final harness = await _Harness.create(transport, initialize: false);
      addTearDown(harness.dispose);
      final relativeTemp = path.join('legacy', 'completed.part');
      final relativeFinal = path.join('legacy', 'completed.mkv');
      final finalFile = File(path.join(harness.directory.path, relativeFinal));
      await finalFile.parent.create(recursive: true);
      await finalFile.writeAsBytes(_mediaBytes);
      final task = _task(
        tempPath: relativeTemp,
        finalPath: relativeFinal,
        status: DownloadStatus.completed,
      );
      await harness.repository.complete(
        task,
        OfflineMediaItem(
          scope: task.scope,
          itemId: task.itemId,
          mediaSourceId: task.mediaSourceId,
          metadata: task.metadata,
          localMediaPath: relativeFinal,
          completedAt: task.updatedAt,
        ),
      );

      await harness.service.initialize();
      final restored = harness.service.taskForItem(task.itemId);
      final offline = await harness.service.offlineItem(task.itemId);

      expect(restored?.status, DownloadStatus.completed);
      expect(restored?.finalPath, path.normalize(finalFile.absolute.path));
      expect(offline?.localMediaPath, path.normalize(finalFile.absolute.path));
      expect(await finalFile.exists(), isTrue);
    },
  );

  test('invalidates a restored media path outside the download root', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport, initialize: false);
    final outside = await Directory.systemTemp.createTemp(
      'emby-download-invalid-',
    );
    addTearDown(harness.dispose);
    addTearDown(() => outside.delete(recursive: true));
    final outsideFinal = File(path.join(outside.path, 'completed.mkv'));
    await outsideFinal.writeAsBytes(_mediaBytes);
    final task = _task(
      tempPath: path.join(outside.path, 'completed.part'),
      finalPath: outsideFinal.path,
      status: DownloadStatus.completed,
    );
    await harness.repository.complete(
      task,
      OfflineMediaItem(
        scope: task.scope,
        itemId: task.itemId,
        mediaSourceId: task.mediaSourceId,
        metadata: task.metadata,
        localMediaPath: task.finalPath,
        completedAt: task.updatedAt,
      ),
    );

    await harness.service.initialize();
    final restored = harness.service.taskForItem(task.itemId);

    expect(restored?.status, DownloadStatus.failed);
    expect(restored?.lastErrorCode, 'invalidLocalPath');
    expect(await harness.service.offlineItem(task.itemId), isNull);
    expect(await outsideFinal.exists(), isTrue);
    expect(transport.calls, isEmpty);
  });

  test(
    'invalidates an offline record when its final file is missing',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final harness = await _Harness.create(transport, initialize: false);
      addTearDown(harness.dispose);
      final task = _task(
        tempPath:
            '${harness.directory.path}${Platform.pathSeparator}missing.part',
        finalPath:
            '${harness.directory.path}${Platform.pathSeparator}missing.mkv',
        status: DownloadStatus.completed,
      );
      await harness.repository.complete(
        task,
        OfflineMediaItem(
          scope: task.scope,
          itemId: task.itemId,
          mediaSourceId: task.mediaSourceId,
          metadata: task.metadata,
          localMediaPath: task.finalPath,
          completedAt: task.updatedAt,
        ),
      );

      await harness.service.initialize();

      expect(
        harness.service.taskForItem(task.itemId)?.status,
        DownloadStatus.failed,
      );
      expect(await harness.service.offlineItem(task.itemId), isNull);
    },
  );

  test(
    'rejects a task before persistence when storage is insufficient',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final preflight = _FakePreflight(
        storageError: const DownloadPreflightException(
          code: 'insufficientStorage',
          message: 'no space',
        ),
      );
      final harness = await _Harness.create(transport, preflight: preflight);
      addTearDown(harness.dispose);

      await expectLater(
        harness.service.enqueue(_item),
        throwsA(
          isA<DownloadPreflightException>().having(
            (error) => error.code,
            'code',
            'insufficientStorage',
          ),
        ),
      );

      expect(harness.service.tasks, isEmpty);
      expect(await harness.repository.listTasks(_scope), isEmpty);
      expect(transport.calls, isEmpty);
    },
  );

  test(
    'blocks network transfer while the Wi-Fi-only policy is unmet',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final preflight = _FakePreflight(
        networkError: const DownloadPreflightException(
          code: 'wifiRequired',
          message: 'wifi required',
        ),
      );
      final harness = await _Harness.create(transport, preflight: preflight);
      addTearDown(harness.dispose);

      await harness.service.enqueue(_item);
      final failed = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.failed,
      );

      expect(failed.lastErrorCode, 'wifiRequired');
      expect(preflight.networkPolicies, [true]);
      expect(transport.calls, isEmpty);
    },
  );

  test('allowing mobile data resumes a task blocked by Wi-Fi policy', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final preflight = _FakePreflight(blockWifiOnly: true);
    final settingsStore = MemoryDownloadSettingsStore();
    final harness = await _Harness.create(
      transport,
      preflight: preflight,
      settingsStore: settingsStore,
    );
    addTearDown(harness.dispose);
    await harness.service.enqueue(_item);
    await _waitForTask(
      harness.service,
      (task) =>
          task.status == DownloadStatus.failed &&
          task.lastErrorCode == 'wifiRequired',
    );

    await harness.service.setWifiOnly(false);
    final completed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.completed,
    );

    expect(completed.downloadedBytes, _mediaBytes.length);
    expect(preflight.networkPolicies, [true, false]);
    expect((await settingsStore.load(_scope)).wifiOnly, isFalse);
  });

  test(
    'keeps externally running tasks intact and does not duplicate transfer',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final executor = _FakeExecutor(running: true);
      final harness = await _Harness.create(
        transport,
        initialize: false,
        executor: executor,
      );
      addTearDown(harness.dispose);
      final task = _task(
        tempPath:
            '${harness.directory.path}${Platform.pathSeparator}external.part',
        finalPath:
            '${harness.directory.path}${Platform.pathSeparator}external.mkv',
        status: DownloadStatus.running,
      );
      await harness.repository.saveTask(task);

      await harness.service.initialize();
      await harness.service.pause(task.id);

      expect(
        harness.service.taskForItem(task.itemId)?.lastErrorCode,
        isNot('processInterrupted'),
      );
      expect(executor.starts, 1);
      expect(executor.commands, [(DownloadExecutorCommand.pause, task.id)]);
      expect(transport.calls, isEmpty);
    },
  );
}

class _Harness {
  _Harness({
    required this.database,
    required this.repository,
    required this.directory,
    required this.api,
    required this.service,
  });

  final LocalDatabase database;
  final DownloadRepository repository;
  final Directory directory;
  final EmbyApi api;
  final DownloadService service;

  static Future<_Harness> create(
    DownloadTransport transport, {
    bool initialize = true,
    DownloadPreflight? preflight,
    DownloadSettingsStore? settingsStore,
    DownloadExecutor? executor,
  }) async {
    final database = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => inMemoryDatabasePath,
    );
    final repository = DownloadRepository(database);
    final directory = await Directory.systemTemp.createTemp(
      'emby-download-test-',
    );
    final api = EmbyApi(_session, dio: Dio());
    final service = DownloadService(
      api: api,
      scope: _scope,
      repository: repository,
      transport: transport,
      directoryResolver: (_) async => directory,
      retryDelay: (_) async {},
      preflight: preflight,
      settingsStore: settingsStore,
      executor: executor,
      maxConcurrentDownloads: 1,
    );
    if (initialize) await service.initialize();
    return _Harness(
      database: database,
      repository: repository,
      directory: directory,
      api: api,
      service: service,
    );
  }

  Future<void> dispose() async {
    await service.shutdown();
    service.dispose();
    await api.dispose();
    await database.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _FakeTransport implements DownloadTransport {
  _FakeTransport({required this.handler, this.uriCount = 1});

  final Future<DownloadResponse> Function(_OpenCall call) handler;
  final int uriCount;
  final List<_OpenCall> calls = [];

  @override
  List<Uri> sourceUris({
    required String itemId,
    required String mediaSourceId,
  }) => List.generate(
    uriCount,
    (index) => Uri.parse('https://download.test/$itemId/$index'),
  );

  @override
  Future<DownloadResponse> open(
    Uri uri, {
    required CancelToken cancelToken,
    required int offset,
    String? etag,
  }) {
    final call = _OpenCall(
      index: calls.length,
      uri: uri,
      offset: offset,
      etag: etag,
      cancelToken: cancelToken,
    );
    calls.add(call);
    return handler(call);
  }
}

class _FakePreflight implements DownloadPreflight {
  _FakePreflight({
    this.storageError,
    this.networkError,
    this.blockWifiOnly = false,
  });

  final DownloadPreflightException? storageError;
  final DownloadPreflightException? networkError;
  final bool blockWifiOnly;
  final List<bool> networkPolicies = [];

  @override
  Future<void> verifyNetwork({required bool wifiOnly}) async {
    networkPolicies.add(wifiOnly);
    final error =
        networkError ??
        (blockWifiOnly && wifiOnly
            ? const DownloadPreflightException(
                code: 'wifiRequired',
                message: 'wifi required',
              )
            : null);
    if (error != null) throw error;
  }

  @override
  Future<void> verifyStorage({
    required Directory directory,
    required int? expectedBytes,
    required int downloadedBytes,
  }) async {
    final error = storageError;
    if (error != null) throw error;
  }
}

class _FakeExecutor implements DownloadExecutor {
  _FakeExecutor({required this.running});

  bool running;
  int starts = 0;
  final List<(DownloadExecutorCommand, String?)> commands = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> get isRunning async => running;

  @override
  Future<void> start() async {
    starts++;
    running = true;
  }

  @override
  Future<void> send(DownloadExecutorCommand command, {String? taskId}) async {
    commands.add((command, taskId));
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<void> dispose() => _changes.close();
}

class _OpenCall {
  const _OpenCall({
    required this.index,
    required this.uri,
    required this.offset,
    required this.etag,
    required this.cancelToken,
  });

  final int index;
  final Uri uri;
  final int offset;
  final String? etag;
  final CancelToken cancelToken;
}

DownloadResponse _response(
  List<int> bytes, {
  int statusCode = 200,
  Map<String, String>? headers,
}) => DownloadResponse(
  statusCode: statusCode,
  stream: Stream.value(bytes),
  headers:
      headers ??
      {'content-length': '${bytes.length}', 'content-type': 'video/x-matroska'},
);

Stream<List<int>> _pauseAfter(List<int> bytes, CancelToken token) async* {
  yield bytes;
  while (!token.isCancelled) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw DioException(
    type: DioExceptionType.cancel,
    requestOptions: RequestOptions(path: '/download'),
  );
}

Future<DownloadTaskRecord> _waitForTask(
  DownloadService service,
  bool Function(DownloadTaskRecord task) predicate,
) async {
  await _waitUntil(() {
    final task = service.taskForItem(_item.id);
    return task != null && predicate(task);
  });
  return service.taskForItem(_item.id)!;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Download condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

DownloadTaskRecord _task({
  required String tempPath,
  required String finalPath,
  required DownloadStatus status,
}) {
  final now = DateTime.utc(2026, 7, 30);
  return DownloadTaskRecord(
    id: 'task-1',
    scope: _scope,
    itemId: _item.id,
    mediaSourceId: 'source-1',
    sourceKind: DownloadSourceKind.original,
    sourceFingerprint: 'fingerprint',
    status: status,
    downloadedBytes: 0,
    retryCount: 0,
    tempPath: tempPath,
    finalPath: finalPath,
    metadata: OfflineMediaMetadata.fromItem(_item, _item.mediaSources.single),
    createdAt: now,
    updatedAt: now,
  );
}

const _scope = ServerScope(serverId: 'server-1', userId: 'user-1');

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'secret-token',
  deviceId: 'device-1',
);

const _item = EmbyItem(
  id: 'item-1',
  name: 'Offline Test',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
  mediaSources: [
    PlaybackMediaSource(
      id: 'source-1',
      supportsDirectPlay: true,
      supportsDirectStream: true,
      supportsTranscoding: true,
      mediaStreams: [],
      transcodingReasons: [],
      container: 'mkv',
      size: 12,
    ),
  ],
);

const _mediaBytes = <int>[
  0x1A,
  0x45,
  0xDF,
  0xA3,
  0x93,
  0x42,
  0x82,
  0x88,
  0x6D,
  0x61,
  0x74,
  0x72,
];
