import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shared_preferences_async_test_backend.dart';

void main() {
  test('library category settings are isolated by server scope', () async {
    final store = MemoryLibraryCategorySettingsStore();

    expect(await store.load(_firstScope), const LibraryCategorySettings());
    expect((await store.load(_firstScope)).showPhotos, isTrue);
    await store.save(
      _firstScope,
      const LibraryCategorySettings(showMovies: true, showFolders: false),
    );

    expect((await store.load(_firstScope)).showMovies, isTrue);
    expect((await store.load(_firstScope)).showFolders, isFalse);
    expect(await store.load(_secondScope), const LibraryCategorySettings());
  });

  test(
    'missing legacy photos key defaults to visible and remains clearable',
    () async {
      final prefix = 'library.${_firstScope.databaseKey}.category';
      final backend = SharedPreferencesAsyncTestBackend.install(
        initialValues: {
          '$prefix.movies': true,
          '$prefix.series': false,
          '$prefix.videos': true,
          '$prefix.favorites': false,
          '$prefix.folders': true,
        },
      );
      addTearDown(backend.restore);
      final store = SharedPreferencesLibraryCategorySettingsStore(
        preferences: backend.preferences,
      );

      final migrated = await store.load(_firstScope);

      expect(migrated.showMovies, isTrue);
      expect(migrated.showSeries, isFalse);
      expect(migrated.showVideos, isTrue);
      expect(migrated.showFavorites, isFalse);
      expect(migrated.showFolders, isTrue);
      expect(migrated.showPhotos, isTrue);
      expect(await backend.preferences.getBool('$prefix.photos'), isNull);

      await store.save(_firstScope, migrated.copyWith(showPhotos: false));
      expect((await store.load(_firstScope)).showPhotos, isFalse);

      await store.clear(_firstScope);
      for (final category in const [
        'movies',
        'series',
        'videos',
        'photos',
        'favorites',
        'folders',
      ]) {
        expect(await backend.preferences.getBool('$prefix.$category'), isNull);
      }
    },
  );

  testWidgets('settings screen updates a media library category', (
    tester,
  ) async {
    final changes = <LibraryCategorySettings>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsScreen(
          settings: const LibraryCategorySettings(),
          accountName: 'tester',
          session: _session,
          playbackSettingsRepository: _playbackRepository(),
          playbackCacheStorage: _UnavailablePlaybackCacheStorage(),
          onLibraryCategorySettingsChanged: (settings) async {
            changes.add(settings);
          },
          onDeleteAccountData: () async {},
        ),
      ),
    );

    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '电影'))
          .value,
      isFalse,
    );

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();

    expect(changes.single.showMovies, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '电影'))
          .value,
      isTrue,
    );
    expect(find.widgetWithText(SwitchListTile, '目录'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '图片'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '文件夹'), findsNothing);
    expect(find.text('播放验收测试'), findsNothing);
  });

  testWidgets('account data deletion requires explicit confirmation', (
    tester,
  ) async {
    var deleteCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsScreen(
          settings: const LibraryCategorySettings(),
          accountName: 'tester',
          session: _session,
          playbackSettingsRepository: _playbackRepository(),
          playbackCacheStorage: _UnavailablePlaybackCacheStorage(),
          onLibraryCategorySettingsChanged: (_) async {},
          onDeleteAccountData: () async {
            deleteCalls++;
          },
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('删除此账户数据'), 300);
    await tester.tap(find.text('删除此账户数据'));
    await tester.pumpAndSettle();
    expect(find.text('删除此账户数据？'), findsOneWidget);
    expect(find.textContaining('tester'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 0);

    await tester.scrollUntilVisible(find.text('删除此账户数据'), 300);
    await tester.tap(find.text('删除此账户数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除并退出'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
  });
}

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');

const _session = EmbySession(
  serverUrl: 'https://example.test',
  serverName: 'Test',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'token',
  deviceId: 'device',
);

PlaybackSettingsRepository _playbackRepository() =>
    PlaybackSettingsRepository(storage: _MemoryPlaybackSettingsStorage());

class _MemoryPlaybackSettingsStorage implements PlaybackSettingsStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _UnavailablePlaybackCacheStorage implements PlaybackCacheStorage {
  @override
  Future<PlaybackCacheStorageSnapshot> prepareSession() async =>
      const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.storageCapacityUnknown,
      );

  @override
  Future<int?> freeBytesFor(_) async => null;

  @override
  Future<void> cleanupSession(PlaybackCacheSession session) async {}

  @override
  Future<void> cleanupNonActiveMarkedSessions() async {}
}
