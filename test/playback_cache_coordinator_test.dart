import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_coordinator.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overlapping ranges merge and expose actual forward and backward', () {
    final ranges = normalizedPlaybackCacheRanges(const [
      PlaybackCacheRange(
        start: Duration(seconds: 20),
        end: Duration(seconds: 40),
      ),
      PlaybackCacheRange(
        start: Duration(seconds: 10),
        end: Duration(seconds: 30),
      ),
      PlaybackCacheRange(
        start: Duration(seconds: 50),
        end: Duration(seconds: 60),
      ),
    ]);

    expect(ranges, hasLength(2));
    final actual = actualPlaybackCacheRange(
      ranges: ranges,
      position: const Duration(seconds: 25),
    );
    expect(actual?.backward, const Duration(seconds: 15));
    expect(actual?.forward, const Duration(seconds: 15));
    expect(
      actualPlaybackCacheRange(
        ranges: ranges,
        position: const Duration(seconds: 45),
      ),
      isNull,
    );
  });

  test('budget and low-space guards use rate and close latency', () {
    expect(
      cacheStopThresholdBytes(
        targetBytes: 512 << 20,
        inputRateBytesPerSecond: 16 << 20,
        pollInterval: const Duration(seconds: 1),
        expectedCloseLatency: const Duration(seconds: 2),
      ),
      464 << 20,
    );
    expect(
      cacheLowSpaceTriggerBytes(
        reservedFreeBytes: 2 << 30,
        inputRateBytesPerSecond: 16 << 20,
        pollInterval: const Duration(seconds: 10),
        expectedCloseLatency: const Duration(seconds: 2),
      ),
      (2 << 30) + (192 << 20),
    );
  });

  test('low-space wins and all safety signals share one reopen', () async {
    final engine = _Engine(
      const PlaybackCacheEngineSnapshot(
        fileCacheBytes: 500 << 20,
        rawInputRateBytesPerSecond: 16 << 20,
        seekableRanges: [],
        pausedForCache: false,
        cacheBufferingPercent: 0,
        cacheOnDisk: true,
      ),
    );
    final storage = _Storage(freeBytes: (2 << 30) + (100 << 20));
    final reasons = <PlaybackCacheSafetyReason>[];
    final coordinator = PlaybackCacheCoordinator(
      engine: engine,
      storage: storage,
      session: _session,
      profile: _profile,
      mediaBitrate: 8 * 1000 * 1000,
      committedPosition: () => const Duration(minutes: 5),
      onObservation: (_) {},
      onSafetyReopen: (reason) async => reasons.add(reason),
      statePollInterval: const Duration(hours: 1),
      spacePollInterval: const Duration(seconds: 10),
    );

    await coordinator.start();
    await coordinator.afterExecutedSeek();
    await coordinator.handleMemoryPressure();

    expect(reasons, [PlaybackCacheSafetyReason.lowSpace]);
    expect(coordinator.safetyReopenRequested, isTrue);
    await coordinator.stop();
  });

  test('concurrent refreshes are serialized and coalesced', () async {
    final gate = Completer<void>();
    final engine = _Engine(null, readGate: gate);
    final storage = _Storage(freeBytes: 20 << 30);
    final coordinator = PlaybackCacheCoordinator(
      engine: engine,
      storage: storage,
      session: _session,
      profile: _profile,
      mediaBitrate: 8 * 1000 * 1000,
      committedPosition: () => Duration.zero,
      onObservation: (_) {},
      onSafetyReopen: (_) async {},
      statePollInterval: const Duration(hours: 1),
      spacePollInterval: const Duration(hours: 1),
    );

    final start = coordinator.start();
    await Future<void>.delayed(Duration.zero);
    final extra = List<Future<void>>.generate(
      100,
      (_) => coordinator.refreshNow(checkSpace: false),
    );
    gate.complete();
    await start;
    await Future.wait(extra);

    expect(engine.maxConcurrentReads, 1);
    expect(engine.reads, 2);
    await coordinator.stop();
  });
}

const _profile = ResolvedPlaybackCacheProfile(
  runtimeMode: PlaybackCacheRuntimeMode.disk,
  transportKind: PlaybackTransportKind.progressiveHttp,
  fallbackReason: PlaybackCacheFallbackReason.none,
  forwardTarget: Duration(minutes: 3),
  backwardTarget: Duration(minutes: 2),
  sessionTargetBytes: 512 << 20,
  reservedFreeBytes: 2 << 30,
  demuxerForwardMetadataBytes: 32 << 20,
  demuxerBackwardMetadataBytes: 16 << 20,
  metadataBudgetCapBytes: 64 << 20,
  streamBufferBytes: 128 << 10,
  donateBuffer: true,
  sessionDirectory: null,
);

final _session = PlaybackCacheSession(
  directory: Directory.systemTemp,
  nonce: '0123456789abcdef0123456789abcdef',
);

class _Engine implements PlaybackCacheEngine {
  _Engine(this.snapshot, {this.readGate});

  final PlaybackCacheEngineSnapshot? snapshot;
  final Completer<void>? readGate;
  int reads = 0;
  int concurrentReads = 0;
  int maxConcurrentReads = 0;

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) => throw UnimplementedError();

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() =>
      throw UnimplementedError();

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() async {
    reads++;
    concurrentReads++;
    if (concurrentReads > maxConcurrentReads) {
      maxConcurrentReads = concurrentReads;
    }
    await readGate?.future;
    concurrentReads--;
    return snapshot;
  }
}

class _Storage implements PlaybackCacheStorage {
  _Storage({required this.freeBytes});

  final int freeBytes;

  @override
  Future<void> cleanupNonActiveMarkedSessions() async {}

  @override
  Future<void> cleanupSession(PlaybackCacheSession session) async {}

  @override
  Future<int?> freeBytesFor(Directory directory) async => freeBytes;

  @override
  Future<PlaybackCacheStorageSnapshot> prepareSession() async =>
      throw UnimplementedError();
}
