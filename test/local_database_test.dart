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
}

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');
