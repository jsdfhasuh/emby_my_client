import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/downloads/download_repository.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/offline/offline_progress_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('pushes a farther local position once with PlaybackStopped', () async {
    final harness = await _SyncHarness.create(
      serverUserData: const {'PlaybackPositionTicks': 100, 'Played': false},
      localPositionTicks: 200,
    );
    addTearDown(harness.dispose);

    final first = await harness.sync.sync();
    final second = await harness.sync.sync();
    final stored = await harness.repository.loadProgress(_scope, 'item-1');

    expect(first.synced, 1);
    expect(second.synced, 0);
    expect(stored?.syncStatus, 'synced');
    expect(harness.requests.map((request) => request.path), [
      '/Users/user-1/Items',
      '/Sessions/Playing/Stopped',
    ]);
    final report = harness.requests.last.data as Map<String, dynamic>;
    expect(report['PositionTicks'], 200);
    expect(report.containsKey('PlaySessionId'), isFalse);
  });

  test('adopts a completed or farther server state without pushing', () async {
    final completed = await _SyncHarness.create(
      serverUserData: const {'PlaybackPositionTicks': 0, 'Played': true},
      localPositionTicks: 400,
    );
    addTearDown(completed.dispose);
    await completed.sync.sync();
    final completedRecord = await completed.repository.loadProgress(
      _scope,
      'item-1',
    );

    expect(completedRecord?.played, isTrue);
    expect(completedRecord?.positionTicks, 0);
    expect(completed.requests, hasLength(1));

    final farther = await _SyncHarness.create(
      serverUserData: const {'PlaybackPositionTicks': 900, 'Played': false},
      localPositionTicks: 400,
    );
    addTearDown(farther.dispose);
    await farther.sync.sync();
    final fartherRecord = await farther.repository.loadProgress(
      _scope,
      'item-1',
    );

    expect(fartherRecord?.positionTicks, 900);
    expect(fartherRecord?.played, isFalse);
    expect(farther.requests, hasLength(1));
  });

  test(
    'applies a bounded retry time when server state cannot be read',
    () async {
      final now = DateTime.utc(2026, 7, 30, 12);
      final harness = await _SyncHarness.create(
        serverUserData: const {},
        localPositionTicks: 200,
        now: now,
        failServerRead: true,
      );
      addTearDown(harness.dispose);

      final result = await harness.sync.sync();
      final stored = await harness.repository.loadProgress(_scope, 'item-1');

      expect(result.failed, 1);
      expect(stored?.syncStatus, 'failed');
      expect(stored?.retryAfter, now.add(const Duration(minutes: 5)));
      expect(
        await harness.repository.listPendingProgress(
          _scope,
          now: now.add(const Duration(minutes: 4)),
        ),
        isEmpty,
      );
    },
  );

  test('network recovery retries deferred progress immediately', () async {
    final now = DateTime.utc(2026, 7, 30, 12);
    final harness = await _SyncHarness.create(
      serverUserData: const {'PlaybackPositionTicks': 100, 'Played': false},
      localPositionTicks: 200,
      now: now,
      serverReadFailures: 1,
    );
    addTearDown(harness.dispose);

    final failed = await harness.sync.sync();
    final deferred = await harness.sync.sync();
    final recovered = await harness.sync.sync(includeDeferred: true);
    final stored = await harness.repository.loadProgress(_scope, 'item-1');

    expect(failed.failed, 1);
    expect(deferred.synced, 0);
    expect(recovered.synced, 1);
    expect(stored?.syncStatus, 'synced');
    expect(harness.requests.map((request) => request.path), [
      '/Users/user-1/Items',
      '/Users/user-1/Items',
      '/Sessions/Playing/Stopped',
    ]);
  });

  test(
    'does not overwrite progress written while a sync is in flight',
    () async {
      late _SyncHarness harness;
      harness = await _SyncHarness.create(
        serverUserData: const {'PlaybackPositionTicks': 100, 'Played': false},
        localPositionTicks: 200,
        beforeStoppedResponse: () async {
          await harness.repository.saveProgress(
            OfflineProgressRecord(
              scope: _scope,
              itemId: 'item-1',
              positionTicks: 300,
              played: false,
              updatedAt: DateTime.utc(2026, 7, 30, 12, 1),
              syncStatus: 'pending',
            ),
          );
        },
      );
      addTearDown(harness.dispose);

      final result = await harness.sync.sync();
      final stored = await harness.repository.loadProgress(_scope, 'item-1');

      expect(result.superseded, 1);
      expect(stored?.positionTicks, 300);
      expect(stored?.syncStatus, 'pending');
    },
  );
}

