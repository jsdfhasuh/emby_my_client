import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/downloads/download_executor.dart';
import 'package:emby_my_client/downloads/download_integrity.dart';
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
    expect(
      path.dirname(completed.finalPath),
      path.join(harness.directory.path, 'media'),
    );
    expect(
      path.dirname(completed.tempPath),
      path.join(harness.directory.path, 'parts'),
    );
    expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
    expect(await File(completed.tempPath).exists(), isFalse);
    expect(offline?.localMediaPath, completed.finalPath);
    expect(offline?.metadata.name, _item.name);
  });

  test('validates and persists a SHA-256 response digest', () async {
    final digest = _digest(sha256, _mediaBytes);
    final transport = _FakeTransport(
      handler: (call) async => _response(
        _mediaBytes,
        headers: {
          'content-length': '${_mediaBytes.length}',
          'content-type': 'video/x-matroska',
          'digest': 'sha-256=$digest',
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
    final stored = (await harness.repository.listTasks(_scope)).single;

    expect(completed.integrity?.algorithm, 'sha-256');
    expect(completed.integrity?.digest, digest);
    expect(stored.integrity, completed.integrity);
  });

  test('validates Content-MD5 when the server provides it', () async {
    final digest = _digest(md5, _mediaBytes);
    final transport = _FakeTransport(
      handler: (call) async => _response(
        _mediaBytes,
        headers: {
          'content-length': '${_mediaBytes.length}',
          'content-type': 'video/x-matroska',
          'content-md5': digest,
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

    expect(completed.integrity?.algorithm, 'md5');
    expect(completed.integrity?.digest, digest);
  });

  test('deletes a corrupt payload after a checksum mismatch', () async {
    final transport = _FakeTransport(
      uriCount: 3,
      handler: (call) async => _response(
        _mediaBytes,
        headers: {
          'content-length': '${_mediaBytes.length}',
          'content-type': 'video/x-matroska',
          'digest': 'sha-256=${_digest(sha256, _otherMediaBytes)}',
        },
      ),
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final failed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.failed,
    );

    expect(failed.lastErrorCode, 'checksumMismatch');
    expect(failed.downloadedBytes, 0);
    expect(failed.etag, isNull);
    expect(failed.integrity, isNull);
    expect(transport.calls, hasLength(1));
    expect(await File(failed.tempPath).exists(), isFalse);
    expect(await File(failed.finalPath).exists(), isFalse);
  });

  test('pauses and resumes with Range and If-Range', () async {
    final digest = _digest(sha256, _mediaBytes);
    final transport = _FakeTransport(
      handler: (call) async {
        if (call.offset == 0 && call.index == 0) {
          return DownloadResponse(
            statusCode: 200,
            headers: {
              'content-length': '${_mediaBytes.length}',
              'content-type': 'video/x-matroska',
              'etag': '"media-v1"',
              'digest': 'sha-256=$digest',
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
    final persisted = (await harness.repository.listTasks(_scope)).single;
    expect(persisted.integrity?.digest, digest);
    await harness.service.resume(task.id);
    final completed = await _waitForTask(
      harness.service,
      (candidate) => candidate.status == DownloadStatus.completed,
    );

    expect(transport.calls, hasLength(2));
    expect(transport.calls[1].offset, 4);
    expect(transport.calls[1].etag, '"media-v1"');
    expect(completed.integrity?.digest, digest);
    expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
  });

  test('restarts from zero when a whole-file digest changes', () async {
    final firstDigest = _digest(sha256, _mediaBytes);
    final secondDigest = _digest(sha256, _otherMediaBytes);
    var discardedChangedResponse = false;
    final transport = _FakeTransport(
      handler: (call) async {
        if (call.index == 0) {
          return DownloadResponse(
            statusCode: 200,
            headers: {
              'content-length': '${_mediaBytes.length}',
              'content-type': 'video/x-matroska',
              'etag': '"media-v1"',
              'digest': 'sha-256=$firstDigest',
            },
            stream: _pauseAfter(_mediaBytes.sublist(0, 4), call.cancelToken),
          );
        }
        if (call.index == 1) {
          return DownloadResponse(
            statusCode: 206,
            headers: {
              'content-length': '${_otherMediaBytes.length - call.offset}',
              'content-range':
                  'bytes ${call.offset}-${_otherMediaBytes.length - 1}/'
                  '${_otherMediaBytes.length}',
              'content-type': 'video/x-matroska',
              'etag': '"media-v1"',
              'digest': 'sha-256=$secondDigest',
            },
            stream: Stream<List<int>>.multi((controller) {
              controller.onCancel = () {
                discardedChangedResponse = true;
              };
            }),
          );
        }
        return _response(
          _otherMediaBytes,
          headers: {
            'content-length': '${_otherMediaBytes.length}',
            'content-type': 'video/x-matroska',
            'etag': '"media-v2"',
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

    expect(transport.calls.map((call) => call.offset), [0, 4, 0]);
    expect(discardedChangedResponse, isTrue);
    expect(completed.integrity?.digest, secondDigest);
    expect(await File(completed.finalPath).readAsBytes(), _otherMediaBytes);
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

  test('does not retry another endpoint after HTTP 403', () async {
    final transport = _FakeTransport(
      uriCount: 4,
      handler: (call) async {
        throw const EmbyApiException('forbidden', statusCode: 403);
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
    expect(failed.retryCount, 0);
    expect(failed.lastErrorCode, 'authenticationRequired');
  });

  test('retries HTTP 429 with bounded exponential delays', () async {
    final delays = <Duration>[];
    final transport = _FakeTransport(
      handler: (call) async {
        if (call.index < 2) {
          throw const EmbyApiException('limited', statusCode: 429);
        }
        return _response(_mediaBytes);
      },
    );
    final harness = await _Harness.create(
      transport,
      retryDelay: (delay) async => delays.add(delay),
    );
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final completed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.completed,
    );

    expect(transport.calls, hasLength(3));
    expect(delays, const [Duration(seconds: 1), Duration(seconds: 2)]);
    expect(completed.retryCount, 2);
  });

  test('stops retrying after three HTTP 5xx responses', () async {
    final delays = <Duration>[];
    final transport = _FakeTransport(
      handler: (call) async {
        throw const EmbyApiException('unavailable', statusCode: 503);
      },
    );
    final harness = await _Harness.create(
      transport,
      retryDelay: (delay) async => delays.add(delay),
    );
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final failed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.failed,
    );

    expect(transport.calls, hasLength(3));
    expect(delays, const [Duration(seconds: 1), Duration(seconds: 2)]);
    expect(failed.retryCount, 2);
    expect(failed.lastErrorCode, 'serverError');
  });

  test('fails with rateLimited after the final HTTP 429 response', () async {
    final transport = _FakeTransport(
      handler: (call) async {
        throw const EmbyApiException('limited', statusCode: 429);
      },
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final failed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.failed,
    );

    expect(transport.calls, hasLength(3));
    expect(failed.lastErrorCode, 'rateLimited');
  });

  test('restarts from zero when the ETag changes during resume', () async {
    var discardedChangedResponse = false;
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
            stream: _pauseAfter(_mediaBytes.sublist(0, 4), call.cancelToken),
          );
        }
        if (call.index == 1) {
          return DownloadResponse(
            statusCode: 206,
            headers: {
              'content-length': '${_mediaBytes.length - call.offset}',
              'content-range':
                  'bytes ${call.offset}-${_mediaBytes.length - 1}/'
                  '${_mediaBytes.length}',
              'content-type': 'video/x-matroska',
              'etag': '"media-v2"',
            },
            stream: Stream<List<int>>.multi((controller) {
              controller.onCancel = () {
                discardedChangedResponse = true;
              };
            }),
          );
        }
        return _response(
          _mediaBytes,
          headers: {
            'content-length': '${_mediaBytes.length}',
            'content-type': 'video/x-matroska',
            'etag': '"media-v2"',
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

    expect(transport.calls.map((call) => call.offset), [0, 4, 0]);
    expect(discardedChangedResponse, isTrue);
    expect(completed.etag, '"media-v2"');
  });

  test('keeps a short partial file after a content length mismatch', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(
        _mediaBytes.sublist(0, 8),
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
    final failed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.failed,
    );

    expect(failed.lastErrorCode, 'contentLengthMismatch');
    expect(failed.downloadedBytes, 8);
    expect(await File(failed.tempPath).length(), 8);
    expect(await File(failed.finalPath).exists(), isFalse);
  });

  test('finalizes a complete part file after HTTP 416', () async {
    var discardedResponse = false;
    final transport = _FakeTransport(
      handler: (call) async => DownloadResponse(
        statusCode: 416,
        headers: {'content-range': 'bytes */${_mediaBytes.length}'},
        stream: Stream<List<int>>.multi((controller) {
          controller.onCancel = () {
            discardedResponse = true;
          };
        }),
      ),
    );
    final harness = await _Harness.create(transport, initialize: false);
    addTearDown(harness.dispose);
    final tempPath = path.join(harness.directory.path, 'parts', 'full.part');
    final finalPath = path.join(harness.directory.path, 'media', 'full.mkv');
    await File(tempPath).create(recursive: true);
    await File(tempPath).writeAsBytes(_mediaBytes);
    final task =
        _task(
          tempPath: tempPath,
          finalPath: finalPath,
          status: DownloadStatus.paused,
        ).copyWith(
          downloadedBytes: _mediaBytes.length,
          expectedBytes: _mediaBytes.length,
          etag: '"media-v1"',
        );
    await harness.repository.saveTask(task);
    await harness.service.initialize();

    await harness.service.resume(task.id);
    final completed = await _waitForTask(
      harness.service,
      (candidate) => candidate.status == DownloadStatus.completed,
    );

    expect(transport.calls.single.offset, _mediaBytes.length);
    expect(discardedResponse, isTrue);
    expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
    expect(await File(completed.tempPath).exists(), isFalse);
  });

  test('discards a non-media response before reporting failure', () async {
    var discardedResponse = false;
    final transport = _FakeTransport(
      handler: (call) async => DownloadResponse(
        statusCode: 200,
        headers: {'content-length': '2', 'content-type': 'application/json'},
        stream: Stream<List<int>>.multi((controller) {
          controller.onCancel = () {
            discardedResponse = true;
          };
        }),
      ),
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final failed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.failed,
    );

    expect(discardedResponse, isTrue);
    expect(failed.lastErrorCode, 'nonMediaContentType');
    expect(await File(failed.tempPath).exists(), isFalse);
  });

  test('enqueue is idempotent after a download completes', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    final first = await harness.service.enqueue(_item);
    final completed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.completed,
    );
    final repeated = await harness.service.enqueue(_item);

    expect(first.id, completed.id);
    expect(repeated.id, completed.id);
    expect(transport.calls, hasLength(1));
    expect(harness.service.tasks, hasLength(1));
  });

  test('reports a non-space file write failure without waiting', () async {
    final transport = _FakeTransport(
      handler: (call) async => DownloadResponse(
        statusCode: 200,
        headers: {
          'content-length': '${_mediaBytes.length}',
          'content-type': 'video/x-matroska',
        },
        stream: _fileWriteFailureAfter(_mediaBytes.sublist(0, 4)),
      ),
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);

    await harness.service.enqueue(_item);
    final failed = await _waitForTask(
      harness.service,
      (candidate) => candidate.status == DownloadStatus.failed,
    );

    expect(failed.lastErrorCode, 'storageError');
    expect(failed.status, DownloadStatus.failed);
    expect(failed.downloadedBytes, 4);
    expect(await File(failed.tempPath).length(), 4);
    expect(await File(failed.finalPath).exists(), isFalse);
  });

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

  test('resets a stale checkpoint when its partial file is missing', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport, initialize: false);
    addTearDown(harness.dispose);
    final task =
        _task(
          tempPath: path.join(harness.directory.path, 'missing.part'),
          finalPath: path.join(harness.directory.path, 'missing.mkv'),
          status: DownloadStatus.paused,
        ).copyWith(
          downloadedBytes: 4,
          etag: '"stale-etag"',
          integrity: DownloadIntegrity.fromStored(
            'sha-256',
            _digest(sha256, _mediaBytes),
          ),
        );
    await harness.repository.saveTask(task);

    await harness.service.initialize();
    final restored = harness.service.taskForItem(task.itemId);

    expect(restored?.status, DownloadStatus.paused);
    expect(restored?.downloadedBytes, 0);
    expect(restored?.etag, isNull);
    expect(restored?.integrity, isNull);
    expect(
      (await harness.repository.listTasks(_scope)).single.downloadedBytes,
      0,
    );
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

  test('marks a completed item cancelling before deleting its files', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport);
    addTearDown(harness.dispose);
    await harness.service.enqueue(_item);
    final completed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.completed,
    );
    final observed = <DownloadStatus?>[];
    harness.service.addListener(() {
      observed.add(harness.service.taskForItem(_item.id)?.status);
    });

    await harness.service.delete(completed.id);

    expect(observed, contains(DownloadStatus.cancelling));
    expect(observed.last, isNull);
    expect(await File(completed.finalPath).exists(), isFalse);
    expect(await harness.service.offlineItem(_item.id), isNull);
    expect(await harness.repository.listTasks(_scope), isEmpty);
  });

  test(
    'finishes deletion of a completed item after process interruption',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final harness = await _Harness.create(transport, initialize: false);
      addTearDown(harness.dispose);
      final finalPath = path.join(harness.directory.path, 'legacy.mkv');
      await File(finalPath).writeAsBytes(_mediaBytes);
      final task =
          _task(
            tempPath: '$finalPath.part',
            finalPath: finalPath,
            status: DownloadStatus.cancelling,
          ).copyWith(
            downloadedBytes: _mediaBytes.length,
            expectedBytes: _mediaBytes.length,
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

      expect(await File(finalPath).exists(), isFalse);
      expect(await harness.service.offlineItem(task.itemId), isNull);
      expect(await harness.repository.listTasks(_scope), isEmpty);
      expect(transport.calls, isEmpty);
    },
  );

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
    final relativeAsset = path.join('assets', 'poster.jpg');
    final legacyAsset = path.join('media', 'assets', 'subtitle.srt');
    final temporaryAsset = path.join(
      'parts',
      'assets',
      'task-1',
      'poster.jpg.part',
    );
    final tempFile = File(path.join(harness.directory.path, relativeTemp));
    final assetFile = File(path.join(harness.directory.path, relativeAsset));
    final legacyAssetFile = File(
      path.join(harness.directory.path, legacyAsset),
    );
    final temporaryAssetFile = File(
      path.join(harness.directory.path, temporaryAsset),
    );
    for (final file in [
      tempFile,
      assetFile,
      legacyAssetFile,
      temporaryAssetFile,
    ]) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(const [1, 2, 3]);
    }
    final baseTask = _task(
      tempPath: relativeTemp,
      finalPath: relativeFinal,
      status: DownloadStatus.cancelling,
    );
    final task = baseTask.copyWith(
      metadata: baseTask.metadata.copyWith(
        primaryImagePath: relativeAsset,
        mediaStreams: [
          {'Type': 'Subtitle', 'IsExternal': true, 'DeliveryUrl': legacyAsset},
        ],
      ),
    );
    await harness.repository.saveTask(task);

    await harness.service.initialize();

    expect(await tempFile.exists(), isFalse);
    expect(await assetFile.exists(), isFalse);
    expect(await legacyAssetFile.exists(), isFalse);
    expect(await temporaryAssetFile.exists(), isFalse);
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
      expect(
        harness.service.taskForItem(task.itemId)?.lastErrorCode,
        'missingFile',
      );
      expect(
        harness.service.taskForItem(task.itemId)?.requiresFreshDownload,
        isTrue,
      );
      expect(await harness.service.offlineItem(task.itemId), isNull);
    },
  );

  test('invalidates a truncated completed file during startup', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport, initialize: false);
    addTearDown(harness.dispose);
    final finalPath = path.join(harness.directory.path, 'truncated.mkv');
    await File(finalPath).writeAsBytes(_mediaBytes.sublist(0, 4));
    final task =
        _task(
          tempPath: '$finalPath.part',
          finalPath: finalPath,
          status: DownloadStatus.completed,
        ).copyWith(
          downloadedBytes: _mediaBytes.length,
          expectedBytes: _mediaBytes.length,
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

    final failed = harness.service.taskForItem(task.itemId);
    expect(failed?.status, DownloadStatus.failed);
    expect(failed?.lastErrorCode, 'localMediaCorrupt');
    expect(failed?.downloadedBytes, 4);
    expect(failed?.requiresFreshDownload, isTrue);
    expect(await harness.service.offlineItem(task.itemId), isNull);
    expect(await File(finalPath).length(), 4);
    expect(transport.calls, isEmpty);
  });

  test('keeps a corrupt completed file invalidated after restart', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final harness = await _Harness.create(transport, initialize: false);
    addTearDown(harness.dispose);
    final finalPath = path.join(harness.directory.path, 'corrupt-restart.mkv');
    await File(finalPath).writeAsBytes(_mediaBytes.sublist(0, 4));
    final task =
        _task(
          tempPath: '$finalPath.part',
          finalPath: finalPath,
          status: DownloadStatus.failed,
        ).copyWith(
          downloadedBytes: 4,
          expectedBytes: _mediaBytes.length,
          lastErrorCode: 'localMediaCorrupt',
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
    expect(restored?.lastErrorCode, 'localMediaCorrupt');
    expect(restored?.requiresFreshDownload, isTrue);
    expect(await harness.service.offlineItem(task.itemId), isNull);
    expect(await File(finalPath).length(), 4);
    expect(transport.calls, isEmpty);
  });

  test(
    'invalidates a completed file changed before offline playback',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final harness = await _Harness.create(transport);
      addTearDown(harness.dispose);
      await harness.service.enqueue(_item);
      final completed = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.completed,
      );
      await File(completed.finalPath).writeAsBytes(_mediaBytes.sublist(0, 4));

      final offline = await harness.service.offlineItem(_item.id);

      final failed = harness.service.taskForItem(_item.id);
      expect(offline, isNull);
      expect(failed?.status, DownloadStatus.failed);
      expect(failed?.lastErrorCode, 'localMediaCorrupt');
      expect(failed?.downloadedBytes, 4);
      expect(await File(completed.finalPath).length(), 4);
      expect(transport.calls, hasLength(1));
    },
  );

  test(
    'redownloads corrupt local media from zero after explicit action',
    () async {
      final digest = _digest(sha256, _mediaBytes);
      final transport = _FakeTransport(
        handler: (call) async => call.index == 0
            ? _response(
                _mediaBytes,
                headers: {
                  'content-length': '${_mediaBytes.length}',
                  'content-type': 'video/x-matroska',
                  'etag': '"media-v1"',
                  'digest': 'sha-256=$digest',
                },
              )
            : _response(_mediaBytes),
      );
      final harness = await _Harness.create(transport);
      addTearDown(harness.dispose);
      await harness.service.enqueue(_item);
      final completed = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.completed,
      );
      await File(completed.finalPath).writeAsBytes(_mediaBytes.sublist(0, 4));
      expect(await harness.service.offlineItem(_item.id), isNull);

      await harness.service.redownload(completed.id);
      final redownloaded = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.completed,
      );

      expect(transport.calls, hasLength(2));
      expect(transport.calls.last.offset, 0);
      expect(transport.calls.last.etag, isNull);
      expect(redownloaded.integrity, isNull);
      expect(await File(redownloaded.finalPath).readAsBytes(), _mediaBytes);
      expect(await harness.service.offlineItem(_item.id), isNotNull);
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
      final waiting = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.waitingForNetwork,
      );

      expect(waiting.lastErrorCode, 'wifiRequired');
      expect(preflight.networkPolicies, isNotEmpty);
      expect(preflight.networkPolicies, everyElement(isTrue));
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
          task.status == DownloadStatus.waitingForNetwork &&
          task.lastErrorCode == 'wifiRequired',
    );

    await harness.service.setWifiOnly(false);
    final completed = await _waitForTask(
      harness.service,
      (task) => task.status == DownloadStatus.completed,
    );

    expect(completed.downloadedBytes, _mediaBytes.length);
    expect(preflight.networkPolicies, containsAllInOrder([true, false]));
    expect((await settingsStore.load(_scope)).wifiOnly, isFalse);
  });

  test('a manually paused network-waiting task stays paused', () async {
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

    final task = await harness.service.enqueue(_item);
    await _waitForTask(
      harness.service,
      (candidate) => candidate.status == DownloadStatus.waitingForNetwork,
    );
    await harness.service.pause(task.id);
    preflight.setNetworkError(null);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final paused = harness.service.taskForItem(_item.id)!;
    expect(paused.status, DownloadStatus.paused);
    expect(paused.lastErrorCode, isNull);
    expect(transport.calls, isEmpty);
  });

  test(
    'waits when Wi-Fi disappears mid-transfer and resumes with Range',
    () async {
      final preflight = _FakePreflight();
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
      final harness = await _Harness.create(transport, preflight: preflight);
      addTearDown(harness.dispose);

      await harness.service.enqueue(_item);
      await _waitUntil(
        () => harness.service.taskForItem(_item.id)?.downloadedBytes == 4,
      );
      preflight.setNetworkError(
        const DownloadPreflightException(
          code: 'wifiRequired',
          message: 'wifi required',
        ),
      );
      final waiting = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.waitingForNetwork,
      );

      expect(waiting.downloadedBytes, 4);
      expect(waiting.lastErrorCode, 'wifiRequired');
      expect(transport.calls, hasLength(1));

      preflight.setNetworkError(null);
      final completed = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.completed,
      );

      expect(transport.calls.map((call) => call.offset), [0, 4]);
      expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
    },
  );

  test(
    'restored network-waiting tasks resume when connectivity is valid',
    () async {
      final transport = _FakeTransport(
        handler: (call) async => _response(_mediaBytes),
      );
      final harness = await _Harness.create(transport, initialize: false);
      addTearDown(harness.dispose);
      final task = _task(
        tempPath:
            '${harness.directory.path}${Platform.pathSeparator}waiting.part',
        finalPath:
            '${harness.directory.path}${Platform.pathSeparator}waiting.mkv',
        status: DownloadStatus.waitingForNetwork,
      ).copyWith(lastErrorCode: 'networkUnavailable');
      await harness.repository.saveTask(task);

      await harness.service.initialize();
      final completed = await _waitForTask(
        harness.service,
        (candidate) => candidate.status == DownloadStatus.completed,
      );

      expect(completed.lastErrorCode, isNull);
      expect(transport.calls, hasLength(1));
    },
  );

  test(
    'network failure cleanup cannot override a later manual pause',
    () async {
      final preflight = _DelayedNetworkBlockPreflight();
      final transport = _FakeTransport(
        handler: (call) async => DownloadResponse(
          statusCode: 200,
          headers: {
            'content-length': '${_mediaBytes.length}',
            'content-type': 'video/x-matroska',
          },
          stream: _networkFailureAfter(_mediaBytes.sublist(0, 4)),
        ),
      );
      final harness = await _Harness.create(transport, preflight: preflight);
      addTearDown(harness.dispose);

      final task = await harness.service.enqueue(_item);
      await preflight.recheckStarted;
      await harness.service.pause(task.id);
      preflight.releaseRecheck();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        harness.service.taskForItem(_item.id)?.status,
        DownloadStatus.paused,
      );
      expect(
        (await harness.repository.listTasks(_scope)).single.status,
        DownloadStatus.paused,
      );
    },
  );

  test('network failure cleanup cannot resurrect a cancelled task', () async {
    final preflight = _DelayedNetworkBlockPreflight();
    final transport = _FakeTransport(
      handler: (call) async => DownloadResponse(
        statusCode: 200,
        headers: {
          'content-length': '${_mediaBytes.length}',
          'content-type': 'video/x-matroska',
        },
        stream: _networkFailureAfter(_mediaBytes.sublist(0, 4)),
      ),
    );
    final harness = await _Harness.create(transport, preflight: preflight);
    addTearDown(harness.dispose);

    final task = await harness.service.enqueue(_item);
    await preflight.recheckStarted;
    final deleting = harness.service.delete(task.id);
    await Future<void>.delayed(Duration.zero);
    preflight.releaseRecheck();
    await deleting;

    expect(harness.service.taskForItem(_item.id), isNull);
    expect(await harness.repository.listTasks(_scope), isEmpty);
    expect(await File(task.tempPath).exists(), isFalse);
  });

  test(
    'waits after storage fills mid-transfer and resumes with Range',
    () async {
      final preflight = _FakePreflight();
      final transport = _FakeTransport(
        handler: (call) async {
          if (call.index == 0) {
            preflight.storageError = const DownloadPreflightException(
              code: 'insufficientStorage',
              message: 'no space',
            );
            return DownloadResponse(
              statusCode: 200,
              headers: {
                'content-length': '${_mediaBytes.length}',
                'content-type': 'video/x-matroska',
                'etag': '"media-v1"',
              },
              stream: _storageFullAfter(_mediaBytes.sublist(0, 4)),
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
      final harness = await _Harness.create(
        transport,
        preflight: preflight,
        storageRecheckInterval: const Duration(milliseconds: 5),
      );
      addTearDown(harness.dispose);

      await harness.service.enqueue(_item);
      final waiting = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.waitingForStorage,
      );

      expect(waiting.downloadedBytes, 4);
      expect(waiting.lastErrorCode, 'insufficientStorage');
      expect(await File(waiting.tempPath).length(), 4);

      preflight.storageError = null;
      final completed = await _waitForTask(
        harness.service,
        (task) => task.status == DownloadStatus.completed,
      );

      expect(transport.calls.map((call) => call.offset), [0, 4]);
      expect(transport.calls[1].etag, '"media-v1"');
      expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
    },
  );

  test(
    'restored storage-waiting task stays active and resumes from its part file',
    () async {
      final preflight = _FakePreflight(
        storageError: const DownloadPreflightException(
          code: 'insufficientStorage',
          message: 'no space',
        ),
      );
      final transport = _FakeTransport(
        handler: (call) async => _response(
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
        ),
      );
      final harness = await _Harness.create(
        transport,
        initialize: false,
        preflight: preflight,
        storageRecheckInterval: const Duration(milliseconds: 5),
      );
      addTearDown(harness.dispose);
      final tempPath = path.join(harness.directory.path, 'storage.part');
      final finalPath = path.join(harness.directory.path, 'storage.mkv');
      await File(tempPath).writeAsBytes(_mediaBytes.sublist(0, 4));
      final task =
          _task(
            tempPath: tempPath,
            finalPath: finalPath,
            status: DownloadStatus.waitingForStorage,
          ).copyWith(
            downloadedBytes: 4,
            expectedBytes: _mediaBytes.length,
            etag: '"media-v1"',
            lastErrorCode: 'insufficientStorage',
          );
      await harness.repository.saveTask(task);

      await harness.service.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 15));

      expect(harness.service.hasActiveWork, isTrue);
      expect(transport.calls, isEmpty);
      expect(
        harness.service.taskForItem(_item.id)?.status,
        DownloadStatus.waitingForStorage,
      );

      preflight.storageError = null;
      final completed = await _waitForTask(
        harness.service,
        (candidate) => candidate.status == DownloadStatus.completed,
      );

      expect(transport.calls.map((call) => call.offset), [4]);
      expect(transport.calls.single.etag, '"media-v1"');
      expect(await File(completed.finalPath).readAsBytes(), _mediaBytes);
    },
  );

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
        harness.service.taskForItem(task.itemId)?.status,
        DownloadStatus.running,
      );
      expect(
        harness.service.taskForItem(task.itemId)?.lastErrorCode,
        isNot('processInterrupted'),
      );
      expect(executor.starts, 1);
      expect(executor.commands, [(DownloadExecutorCommand.pause, task.id)]);
      expect(transport.calls, isEmpty);
    },
  );

  test(
    'routes completed deletion to a running worker without local writes',
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
      final finalPath = path.join(harness.directory.path, 'completed.mkv');
      await File(finalPath).writeAsBytes(_mediaBytes);
      final task =
          _task(
            tempPath: '$finalPath.part',
            finalPath: finalPath,
            status: DownloadStatus.completed,
          ).copyWith(
            downloadedBytes: _mediaBytes.length,
            expectedBytes: _mediaBytes.length,
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
      await harness.service.delete(task.id);

      expect(executor.commands, [(DownloadExecutorCommand.delete, task.id)]);
      expect(
        harness.service.taskForItem(task.itemId)?.status,
        DownloadStatus.completed,
      );
      expect(await File(finalPath).exists(), isTrue);
      expect(transport.calls, isEmpty);
    },
  );

  test(
    'routes commands to a running executor without competing database writes',
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
        status: DownloadStatus.paused,
      );
      await harness.repository.saveTask(task);

      await harness.service.initialize();
      await harness.service.resume(task.id);
      await harness.service.delete(task.id);

      expect(
        harness.service.taskForItem(task.itemId)?.status,
        DownloadStatus.paused,
      );
      expect(executor.starts, 0);
      expect(executor.commands, [
        (DownloadExecutorCommand.resume, task.id),
        (DownloadExecutorCommand.delete, task.id),
      ]);
      expect(transport.calls, isEmpty);
    },
  );

  test('notifies a running executor when download settings change', () async {
    final transport = _FakeTransport(
      handler: (call) async => _response(_mediaBytes),
    );
    final executor = _FakeExecutor(running: true);
    final settingsStore = MemoryDownloadSettingsStore();
    final harness = await _Harness.create(
      transport,
      executor: executor,
      settingsStore: settingsStore,
    );
    addTearDown(harness.dispose);

    await harness.service.setWifiOnly(false);

    expect(executor.commands, [
      (DownloadExecutorCommand.settingsChanged, null),
    ]);
    expect((await settingsStore.load(_scope)).wifiOnly, isFalse);
  });
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
    DownloadRetryDelay? retryDelay,
    Duration storageRecheckInterval = const Duration(seconds: 15),
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
      retryDelay: retryDelay ?? (_) async {},
      preflight: preflight,
      settingsStore: settingsStore,
      executor: executor,
      maxConcurrentDownloads: 1,
      storageRecheckInterval: storageRecheckInterval,
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

  DownloadPreflightException? storageError;
  DownloadPreflightException? networkError;
  final bool blockWifiOnly;
  final List<bool> networkPolicies = [];
  final StreamController<void> _networkChanges =
      StreamController<void>.broadcast(sync: true);

  @override
  Stream<void> get networkChanges => _networkChanges.stream;

  void setNetworkError(DownloadPreflightException? error) {
    networkError = error;
    _networkChanges.add(null);
  }

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

