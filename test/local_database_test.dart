import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/server_capabilities.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/data/server_capabilities_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('persists capability evidence with strict scope isolation', () async {
    final database = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => inMemoryDatabasePath,
    );
    addTearDown(database.close);
    final repository = ServerCapabilitiesRepository(database);
    final observedAt = DateTime.utc(2026, 7, 30, 12);

    await repository.save(
      ServerCapabilities(
        scope: _firstScope,
        productName: 'Emby Server',
        serverVersion: '4.8.11.0',
        updatedAt: observedAt,
      ).observe(
        ServerFeature.remoteControl,
        CapabilitySupport.supported,
        source: 'sessions-capabilities-full',
        observedAt: observedAt,
      ),
    );
    await repository.save(
      ServerCapabilities(scope: _secondScope, updatedAt: observedAt).observe(
        ServerFeature.liveTv,
        CapabilitySupport.unsupported,
        source: 'live-tv-info-404',
        observedAt: observedAt,
      ),
    );

    final first = await repository.load(_firstScope);
    final second = await repository.load(_secondScope);
    final missing = await repository.load(
      const ServerScope(serverId: 'server-2', userId: 'user-1'),
    );

    expect(first?.productName, 'Emby Server');
    expect(first?.serverVersion, '4.8.11.0');
    expect(
      first?.statusOf(ServerFeature.remoteControl),
      CapabilitySupport.supported,
    );
    expect(first?.statusOf(ServerFeature.liveTv), CapabilitySupport.unknown);
    expect(
      second?.statusOf(ServerFeature.liveTv),
      CapabilitySupport.unsupported,
    );
    expect(missing, isNull);
  });

  test('upgrades a version 1 database without losing evidence', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-client-database-test-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final databasePath = '${directory.path}${Platform.pathSeparator}legacy.db';
    final observedAt = DateTime.utc(2026, 7, 29, 8);
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, _) async {
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
        },
      ),
    );
    await legacy.insert('server_capabilities', {
      'server_id': _firstScope.serverId,
      'user_id': _firstScope.userId,
      'product_name': 'Emby Server',
      'server_version': '4.8.10.0',
      'supported_features': jsonEncode(['remoteControl']),
      'updated_at_ms': observedAt.millisecondsSinceEpoch,
    });
    await legacy.close();

    final database = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => databasePath,
    );
    addTearDown(database.close);
    final repository = ServerCapabilitiesRepository(database);
    final restored = await repository.load(_firstScope);
    final columns = await database.read(
      (executor) => executor.rawQuery('PRAGMA table_info(server_capabilities)'),
    );
    final columnNames = columns
        .map((column) => column['name']?.toString())
        .toSet();

    expect(
      restored?.statusOf(ServerFeature.remoteControl),
      CapabilitySupport.supported,
    );
    expect(
      restored?.evidence[ServerFeature.remoteControl]?.source,
      'legacy-capability-record',
    );
    expect(columnNames, containsAll(['unsupported_features', 'evidence_json']));
    final tables = await database.read(
      (executor) => executor.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ),
    );
    expect(
      tables.map((row) => row['name']),
      containsAll(['download_tasks', 'offline_items', 'offline_progress']),
    );
  });

  test(
    'upgrades a version 3 download record without losing large files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'emby-client-database-v3-test-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final databasePath =
          '${directory.path}${Platform.pathSeparator}legacy.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (database, _) async {
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
          },
        ),
      );
      const downloadedBytes = 3682934456;
      await legacy.insert('download_tasks', {
        'id': 'existing-large-download',
        'server_id': _firstScope.serverId,
        'user_id': _firstScope.userId,
        'item_id': 'item-1',
        'media_source_id': 'source-1',
        'display_name': 'Existing download',
        'item_type': 'Movie',
        'container': 'mkv',
        'source_kind': 'original',
        'source_fingerprint': 'fingerprint',
        'etag': '"media-v1"',
        'expected_bytes': downloadedBytes,
        'downloaded_bytes': downloadedBytes,
        'status': 'completed',
        'retry_count': 0,
        'temp_path': 'parts/existing.mkv.part',
        'final_path': 'media/existing.mkv',
        'metadata_json': '{"name":"Existing download"}',
        'created_at_ms': 1,
        'updated_at_ms': 2,
      });
      await legacy.close();

      final database = LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => databasePath,
      );
      addTearDown(database.close);
      final columns = await database.read(
        (executor) => executor.rawQuery('PRAGMA table_info(download_tasks)'),
      );
      final rows = await database.read(
        (executor) => executor.query('download_tasks'),
      );
      final version = await database.read(
        (executor) => executor.rawQuery('PRAGMA user_version'),
      );

      expect(
        columns.map((column) => column['name']),
        containsAll(['integrity_algorithm', 'integrity_digest']),
      );
      expect(rows, hasLength(1));
      expect(rows.single['id'], 'existing-large-download');
      expect(rows.single['downloaded_bytes'], downloadedBytes);
      expect(rows.single['final_path'], 'media/existing.mkv');
      expect(rows.single['integrity_algorithm'], isNull);
      expect(rows.single['integrity_digest'], isNull);
      expect(version.single['user_version'], LocalDatabase.schemaVersion);
    },
  );

  test('closing a worker handle keeps the main database usable', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-client-database-handles-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final databasePath = '${directory.path}${Platform.pathSeparator}shared.db';
    final mainDatabase = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => databasePath,
    );
    final workerDatabase = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => databasePath,
      singleInstance: false,
    );
    addTearDown(mainDatabase.close);
    addTearDown(workerDatabase.close);

    await mainDatabase.open();
    await workerDatabase.open();
    final mainJournalMode = await mainDatabase.read(
      (database) => database.rawQuery('PRAGMA journal_mode'),
    );
    final workerJournalMode = await workerDatabase.read(
      (database) => database.rawQuery('PRAGMA journal_mode'),
    );
    await workerDatabase.close();

    final result = await mainDatabase.read(
      (database) => database.rawQuery('SELECT 1 AS value'),
    );

    expect(result.single['value'], 1);
    expect(mainJournalMode.single['journal_mode'], 'wal');
    expect(workerJournalMode.single['journal_mode'], 'wal');
    expect(mainDatabase.isOpen, isTrue);
  });
}

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');
