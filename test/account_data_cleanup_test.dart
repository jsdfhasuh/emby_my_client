import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/account_data_cleanup.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/downloads/download_settings.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/search/search_history_store.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/settings/library_sort_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'deletes only the selected account files, records, and settings',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'emby-account-cleanup-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await _seedDatabase(database, _firstScope, 'first');
      await _seedDatabase(database, _secondScope, 'second');

      final firstDirectory = Directory(
        path.join(root.path, _firstScope.databaseKey),
      );
      final secondDirectory = Directory(
        path.join(root.path, _secondScope.databaseKey),
      );
      await firstDirectory.create(recursive: true);
      await secondDirectory.create(recursive: true);
      await File(path.join(firstDirectory.path, 'media.bin')).writeAsBytes([1]);
      final secondFile = File(path.join(secondDirectory.path, 'media.bin'));
      await secondFile.writeAsBytes([2]);

      final downloadSettings = MemoryDownloadSettingsStore();
      final librarySettings = MemoryLibraryCategorySettingsStore();
      final sortPreferences = MemoryLibrarySortPreferenceStore();
      final searchHistory = MemorySearchHistoryStore();
      final playbackSettings = PlaybackSettingsRepository();
      await downloadSettings.save(
        _firstScope,
        const DownloadSettings(wifiOnly: false),
      );
      await downloadSettings.save(
        _secondScope,
        const DownloadSettings(wifiOnly: false),
      );
      await librarySettings.save(
        _firstScope,
        const LibraryCategorySettings(showMovies: true),
      );
      await librarySettings.save(
        _secondScope,
        const LibraryCategorySettings(showSeries: true),
      );
      await sortPreferences.save(
        _firstScope,
        'library-a',
        const LibrarySortPreference(
          sortBy: LibrarySortBy.playCount,
          sortOrder: LibrarySortOrder.descending,
        ),
      );
      await sortPreferences.save(
        _secondScope,
        'library-a',
        const LibrarySortPreference(
          sortBy: LibrarySortBy.dateAdded,
          sortOrder: LibrarySortOrder.ascending,
        ),
      );
      await searchHistory.add(_firstScope, 'first query');
      await searchHistory.add(_secondScope, 'second query');
      await playbackSettings.patch(
        _firstSession,
        const PlaybackSettingsPatch(maxStreamingBitrate: 1000000),
      );
      await playbackSettings.patch(
        _secondSession,
        const PlaybackSettingsPatch(maxStreamingBitrate: 2000000),
      );

      final cleanup = AccountDataCleanup(
        database: database,
        directoryResolver: (scope) async =>
            Directory(path.join(root.path, scope.databaseKey)),
        downloadSettingsStore: downloadSettings,
        libraryCategorySettingsStore: librarySettings,
        librarySortPreferenceStore: sortPreferences,
        searchHistoryStore: searchHistory,
        playbackSettingsRepository: playbackSettings,
      );

      await cleanup.delete(scope: _firstScope, session: _firstSession);

      expect(await firstDirectory.exists(), isFalse);
      expect(await secondFile.readAsBytes(), [2]);
      for (final table in const [
        'server_capabilities',
        'download_tasks',
        'offline_items',
        'offline_progress',
      ]) {
        expect(await _scopeCount(database, table, _firstScope), 0);
        expect(await _scopeCount(database, table, _secondScope), 1);
      }
      expect((await downloadSettings.load(_firstScope)).wifiOnly, isTrue);
      expect((await downloadSettings.load(_secondScope)).wifiOnly, isFalse);
      expect(
        await librarySettings.load(_firstScope),
        const LibraryCategorySettings(),
      );
      expect((await librarySettings.load(_secondScope)).showSeries, isTrue);
      expect(await sortPreferences.load(_firstScope, 'library-a'), isNull);
      expect(
        await sortPreferences.load(_secondScope, 'library-a'),
        const LibrarySortPreference(
          sortBy: LibrarySortBy.dateAdded,
          sortOrder: LibrarySortOrder.ascending,
        ),
      );
      expect(await searchHistory.load(_firstScope), isEmpty);
      expect(await searchHistory.load(_secondScope), ['second query']);
      expect(
        (await playbackSettings.load(
          _firstSession,
        )).settings.maxStreamingBitrate,
        const PlaybackSettings().maxStreamingBitrate,
      );
      expect(
        (await playbackSettings.load(
          _secondSession,
        )).settings.maxStreamingBitrate,
        2000000,
      );
    },
  );

  test(
    'rejects a directory that is not owned by the requested scope',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'emby-account-cleanup-guard-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final protectedFile = File(path.join(root.path, 'keep.txt'));
      await protectedFile.writeAsString('keep');
      final database = LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await _seedDatabase(database, _firstScope, 'first');
      final cleanup = AccountDataCleanup(
        database: database,
        directoryResolver: (_) async => root,
        downloadSettingsStore: MemoryDownloadSettingsStore(),
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
        librarySortPreferenceStore: MemoryLibrarySortPreferenceStore(),
        searchHistoryStore: MemorySearchHistoryStore(),
      );

      await expectLater(
        cleanup.delete(scope: _firstScope, session: _firstSession),
        throwsStateError,
      );

      expect(await protectedFile.readAsString(), 'keep');
      expect(await _scopeCount(database, 'download_tasks', _firstScope), 1);
    },
  );

  test(
    'rejects a non-directory at the expected scope path without partial cleanup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'emby-account-cleanup-file-guard-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final scopePath = path.join(root.path, _firstScope.databaseKey);
      final unexpectedFile = File(scopePath);
      await unexpectedFile.writeAsString('keep');
      final database = LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await _seedDatabase(database, _firstScope, 'first');
      final cleanup = AccountDataCleanup(
        database: database,
        directoryResolver: (_) async => Directory(scopePath),
        downloadSettingsStore: MemoryDownloadSettingsStore(),
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
        librarySortPreferenceStore: MemoryLibrarySortPreferenceStore(),
        searchHistoryStore: MemorySearchHistoryStore(),
      );

      await expectLater(
        cleanup.delete(scope: _firstScope, session: _firstSession),
        throwsStateError,
      );

      expect(await unexpectedFile.readAsString(), 'keep');
      expect(await _scopeCount(database, 'download_tasks', _firstScope), 1);
      expect(await _scopeCount(database, 'offline_items', _firstScope), 1);
      expect(await _scopeCount(database, 'offline_progress', _firstScope), 1);
    },
  );
}

