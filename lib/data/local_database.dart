import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

typedef DatabasePathResolver = Future<String> Function();

class LocalDatabase {
  LocalDatabase({DatabaseFactory? factory, DatabasePathResolver? pathResolver})
    : _factory = factory,
      _pathResolver = pathResolver ?? _defaultPath;

  static const schemaVersion = 3;
  static const fileName = 'emby_client.db';

  final DatabaseFactory? _factory;
  final DatabasePathResolver _pathResolver;
  Database? _database;
  Future<Database>? _opening;

  bool get isOpen => _database?.isOpen ?? false;

  Future<Database> open() {
    final database = _database;
    if (database != null && database.isOpen) return Future.value(database);
    return _opening ??= _open();
  }

  Future<T> read<T>(
    Future<T> Function(DatabaseExecutor database) operation,
  ) async => operation(await open());

  Future<T> transaction<T>(
    Future<T> Function(Transaction transaction) operation,
  ) async => (await open()).transaction(operation);

  Future<void> close() async {
    final opening = _opening;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        // The failed open has no database handle to close.
      }
    }
    final database = _database;
    _database = null;
    _opening = null;
    if (database != null && database.isOpen) await database.close();
  }

  Future<Database> _open() async {
    try {
      final databasePath = await _pathResolver();
      final factory = _factory ?? databaseFactory;
      final database = await factory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onConfigure: (database) async {
            await database.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (database, version) =>
              _migrate(database, fromVersion: 0, toVersion: version),
          onUpgrade: (database, oldVersion, newVersion) => _migrate(
            database,
            fromVersion: oldVersion,
            toVersion: newVersion,
          ),
        ),
      );
      _database = database;
      return database;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  static Future<void> _migrate(
    Database database, {
    required int fromVersion,
    required int toVersion,
  }) async {
    for (var version = fromVersion + 1; version <= toVersion; version++) {
      switch (version) {
        case 1:
          await database.execute('''
            CREATE TABLE server_capabilities (
              server_id TEXT NOT NULL,
              user_id TEXT NOT NULL,
              product_name TEXT,
              server_version TEXT,
              supported_features TEXT NOT NULL DEFAULT '[]',
              updated_at_ms INTEGER NOT NULL,
              PRIMARY KEY (server_id, user_id)
            )
          ''');
          break;
        case 2:
          await database.execute(
            "ALTER TABLE server_capabilities ADD COLUMN "
            "unsupported_features TEXT NOT NULL DEFAULT '[]'",
          );
          await database.execute(
            "ALTER TABLE server_capabilities ADD COLUMN "
            "evidence_json TEXT NOT NULL DEFAULT '{}'",
          );
          break;
        case 3:
          await database.execute('''
            CREATE TABLE download_tasks (
              id TEXT PRIMARY KEY,
              server_id TEXT NOT NULL,
              user_id TEXT NOT NULL,
              item_id TEXT NOT NULL,
              media_source_id TEXT NOT NULL,
              display_name TEXT NOT NULL,
              item_type TEXT NOT NULL,
              container TEXT,
              source_kind TEXT NOT NULL,
              source_fingerprint TEXT NOT NULL,
              etag TEXT,
              expected_bytes INTEGER,
              downloaded_bytes INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              last_error_code TEXT,
              temp_path TEXT NOT NULL,
              final_path TEXT NOT NULL,
              metadata_json TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL,
              UNIQUE (server_id, user_id, item_id, media_source_id)
            )
          ''');
          await database.execute('''
            CREATE TABLE offline_items (
              server_id TEXT NOT NULL,
              user_id TEXT NOT NULL,
              item_id TEXT NOT NULL,
              media_source_id TEXT NOT NULL,
              metadata_json TEXT NOT NULL,
              local_media_path TEXT NOT NULL,
              completed_at_ms INTEGER NOT NULL,
              PRIMARY KEY (server_id, user_id, item_id, media_source_id)
            )
          ''');
          await database.execute('''
            CREATE TABLE offline_progress (
              server_id TEXT NOT NULL,
              user_id TEXT NOT NULL,
              item_id TEXT NOT NULL,
              position_ticks INTEGER NOT NULL DEFAULT 0,
              played INTEGER NOT NULL DEFAULT 0,
              updated_at_ms INTEGER NOT NULL,
              sync_status TEXT NOT NULL,
              retry_after_ms INTEGER,
              PRIMARY KEY (server_id, user_id, item_id)
            )
          ''');
          await database.execute(
            'CREATE INDEX download_tasks_scope_status '
            'ON download_tasks (server_id, user_id, status)',
          );
          await database.execute(
            'CREATE INDEX offline_items_scope '
            'ON offline_items (server_id, user_id, completed_at_ms)',
          );
          break;
      }
    }
  }

  static Future<String> _defaultPath() async {
    final directory = await getApplicationSupportDirectory();
    await Directory(directory.path).create(recursive: true);
    return path.join(directory.path, fileName);
  }
}
