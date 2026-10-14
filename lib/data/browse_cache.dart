import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/server_scope.dart';
import 'local_database.dart';

class BrowseSnapshot {
  const BrowseSnapshot(this.data, this.updatedAt);
  final dynamic data;
  final DateTime updatedAt;
}

/// Visited requests only. The complete query preserves page/filter/order
/// membership; no background crawl and no synthetic complete library.
class BrowseCacheRepository {
  BrowseCacheRepository(
    this.database, {
    this.maxBytes = 64 * 1024 * 1024,
    this.maxEntries = 1000,
  });

  final LocalDatabase database;
  final int maxBytes;
  final int maxEntries;
  int generation(ServerScope scope) => database.scopeVersion(scope);

  static String requestKey(String path, Map<String, dynamic>? query) {
    dynamic ordered(dynamic value) {
      if (value is Map) {
        final keys = value.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: ordered(value[key])};
      }
      if (value is List) return value.map(ordered).toList();
      return value;
    }

    return jsonEncode([1, path, ordered(query ?? {})]);
  }

  Future<BrowseSnapshot?> load(ServerScope scope, String key) async {
    final rows = await database.read(
      (db) => db.query(
        'browse_snapshots',
        where: 'server_id = ? AND user_id = ? AND request_key = ?',
        whereArgs: [scope.serverId, scope.userId, key],
        limit: 1,
      ),
    );
    if (rows.isEmpty) return null;
    try {
      final row = rows.single;
      return BrowseSnapshot(
        jsonDecode(row['payload'] as String),
        DateTime.fromMillisecondsSinceEpoch(
          row['updated_at_ms'] as int,
          isUtc: true,
        ),
      );
    } on FormatException {
      // Corrupt entries are misses, never empty successful server responses.
      return null;
    }
  }

  Future<void> save(
    ServerScope scope,
    String key,
    dynamic data, {
    required int expectedGeneration,
    required bool Function() isActive,
  }) async {
    final payload = jsonEncode(_withoutCredentials(data));
    final bytes = utf8.encode(payload).length;
    if (bytes > maxBytes || bytes > 4 * 1024 * 1024) {
      throw const FormatException('browseSnapshotTooLarge');
    }
    await database.transaction((db) async {
      if (!isActive() || generation(scope) != expectedGeneration) return;
      await db.insert('browse_snapshots', {
        'server_id': scope.serverId,
        'user_id': scope.userId,
        'request_key': key,
        'payload': payload,
        'size_bytes': bytes,
        'updated_at_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final rows = await db.query(
        'browse_snapshots',
        columns: ['request_key', 'size_bytes'],
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
        orderBy: 'updated_at_ms DESC, request_key',
      );
      var used = 0;
      for (var index = 0; index < rows.length; index++) {
        used += rows[index]['size_bytes'] as int;
        if (index >= maxEntries || used > maxBytes) {
          await db.delete(
            'browse_snapshots',
            where: 'server_id = ? AND user_id = ? AND request_key = ?',
            whereArgs: [
              scope.serverId,
              scope.userId,
              rows[index]['request_key'],
            ],
          );
        }
      }
    });
  }

  Future<void> clear(ServerScope scope) async {
    database.invalidateScope(scope);
    await database.transaction(
      (db) => db.delete(
        'browse_snapshots',
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
      ),
    );
  }

  Future<({int entries, int bytes})> usage(ServerScope scope) async {
    final rows = await database.read(
      (db) => db.rawQuery(
        'SELECT COUNT(*) AS entries, COALESCE(SUM(size_bytes), 0) AS bytes '
        'FROM browse_snapshots WHERE server_id = ? AND user_id = ?',
        [scope.serverId, scope.userId],
      ),
    );
    return (
      entries: rows.single['entries'] as int,
      bytes: rows.single['bytes'] as int,
    );
  }
}

dynamic _withoutCredentials(dynamic value) {
  const secretKeys = {
    'accesstoken',
    'token',
    'api_key',
    'apikey',
    'authorization',
    'x-emby-token',
    'password',
    'pw',
  };
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (!secretKeys.contains(entry.key.toString().toLowerCase()))
          entry.key.toString(): _withoutCredentials(entry.value),
    };
  }
  if (value is List) return value.map(_withoutCredentials).toList();
  if (value is String && (value.contains('?') || value.contains('://'))) {
    final uri = Uri.tryParse(value);
    if (uri != null) {
      final query = Map<String, dynamic>.from(uri.queryParametersAll)
        ..removeWhere((key, _) => secretKeys.contains(key.toLowerCase()));
      return uri
          .replace(
            userInfo: '',
            queryParameters: query.isEmpty ? null : query,
            query: query.isEmpty ? '' : null,
          )
          .toString();
    }
  }
  return value;
}

class BrowseCacheState extends ChangeNotifier {
  bool offline = false;
  bool authenticationRequired = false;
  bool storageUnavailable = false;
  bool missingPage = false;
  bool _closed = false;
  final Map<String, DateTime> _stale = {};
  DateTime? get cachedAt => _stale.values.isEmpty
      ? null
      : _stale.values.reduce((a, b) => a.isBefore(b) ? a : b);
  bool get hasStalePages => _stale.isNotEmpty;

  void cached(
    String key,
    BrowseSnapshot? snapshot, {
    required bool disconnected,
  }) {
    if (_closed) return;
    offline = disconnected;
    missingPage = snapshot == null;
    if (snapshot != null) _stale[key] = snapshot.updatedAt;
    notifyListeners();
  }

  void online(String key) {
    if (_closed) return;
    offline = false;
    missingPage = false;
    _stale.remove(key);
    notifyListeners();
  }

  void authFailed() {
    if (_closed) return;
    authenticationRequired = true;
    offline = false;
    _stale.clear();
    notifyListeners();
  }

  void storageFailed() {
    if (_closed) return;
    storageUnavailable = true;
    notifyListeners();
  }

  void storageRecovered() {
    if (_closed || !storageUnavailable) return;
    storageUnavailable = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
