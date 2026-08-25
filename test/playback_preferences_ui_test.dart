import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/seek_preview_mode.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/playback_preferences_screen.dart';
import 'package:emby_my_client/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('playback preferences load and save account settings', (
    tester,
  ) async {
    final repository = PlaybackSettingsRepository(storage: _MemoryStorage());
    await repository.load(_session);
    await repository.patch(
      _session,
      const PlaybackSettingsPatch(
        seekForwardSeconds: 30,
        horizontalSwipeSeekSpanSeconds: 300,
        seekPreviewMode: SeekPreviewMode.off,
        playbackRate: 1.5,
      ),
    );

    await _pumpPreferences(tester, repository: repository);

    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('按钮/双击快进'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playback-horizontal-swipe-span')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('playback-seek-preview-mode')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('playback-seek-forward')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 秒').last);
    await tester.pumpAndSettle();
    final yellow = find.byKey(
      const ValueKey('playback-subtitle-color-4294967040'),
    );
    await tester.ensureVisible(yellow);
    await tester.pumpAndSettle();
    await tester.tap(yellow);
    await tester.tap(find.byKey(const ValueKey('save-playback-preferences')));
    await tester.pumpAndSettle();

    final saved = (await repository.load(_session)).settings;
    expect(saved.seekForwardSeconds, 60);
    expect(saved.horizontalSwipeSeekSpanSeconds, 300);
    expect(saved.seekPreviewMode, SeekPreviewMode.off);
    expect(saved.playbackRate, 1.5);
    expect(saved.subtitleColor, 0xFFFFFF00);
    expect(find.text('已保存，将从下次播放生效'), findsOneWidget);
  });

  testWidgets('main settings opens playback preferences as a second level', (
    tester,
  ) async {
    final repository = PlaybackSettingsRepository(storage: _MemoryStorage());
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settings: const LibraryCategorySettings(),
          accountName: 'tester',
          session: _session,
          playbackSettingsRepository: repository,
          playbackCacheStorage: _UnavailableStorage(),
          onLibraryCategorySettingsChanged: (_) async {},
          onDeleteAccountData: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('playback-preferences-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(PlaybackPreferencesScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, '播放设置'), findsOneWidget);
  });

  testWidgets('a failed load cannot overwrite settings and can be retried', (
    tester,
  ) async {
    final storage = _FailingReadStorage();
    final repository = PlaybackSettingsRepository(storage: storage);

    await _pumpPreferences(tester, repository: repository);

    expect(find.text('播放设置读取失败'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('save-playback-preferences')),
          )
          .onPressed,
      isNull,
    );

    storage.failReads = false;
    await tester.tap(find.byKey(const ValueKey('retry-playback-preferences')));
    await tester.pumpAndSettle();

    expect(find.text('播放设置读取失败'), findsNothing);
    expect(find.byKey(const ValueKey('playback-rate')), findsOneWidget);
  });

  testWidgets('playback preferences fit phone and iPad at large text', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [Size(390, 844), Size(1024, 768)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await _pumpPreferences(
        tester,
        repository: PlaybackSettingsRepository(storage: _MemoryStorage()),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

Future<void> _pumpPreferences(
  WidgetTester tester, {
  required PlaybackSettingsRepository repository,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PlaybackPreferencesScreen(
        session: _session,
        repository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _MemoryStorage implements PlaybackSettingsStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FailingReadStorage extends _MemoryStorage {
  bool failReads = true;

  @override
  Future<String?> read(String key) {
    if (failReads) return Future<String?>.error(StateError('read failed'));
    return super.read(key);
  }
}

class _UnavailableStorage implements PlaybackCacheStorage {
  @override
  Future<PlaybackCacheStorageSnapshot> prepareSession() async =>
      const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.storageCapacityUnknown,
      );

  @override
  Future<int?> freeBytesFor(Directory directory) async => null;

  @override
  Future<void> cleanupSession(PlaybackCacheSession session) async {}

  @override
  Future<void> cleanupNonActiveMarkedSessions() async {}
}

const _session = EmbySession(
  serverUrl: 'https://example.test',
  serverName: 'Test',
  serverId: 'server',
  userId: 'user',
  username: 'tester',
  accessToken: 'token',
  deviceId: 'device',
);
