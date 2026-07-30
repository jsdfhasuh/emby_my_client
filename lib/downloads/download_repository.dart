import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/server_scope.dart';
import '../data/local_database.dart';
import 'download_models.dart';

abstract interface class DownloadStore {
  Future<List<DownloadTaskRecord>> listTasks(ServerScope scope);

  Future<void> saveTask(DownloadTaskRecord task);

  Future<void> complete(DownloadTaskRecord task, OfflineMediaItem item);

  Future<List<OfflineMediaItem>> listOfflineItems(ServerScope scope);

  Future<OfflineMediaItem?> offlineItem(ServerScope scope, String itemId);

  Future<void> saveProgress(OfflineProgressRecord progress);

  Future<OfflineProgressRecord?> loadProgress(ServerScope scope, String itemId);

  Future<List<OfflineProgressRecord>> listPendingProgress(
    ServerScope scope, {
    required DateTime now,
  });

  Future<void> removeOfflineItem(DownloadTaskRecord task);

  Future<void> removeDownload(DownloadTaskRecord task);
}

class DownloadRepository implements DownloadStore {
  const DownloadRepository(this._database);

  final LocalDatabase _database;

  @override
  Future<List<DownloadTaskRecord>> listTasks(ServerScope scope) async {
    final rows = await _database.read(
      (database) => database.query(
        'download_tasks',
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
        orderBy: 'created_at_ms DESC',
      ),
    );
    return rows.map(_taskFromRow).toList(growable: false);
  }

  Future<DownloadTaskRecord?> taskForItem(
    ServerScope scope,
    String itemId,
  ) async {
    final rows = await _database.read(
      (database) => database.query(
        'download_tasks',
        where: 'server_id = ? AND user_id = ? AND item_id = ?',
        whereArgs: [scope.serverId, scope.userId, itemId],
        orderBy: 'created_at_ms DESC',
        limit: 1,
      ),
    );
    return rows.isEmpty ? null : _taskFromRow(rows.single);
  }