class _DelayedNetworkBlockPreflight implements DownloadPreflight {
  final Completer<void> _recheckStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  var _networkChecks = 0;

  Future<void> get recheckStarted => _recheckStarted.future;

  void releaseRecheck() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Stream<void> get networkChanges => const Stream<void>.empty();

  @override
  Future<void> verifyNetwork({required bool wifiOnly}) async {
    _networkChecks++;
    if (_networkChecks == 1) return;
    if (!_recheckStarted.isCompleted) _recheckStarted.complete();
    await _release.future;
    throw const DownloadPreflightException(
      code: 'wifiRequired',
      message: 'wifi required',
    );
  }

  @override
  Future<void> verifyStorage({
    required Directory directory,
    required int? expectedBytes,
    required int downloadedBytes,
  }) async {}
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

String _digest(Hash hash, List<int> bytes) =>
    base64Encode(hash.convert(bytes).bytes);

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

Stream<List<int>> _networkFailureAfter(List<int> bytes) async* {
  yield bytes;
  throw DioException(
    type: DioExceptionType.connectionError,
    requestOptions: RequestOptions(path: '/download'),
  );
}

Stream<List<int>> _storageFullAfter(List<int> bytes) async* {
  yield bytes;
  throw const FileSystemException(
    'No space left on device',
    'offline.part',
    OSError('No space left on device', 28),
  );
}

Stream<List<int>> _fileWriteFailureAfter(List<int> bytes) async* {
  yield bytes;
  throw const FileSystemException(
    'Permission denied',
    'offline.part',
    OSError('Permission denied', 13),
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

const _otherMediaBytes = <int>[
  0x1A,
  0x45,
  0xDF,
  0xA3,
  0x93,
  0x42,
  0x82,
  0x88,
  0x77,
  0x65,
  0x62,
  0x6D,
];
