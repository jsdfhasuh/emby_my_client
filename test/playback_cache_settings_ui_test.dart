import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_coordinator.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/ui/playback_cache_settings_screen.dart';
import 'package:emby_my_client/ui/widgets/playback_cache_status_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic summary never invents a fixed cache target', () {
    final summary = playbackCacheSettingsSummary(
      const PlaybackCacheSettings(mode: PlaybackCacheMode.automatic),
    );

    expect(summary, '自动 · 根据可用空间动态决定');
    expect(summary, isNot(contains('前向')));
    expect(summary, isNot(contains('后向')));
  });

  testWidgets('preset selection saves cache patch for the next playback', (
    tester,
  ) async {
    final repository = PlaybackSettingsRepository(storage: _MemoryStorage());
    await _pumpSettings(tester, repository: repository, freeBytes: 12 << 30);

    expect(find.text('自定义目标'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cache-mode-custom')));
    await tester.pumpAndSettle();
    expect(find.text('自定义目标'), findsOneWidget);
    expect(find.text('最大会话缓存目标'), findsOneWidget);
    expect(find.text('设备保留空间'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('save-playback-cache-settings')),
    );
    await tester.pumpAndSettle();

    final saved = (await repository.load(_session)).settings.cache;
    expect(saved.mode, PlaybackCacheMode.custom);
    expect(find.text('已保存，将从下次播放生效'), findsOneWidget);
  });

  testWidgets('all seven cache modes are available exactly once', (
    tester,
  ) async {
    await _pumpSettings(
      tester,
      repository: PlaybackSettingsRepository(storage: _MemoryStorage()),
      freeBytes: 12 << 30,
    );

    for (final mode in PlaybackCacheMode.values) {
      expect(find.byKey(ValueKey('cache-mode-${mode.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('cache-mode-fullReadAhead')));
    await tester.pumpAndSettle();
    expect(find.text('本次所需空间：播放时根据媒体大小、恢复位置和码率确认'), findsOneWidget);
    expect(find.text('结尾状态：只有实际连续缓存范围到达结尾才显示完成'), findsOneWidget);
    expect(find.text('前向缓存目标'), findsNothing);
  });

  testWidgets('known and unknown free space use fixed safe presentation', (
    tester,
  ) async {
    final repository = PlaybackSettingsRepository(storage: _MemoryStorage());
    await _pumpSettings(tester, repository: repository, freeBytes: null);
    expect(find.text('可用于缓存的空间：无法确认'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpSettings(tester, repository: repository, freeBytes: 12 << 30);
    expect(find.text('可用于缓存的空间：约 12 GB'), findsOneWidget);
  });

  testWidgets(
    'settings screen has no overflow on iPad and Android at 2x text',
    (tester) async {
      for (final size in const [Size(1024, 768), Size(390, 844)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await _pumpSettings(
          tester,
          repository: PlaybackSettingsRepository(storage: _MemoryStorage()),
          freeBytes: 8 << 30,
          textScale: 2,
        );
        await tester.tap(find.byKey(const ValueKey('cache-mode-custom')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );

  testWidgets('player status never presents targets as actual cache ranges', (
    tester,
  ) async {
    final profile = ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.disk,
      transportKind: PlaybackTransportKind.progressiveHttp,
      fallbackReason: PlaybackCacheFallbackReason.none,
      forwardTarget: const Duration(minutes: 3),
      backwardTarget: const Duration(minutes: 2),
      sessionTargetBytes: 512 << 20,
      reservedFreeBytes: 2 << 30,
      demuxerForwardMetadataBytes: 32 << 20,
      demuxerBackwardMetadataBytes: 16 << 20,
      metadataBudgetCapBytes: 64 << 20,
      streamBufferBytes: 128 << 10,
      donateBuffer: true,
      sessionDirectory: Directory('cache-fixture'),
    );
    const engineSnapshot = PlaybackCacheEngineSnapshot(
      fileCacheBytes: 186 << 20,
      rawInputRateBytesPerSecond: 1 << 20,
      seekableRanges: [],
      pausedForCache: false,
      cacheBufferingPercent: 100,
      cacheOnDisk: true,
    );
    final state = PlaybackState(
      cacheProfile: profile,
      cacheRuntimeMode: PlaybackCacheRuntimeMode.disk,
      cacheObservation: const PlaybackCacheObservation(
        engineSnapshot: engineSnapshot,
        actualForward: Duration(minutes: 2, seconds: 26),
        actualBackward: Duration(minutes: 1, seconds: 47),
        availableBytes: 10 << 30,
        stopThresholdBytes: 450 << 20,
        lowSpaceTriggerBytes: 3 << 30,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackCacheStatusSection(
              settings: const PlaybackCacheSettings(),
              state: state,
            ),
          ),
        ),
      ),
    );

    expect(find.text('前向目标'), findsOneWidget);
    expect(find.text('3 分钟'), findsOneWidget);
    expect(find.text('实际可前向 Seek'), findsOneWidget);
    expect(find.text('约 2 分 26 秒'), findsOneWidget);
    expect(find.text('实际可回退'), findsOneWidget);
    expect(find.text('约 1 分 47 秒'), findsOneWidget);
    expect(find.text('186 MB'), findsOneWidget);
  });

  testWidgets('full read-ahead status uses confirmed continuous end evidence', (
    tester,
  ) async {
    const profile = ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.disk,
      transportKind: PlaybackTransportKind.progressiveHttp,
      fallbackReason: PlaybackCacheFallbackReason.none,
      forwardTarget: Duration(hours: 2),
      backwardTarget: Duration.zero,
      sessionTargetBytes: 7 << 30,
      reservedFreeBytes: 2 << 30,
      demuxerForwardMetadataBytes: 64 << 20,
      demuxerBackwardMetadataBytes: 16 << 20,
      metadataBudgetCapBytes: 80 << 20,
      streamBufferBytes: 128 << 10,
      donateBuffer: true,
      sessionDirectory: null,
      readAheadStrategy: PlaybackCacheReadAheadStrategy.mediaEnd,
      budgetPolicy: PlaybackCacheBudgetPolicy.lowSpaceOnly,
      sizeConfidence: PlaybackCacheSizeConfidence.serverDeclared,
      readAheadAnchor: Duration(minutes: 42, seconds: 18),
      estimatedSourceBytes: 8 << 30,
    );
    const snapshot = PlaybackCacheEngineSnapshot(
      fileCacheBytes: 2 << 30,
      rawInputRateBytesPerSecond: 1 << 20,
      seekableRanges: [],
      pausedForCache: false,
      cacheBufferingPercent: 100,
      cacheOnDisk: true,
    );
    const observation = PlaybackCacheObservation(
      engineSnapshot: snapshot,
      actualForward: Duration.zero,
      actualBackward: Duration(minutes: 42),
      availableBytes: 10 << 30,
      stopThresholdBytes: 4 << 30,
      lowSpaceTriggerBytes: 3 << 30,
      readAheadAnchor: Duration(minutes: 42, seconds: 18),
      mediaDuration: Duration(hours: 2, minutes: 8, seconds: 10),
      actualContinuousStart: Duration(minutes: 42, seconds: 18),
      actualContinuousEnd: Duration(hours: 2, minutes: 8, seconds: 10),
      fullReadAheadEligible: true,
      fullReadAheadReachedEnd: true,
      telemetryAvailable: true,
    );
    final state = PlaybackState(
      cacheProfile: profile,
      cacheRuntimeMode: PlaybackCacheRuntimeMode.disk,
      cacheObservation: observation,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackCacheStatusSection(
              settings: const PlaybackCacheSettings(
                mode: PlaybackCacheMode.fullReadAhead,
              ),
              state: state,
            ),
          ),
        ),
      ),
    );

    expect(find.text('预计本次需要'), findsOneWidget);
    expect(find.text('约 7 GB'), findsOneWidget);
    expect(find.text('已连续预读至'), findsOneWidget);
    expect(find.text('02:08:10 / 02:08:10'), findsOneWidget);
    expect(find.text('已从 00:42:18 预读至媒体结尾'), findsOneWidget);
    expect(find.text('前向目标'), findsNothing);
    expect(find.text('后向目标'), findsNothing);
  });

  testWidgets('missing telemetry and fallback reason stay explicit', (
    tester,
  ) async {
    final profile = ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
      transportKind: PlaybackTransportKind.progressiveHttp,
      fallbackReason: PlaybackCacheFallbackReason.directoryUnavailable,
      forwardTarget: const Duration(minutes: 1),
      backwardTarget: const Duration(seconds: 30),
      sessionTargetBytes: 0,
      reservedFreeBytes: 2 << 30,
      demuxerForwardMetadataBytes: 16 << 20,
      demuxerBackwardMetadataBytes: 8 << 20,
      metadataBudgetCapBytes: 32 << 20,
      streamBufferBytes: 128 << 10,
      donateBuffer: true,
      sessionDirectory: null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackCacheStatusSection(
            settings: const PlaybackCacheSettings(),
            state: PlaybackState(
              cacheProfile: profile,
              cacheRuntimeMode: PlaybackCacheRuntimeMode.memoryFallback,
              cacheFallbackReason:
                  PlaybackCacheFallbackReason.directoryUnavailable,
            ),
          ),
        ),
      ),
    );

    expect(find.text('实际缓存范围'), findsOneWidget);
    expect(find.text('暂不可用'), findsOneWidget);
    expect(find.text('缓存目录不可用'), findsOneWidget);
  });
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required PlaybackSettingsRepository repository,
  required int? freeBytes,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PlaybackCacheSettingsScreen(
        session: _session,
        repository: repository,
        storage: _UnavailableStorage(),
        spaceProbe: () async => freeBytes,
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