class _SyncHarness {
  _SyncHarness({
    required this.database,
    required this.repository,
    required this.api,
    required this.sync,
    required this.requests,
  });

  final LocalDatabase database;
  final DownloadRepository repository;
  final EmbyApi api;
  final OfflineProgressSync sync;
  final List<RequestOptions> requests;

  static Future<_SyncHarness> create({
    required Map<String, dynamic> serverUserData,
    required int localPositionTicks,
    DateTime? now,
    bool failServerRead = false,
    int serverReadFailures = 0,
    Future<void> Function()? beforeStoppedResponse,
  }) async {
    final database = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => inMemoryDatabasePath,
    );
    final repository = DownloadRepository(database);
    final requests = <RequestOptions>[];
    var remainingServerReadFailures = serverReadFailures;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests.add(options);
            if (options.method == 'GET') {
              if (failServerRead || remainingServerReadFailures > 0) {
                if (remainingServerReadFailures > 0) {
                  remainingServerReadFailures--;
                }
                handler.reject(
                  DioException.badResponse(
                    statusCode: 500,
                    requestOptions: options,
                    response: Response<dynamic>(
                      requestOptions: options,
                      statusCode: 500,
                    ),
                  ),
                );
                return;
              }
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'Items': [
                      {
                        'Id': 'item-1',
                        'Name': 'Offline Test',
                        'Type': 'Movie',
                        'ImageTags': <String, dynamic>{},
                        'BackdropImageTags': <dynamic>[],
                        'Genres': <dynamic>[],
                        'UserData': serverUserData,
                      },
                    ],
                  },
                ),
              );
              return;
            }
            if (options.path == '/Sessions/Playing/Stopped') {
              await beforeStoppedResponse?.call();
            }
            handler.resolve(
              Response<dynamic>(requestOptions: options, statusCode: 204),
            );
          },
        ),
      );
    final api = EmbyApi(_session, dio: dio);
    final timestamp = now ?? DateTime.utc(2026, 7, 30, 12);
    final task = _task(timestamp);
    await repository.complete(
      task,
      OfflineMediaItem(
        scope: _scope,
        itemId: task.itemId,
        mediaSourceId: task.mediaSourceId,
        metadata: task.metadata,
        localMediaPath: task.finalPath,
        completedAt: timestamp,
      ),
    );
    await repository.saveProgress(
      OfflineProgressRecord(
        scope: _scope,
        itemId: task.itemId,
        positionTicks: localPositionTicks,
        played: false,
        updatedAt: timestamp,
        syncStatus: 'pending',
      ),
    );
    final sync = OfflineProgressSync(
      api: api,
      scope: _scope,
      store: repository,
      now: () => timestamp,
    );
    return _SyncHarness(
      database: database,
      repository: repository,
      api: api,
      sync: sync,
      requests: requests,
    );
  }

  Future<void> dispose() async {
    await api.dispose();
    await database.close();
  }
}

DownloadTaskRecord _task(DateTime timestamp) => DownloadTaskRecord(
  id: 'task-1',
  scope: _scope,
  itemId: 'item-1',
  mediaSourceId: 'source-1',
  sourceKind: DownloadSourceKind.original,
  sourceFingerprint: 'fingerprint',
  status: DownloadStatus.completed,
  downloadedBytes: 12,
  retryCount: 0,
  tempPath: 'video.mkv.part',
  finalPath: 'video.mkv',
  metadata: OfflineMediaMetadata(
    name: 'Offline Test',
    itemType: 'Movie',
    mediaStreams: const [],
  ),
  createdAt: timestamp,
  updatedAt: timestamp,
);

const _scope = ServerScope(serverId: 'server-1', userId: 'user-1');

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