  @override
  Future<void> saveTask(DownloadTaskRecord task) async {
    await _database.transaction(
      (database) => database.insert(
        'download_tasks',
        _taskToRow(task),
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
    );
  }

  @override
  Future<void> complete(DownloadTaskRecord task, OfflineMediaItem item) async {
    if (task.scope != item.scope ||
        task.itemId != item.itemId ||
        task.mediaSourceId != item.mediaSourceId) {
      throw ArgumentError('Task and offline item identity do not match');
    }
    await _database.transaction((database) async {
      await database.insert(
        'download_tasks',
        _taskToRow(task),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await database.insert('offline_items', {
        'server_id': item.scope.serverId,
        'user_id': item.scope.userId,
        'item_id': item.itemId,
        'media_source_id': item.mediaSourceId,
        'metadata_json': jsonEncode(item.metadata.toJson()),
        'local_media_path': item.localMediaPath,
        'completed_at_ms': item.completedAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<List<OfflineMediaItem>> listOfflineItems(ServerScope scope) async {
    final rows = await _database.read(
      (database) => database.query(
        'offline_items',
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
        orderBy: 'completed_at_ms DESC',
      ),
    );
    final progress = await _progressByItem(scope);
    return rows
        .map((row) => _offlineItemFromRow(row, progress[row['item_id']]))
        .toList(growable: false);
  }

  @override
  Future<OfflineMediaItem?> offlineItem(
    ServerScope scope,
    String itemId,
  ) async {
    final rows = await _database.read(
      (database) => database.query(
        'offline_items',
        where: 'server_id = ? AND user_id = ? AND item_id = ?',
        whereArgs: [scope.serverId, scope.userId, itemId],
        orderBy: 'completed_at_ms DESC',
        limit: 1,
      ),
    );
    if (rows.isEmpty) return null;
    final progress = await loadProgress(scope, itemId);
    return _offlineItemFromRow(rows.single, progress);
  }

  @override
  Future<void> saveProgress(OfflineProgressRecord progress) async {
    await _database.transaction(
      (database) => database.insert('offline_progress', {
        'server_id': progress.scope.serverId,
        'user_id': progress.scope.userId,
        'item_id': progress.itemId,
        'position_ticks': progress.positionTicks,
        'played': progress.played ? 1 : 0,
        'updated_at_ms': progress.updatedAt.millisecondsSinceEpoch,
        'sync_status': progress.syncStatus,
        'retry_after_ms': progress.retryAfter?.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );
  }

  @override
  Future<OfflineProgressRecord?> loadProgress(
    ServerScope scope,
    String itemId,
  ) async {
    final rows = await _database.read(
      (database) => database.query(
        'offline_progress',
        where: 'server_id = ? AND user_id = ? AND item_id = ?',
        whereArgs: [scope.serverId, scope.userId, itemId],
        limit: 1,
      ),
    );
    return rows.isEmpty ? null : _progressFromRow(rows.single);
  }

  @override
  Future<List<OfflineProgressRecord>> listPendingProgress(
    ServerScope scope, {
    required DateTime now,
  }) async {
    final rows = await _database.read(
      (database) => database.query(
        'offline_progress',
        where:
            'server_id = ? AND user_id = ? AND sync_status != ? '
            'AND (retry_after_ms IS NULL OR retry_after_ms <= ?)',
        whereArgs: [
          scope.serverId,
          scope.userId,
          'synced',
          now.millisecondsSinceEpoch,
        ],
        orderBy: 'updated_at_ms ASC',
      ),
    );
    return rows.map(_progressFromRow).toList(growable: false);
  }

  Future<void> removeTask(DownloadTaskRecord task) async {
    await _database.transaction(
      (database) => database.delete(
        'download_tasks',
        where: 'id = ? AND server_id = ? AND user_id = ?',
        whereArgs: [task.id, task.scope.serverId, task.scope.userId],
      ),
    );
  }

  @override
  Future<void> removeOfflineItem(DownloadTaskRecord task) async {
    await _database.transaction(
      (database) => database.delete(
        'offline_items',
        where:
            'server_id = ? AND user_id = ? AND item_id = ? '
            'AND media_source_id = ?',
        whereArgs: [
          task.scope.serverId,
          task.scope.userId,
          task.itemId,
          task.mediaSourceId,
        ],
      ),
    );
  }

  @override
  Future<void> removeDownload(DownloadTaskRecord task) async {
    await _database.transaction((database) async {
      await database.delete(
        'download_tasks',
        where: 'id = ? AND server_id = ? AND user_id = ?',
        whereArgs: [task.id, task.scope.serverId, task.scope.userId],
      );
      await database.delete(
        'offline_items',
        where:
            'server_id = ? AND user_id = ? AND item_id = ? '
            'AND media_source_id = ?',
        whereArgs: [
          task.scope.serverId,
          task.scope.userId,
          task.itemId,
          task.mediaSourceId,
        ],
      );
      final remaining = Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM offline_items '
          'WHERE server_id = ? AND user_id = ? AND item_id = ?',
          [task.scope.serverId, task.scope.userId, task.itemId],
        ),
      );
      if ((remaining ?? 0) == 0) {
        await database.delete(
          'offline_progress',
          where: 'server_id = ? AND user_id = ? AND item_id = ?',
          whereArgs: [task.scope.serverId, task.scope.userId, task.itemId],
        );
      }
    });
  }

  Future<Map<String, OfflineProgressRecord>> _progressByItem(
    ServerScope scope,
  ) async {
    final rows = await _database.read(
      (database) => database.query(
        'offline_progress',
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
      ),
    );
    return {
      for (final row in rows) row['item_id']!.toString(): _progressFromRow(row),
    };
  }
}

Map<String, Object?> _taskToRow(DownloadTaskRecord task) => {
  'id': task.id,
  'server_id': task.scope.serverId,
  'user_id': task.scope.userId,
  'item_id': task.itemId,
  'media_source_id': task.mediaSourceId,
  'display_name': task.displayName,
  'item_type': task.itemType,
  'container': task.container,
  'source_kind': task.sourceKind.name,
  'source_fingerprint': task.sourceFingerprint,
  'etag': task.etag,
  'expected_bytes': task.expectedBytes,
  'downloaded_bytes': task.downloadedBytes,
  'status': task.status.name,
  'retry_count': task.retryCount,
  'last_error_code': task.lastErrorCode,
  'temp_path': task.tempPath,
  'final_path': task.finalPath,
  'metadata_json': jsonEncode(task.metadata.toJson()),
  'created_at_ms': task.createdAt.millisecondsSinceEpoch,
  'updated_at_ms': task.updatedAt.millisecondsSinceEpoch,
};

DownloadTaskRecord _taskFromRow(Map<String, Object?> row) => DownloadTaskRecord(
  id: row['id']!.toString(),
  scope: ServerScope(
    serverId: row['server_id']!.toString(),
    userId: row['user_id']!.toString(),
  ),
  itemId: row['item_id']!.toString(),
  mediaSourceId: row['media_source_id']!.toString(),
  sourceKind: _enumNamed(
    DownloadSourceKind.values,
    row['source_kind'],
    DownloadSourceKind.original,
  ),
  sourceFingerprint: row['source_fingerprint']!.toString(),
  status: _enumNamed(
    DownloadStatus.values,
    row['status'],
    DownloadStatus.failed,
  ),
  downloadedBytes: _integer(row['downloaded_bytes']) ?? 0,
  retryCount: _integer(row['retry_count']) ?? 0,
  tempPath: row['temp_path']!.toString(),
  finalPath: row['final_path']!.toString(),
  metadata: OfflineMediaMetadata.fromJson(_decodeMap(row['metadata_json'])),
  createdAt: _date(row['created_at_ms']),
  updatedAt: _date(row['updated_at_ms']),
  etag: _string(row['etag']),
  expectedBytes: _integer(row['expected_bytes']),
  lastErrorCode: _string(row['last_error_code']),
);

OfflineMediaItem _offlineItemFromRow(
  Map<String, Object?> row,
  OfflineProgressRecord? progress,
) => OfflineMediaItem(
  scope: ServerScope(
    serverId: row['server_id']!.toString(),
    userId: row['user_id']!.toString(),
  ),
  itemId: row['item_id']!.toString(),
  mediaSourceId: row['media_source_id']!.toString(),
  metadata: OfflineMediaMetadata.fromJson(_decodeMap(row['metadata_json'])),
  localMediaPath: row['local_media_path']!.toString(),
  completedAt: _date(row['completed_at_ms']),
  progress: progress,
);

OfflineProgressRecord _progressFromRow(Map<String, Object?> row) =>
    OfflineProgressRecord(
      scope: ServerScope(
        serverId: row['server_id']!.toString(),
        userId: row['user_id']!.toString(),
      ),
      itemId: row['item_id']!.toString(),
      positionTicks: _integer(row['position_ticks']) ?? 0,
      played: (_integer(row['played']) ?? 0) != 0,
      updatedAt: _date(row['updated_at_ms']),
      syncStatus: row['sync_status']?.toString() ?? 'pending',
      retryAfter: row['retry_after_ms'] == null
          ? null
          : _date(row['retry_after_ms']),
    );

Map<String, dynamic> _decodeMap(Object? value) {
  if (value is! String || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
  } catch (_) {
    return const {};
  }
}

T _enumNamed<T extends Enum>(List<T> values, Object? value, T fallback) =>
    values
        .where((candidate) => candidate.name == value?.toString())
        .firstOrNull ??
    fallback;

DateTime _date(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(_integer(value) ?? 0, isUtc: true);

String? _string(Object? value) {
  final result = value?.toString();
  return result == null || result.isEmpty ? null : result;
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
