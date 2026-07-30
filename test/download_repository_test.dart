import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/downloads/download_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('isolates tasks, offline items and progress by server scope', () async {
    final database = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => inMemoryDatabasePath,
    );
    addTearDown(database.close);
    final repository = DownloadRepository(database);
    final first = _task(_firstScope, 'task-1');
    final second = _task(_secondScope, 'task-2');

    await repository.saveTask(first);
    await repository.saveTask(second);
    await repository.complete(
      first.copyWith(status: DownloadStatus.completed),
      _offline(first),
    );
    await repository.saveProgress(
      OfflineProgressRecord(
        scope: _firstScope,
        itemId: first.itemId,
        positionTicks: 120000000,
        played: false,
        updatedAt: DateTime.utc(2026, 7, 30, 12),
        syncStatus: 'pending',
      ),
    );

    final firstTasks = await repository.listTasks(_firstScope);
    final secondTasks = await repository.listTasks(_secondScope);
    final firstOffline = await repository.listOfflineItems(_firstScope);
    final secondOffline = await repository.listOfflineItems(_secondScope);

    expect(firstTasks.map((task) => task.id), ['task-1']);
    expect(secondTasks.map((task) => task.id), ['task-2']);
    expect(firstOffline, hasLength(1));
    expect(firstOffline.single.progress?.positionTicks, 120000000);
    expect(secondOffline, isEmpty);

    final rows = await database.read(
      (executor) => executor.query('download_tasks'),
    );
    expect(rows.toString(), isNot(contains('access-token')));
  });
}

DownloadTaskRecord _task(ServerScope scope, String id) {
  final timestamp = DateTime.utc(2026, 7, 30);
  return DownloadTaskRecord(
    id: id,
    scope: scope,
    itemId: 'same-item',
    mediaSourceId: 'source-1',
    sourceKind: DownloadSourceKind.original,
    sourceFingerprint: 'sha256-fingerprint',
    status: DownloadStatus.paused,
    downloadedBytes: 4,
    retryCount: 0,
    tempPath: '$id.part',
    finalPath: '$id.mkv',
    metadata: OfflineMediaMetadata(
      name: 'Offline item',
      itemType: 'Movie',
      container: 'mkv',
      mediaStreams: const [],
    ),
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

OfflineMediaItem _offline(DownloadTaskRecord task) => OfflineMediaItem(
  scope: task.scope,
  itemId: task.itemId,
  mediaSourceId: task.mediaSourceId,
  metadata: task.metadata,
  localMediaPath: task.finalPath,
  completedAt: task.updatedAt,
);

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');