Future<void> _seedDatabase(
  LocalDatabase database,
  ServerScope scope,
  String suffix,
) async {
  await database.transaction((executor) async {
    await executor.insert('server_capabilities', {
      'server_id': scope.serverId,
      'user_id': scope.userId,
      'supported_features': '[]',
      'unsupported_features': '[]',
      'evidence_json': '{}',
      'updated_at_ms': 1,
    });
    await executor.insert('download_tasks', {
      'id': 'task-$suffix',
      'server_id': scope.serverId,
      'user_id': scope.userId,
      'item_id': 'item-$suffix',
      'media_source_id': 'source-$suffix',
      'display_name': suffix,
      'item_type': 'Movie',
      'container': 'mkv',
      'source_kind': 'original',
      'source_fingerprint': suffix,
      'downloaded_bytes': 1,
      'status': 'completed',
      'retry_count': 0,
      'temp_path': 'parts/$suffix.part',
      'final_path': 'media/$suffix.mkv',
      'metadata_json': jsonEncode({'itemId': 'item-$suffix'}),
      'created_at_ms': 1,
      'updated_at_ms': 1,
    });
    await executor.insert('offline_items', {
      'server_id': scope.serverId,
      'user_id': scope.userId,
      'item_id': 'item-$suffix',
      'media_source_id': 'source-$suffix',
      'metadata_json': jsonEncode({'itemId': 'item-$suffix'}),
      'local_media_path': 'media/$suffix.mkv',
      'completed_at_ms': 1,
    });
    await executor.insert('offline_progress', {
      'server_id': scope.serverId,
      'user_id': scope.userId,
      'item_id': 'item-$suffix',
      'position_ticks': 1,
      'played': 0,
      'updated_at_ms': 1,
      'sync_status': 'pending',
    });
  });
}

Future<int> _scopeCount(
  LocalDatabase database,
  String table,
  ServerScope scope,
) async {
  final rows = await database.read(
    (executor) => executor.rawQuery(
      'SELECT COUNT(*) AS count FROM $table WHERE server_id = ? AND user_id = ?',
      [scope.serverId, scope.userId],
    ),
  );
  return rows.single['count'] as int;
}

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');

const _firstSession = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'first',
  accessToken: 'token-1',
  deviceId: 'device-1',
);

const _secondSession = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-2',
  username: 'second',
  accessToken: 'token-2',
  deviceId: 'device-1',
);
