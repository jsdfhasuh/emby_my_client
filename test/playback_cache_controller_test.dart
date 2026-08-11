import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_diagnostics_test_overrides.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_recovery_policy.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cache is resolved and applied before open then cleaned after dispose',
    () async {
      final events = <String>[];
      final diagnostics = <String>[];
      final engine = _CacheEngine(events: events);
      final storage = _CacheStorage(events);
      final controller = _controller(
        engine: engine,
        storage: storage,
        diagnostics: _diagnostics(diagnostics),
      );

      await controller.start();

      expect(events.take(4), ['probe', 'prepare', 'configure', 'open']);
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.cacheRuntimeMode, PlaybackCacheRuntimeMode.disk);
      expect(
        controller.state.cacheProfile?.runtimeMode,
        PlaybackCacheRuntimeMode.disk,
      );
      await controller.shutdown();
      expect(events.indexOf('stop'), lessThan(events.indexOf('dispose')));
      expect(events.indexOf('dispose'), lessThan(events.indexOf('cleanup')));
      expect(storage.activeSessions, 0);
      expect(
        diagnostics,
        contains(contains('event=playback_cache_capabilities_resolved')),
      );
      expect(
        diagnostics,
        contains(contains('event=playback_cache_profile_resolved')),
      );
      expect(
        diagnostics,
        contains(contains('event=playback_cache_disk_enabled')),
      );
      expect(
        diagnostics,
        contains(contains('event=playback_cache_snapshot_unavailable')),
      );
      expect(
        diagnostics,
        contains(contains('event=playback_cache_session_cleaned')),
      );
    },
  );

  test(
    'cache creation failure remains nonfatal and confirms memory mode',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(
        events: events,
        snapshot: const PlaybackCacheEngineSnapshot(
          fileCacheBytes: null,
          rawInputRateBytesPerSecond: null,
          seekableRanges: [],
          pausedForCache: false,
          cacheBufferingPercent: null,
          cacheOnDisk: false,
        ),
      );
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
      );
      await controller.start();

      engine.logController.add('Failed to create file cache');
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.diskCacheFailureObserved, isTrue);
      expect(
        controller.state.cacheRuntimeMode,
        PlaybackCacheRuntimeMode.memoryFallback,
      );
      expect(
        controller.state.cacheFallbackReason,
        PlaybackCacheFallbackReason.mpvCacheCreateFailed,
      );
      await controller.shutdown();
    },
  );

  test(
    'cache creation plus startup failure retries once with memory',
    () async {
      final events = <String>[];
      final session = PlaybackItemSession.forTest('cache-create-retry');
      final engine = _CacheEngine(
        events: events,
        noReadyOnOpen: const {1},
        logsOnOpen: const {
          1: [
            'Failed to create file cache',
            'http: HTTP error 502 Bad Gateway',
          ],
        },
      );
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        session: session,
      );

      await controller.start();

      expect(engine.openCalls, 2);
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.plan?.method, PlayMethod.directPlay);
      expect(engine.configuredProfiles.map((profile) => profile.runtimeMode), [
        PlaybackCacheRuntimeMode.disk,
        PlaybackCacheRuntimeMode.memoryFallback,
      ]);
      expect(
        session.hasUsed(AutomaticPlaybackOpenReason.cacheCreateMemoryRetry),
        isTrue,
      );
      expect(session.automaticOpenCount, 2);
      await controller.shutdown();
    },
  );

  test('cache creation memory retry cannot recurse', () async {
    final events = <String>[];
    final session = PlaybackItemSession.forTest('cache-create-one-shot');
    final engine = _CacheEngine(
      events: events,
      noReadyOnOpen: const {1, 2},
      logsOnOpen: const {
        1: ['Failed to create file cache', 'http: HTTP error 502 Bad Gateway'],
      },
    );
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
      session: session,
      readyTimeout: const Duration(milliseconds: 20),
    );

    await controller.start();

    expect(engine.openCalls, 3);
    expect(controller.state.plan?.method, PlayMethod.transcode);
    expect(
      session.hasUsed(AutomaticPlaybackOpenReason.cacheCreateMemoryRetry),
      isTrue,
    );
    expect(
      session.hasUsed(AutomaticPlaybackOpenReason.startupTranscodeFallback),
      isTrue,
    );
    expect(session.automaticOpenCount, 3);
    await controller.shutdown();
  });

  test('profile recreation preserves the logical item session', () async {
    final events = <String>[];
    final first = _CacheEngine(
      events: events,
      requireRecreationAfterOpen: true,
    );
    final second = _CacheEngine(events: events);
    final storage = _CacheStorage(events);
    final session = PlaybackItemSession.forTest('stable-session');
    final recreatedSessions = <PlaybackItemSessionId>[];
    final controller = _controller(
      engine: first,
      storage: storage,
      session: session,
      engineRecreator: (itemSession) async {
        recreatedSessions.add(itemSession.id);
        return second;
      },
    );
    await controller.start();
    first.positionController.add(const Duration(minutes: 5));
    first.playingController.add(true);

    await controller.setMaximumBitrate(10000000);

    expect(recreatedSessions, [session.id]);
    expect(controller.sessionId, session.id);
    expect(second.openCalls, 1);
    expect(controller.state.phase, PlaybackPhase.ready);
    await controller.shutdown();
  });

  test(
    'executed seek enforces the cache budget with one memory reopen',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(
        events: events,
        snapshot: const PlaybackCacheEngineSnapshot(
          fileCacheBytes: 0,
          rawInputRateBytesPerSecond: 8 << 20,
          seekableRanges: [],
          pausedForCache: false,
          cacheBufferingPercent: 0,
          cacheOnDisk: true,
        ),
      );
      final session = PlaybackItemSession.forTest('budget-session');
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        session: session,
      );
      await controller.start();
      engine.snapshot = const PlaybackCacheEngineSnapshot(
        fileCacheBytes: 500 << 20,
        rawInputRateBytesPerSecond: 8 << 20,
        seekableRanges: [],
        pausedForCache: false,
        cacheBufferingPercent: 0,
        cacheOnDisk: true,
      );

      final result = await controller.seekAbsolute(
        const Duration(minutes: 5),
        source: SeekSource.controls,
      );

      expect(result.disposition, SeekDisposition.executed);
      expect(engine.openCalls, 2);
      expect(
        controller.state.cacheRuntimeMode,
        PlaybackCacheRuntimeMode.memoryFallback,
      );
      expect(
        controller.state.cacheFallbackReason,
        PlaybackCacheFallbackReason.sessionBudgetReached,
      );
      expect(
        session.hasUsed(AutomaticPlaybackOpenReason.cacheSafetyReopen),
        isTrue,
      );
      await controller.handleMemoryPressure();
      expect(engine.openCalls, 2);
      await controller.shutdown();
    },
  );

  test('approved seek failure is deduped and recovered once', () async {
    final events = <String>[];
    final engine = _CacheEngine(events: events);
    final session = PlaybackItemSession.forTest('recovery-session');
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
      session: session,
      recoveryPolicy: const PlaybackRecoveryPolicy(
        seekRecoveryWindow: Duration(minutes: 1),
        stablePlaybackWindow: Duration(minutes: 1),
      ),
    );
    await controller.start();
    engine.playingController.add(true);
    await controller.seekAbsolute(
      const Duration(minutes: 5),
      source: SeekSource.horizontalDrag,
    );

    engine.logController.add('partial file');
    engine.errorController.add('partial file');
    await _waitUntil(() => engine.openCalls == 2);

    expect(controller.state.phase, PlaybackPhase.ready);
    expect(engine.openCalls, 2);
    expect(
      session.hasUsed(AutomaticPlaybackOpenReason.runtimeSameMethodRecovery),
      isTrue,
    );

    await controller.seekAbsolute(
      const Duration(minutes: 6),
      source: SeekSource.horizontalDrag,
    );
    engine.errorController.add('Seek failed');
    await _waitUntil(() => controller.state.phase == PlaybackPhase.failed);
    expect(controller.state.errorMessage, '播放连接异常，自动恢复失败，请返回后重试');
    expect(engine.openCalls, 2);
    await controller.shutdown();
  });

  test('stable playback closes the seek recovery window', () async {
    final events = <String>[];
    final engine = _CacheEngine(events: events);
    var now = DateTime.utc(2026, 8, 10);
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
      clock: () => now,
      recoveryPolicy: const PlaybackRecoveryPolicy(
        seekRecoveryWindow: Duration(seconds: 30),
        stablePlaybackWindow: Duration(seconds: 5),
      ),
    );
    await controller.start();
    engine.playingController.add(true);
    await controller.seekAbsolute(
      const Duration(minutes: 5),
      source: SeekSource.controls,
    );
    now = now.add(const Duration(seconds: 1));
    engine.positionController.add(const Duration(minutes: 5, seconds: 1));
    now = now.add(const Duration(seconds: 6));
    engine.positionController.add(const Duration(minutes: 5, seconds: 7));

    engine.errorController.add('error reading packet');
    await _waitUntil(() => controller.state.phase == PlaybackPhase.failed);

    expect(engine.openCalls, 1);
    await controller.shutdown();
  });

  test(
    'approved failure outside the absolute seek window never recovers',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(events: events);
      var now = DateTime.utc(2026, 8, 10);
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        clock: () => now,
        recoveryPolicy: const PlaybackRecoveryPolicy(
          seekRecoveryWindow: Duration(seconds: 15),
          stablePlaybackWindow: Duration(minutes: 1),
        ),
      );
      await controller.start();
      await controller.seekAbsolute(
        const Duration(minutes: 5),
        source: SeekSource.controls,
      );
      now = now.add(const Duration(seconds: 15, microseconds: 1));

      engine.errorController.add('partial file');
      await _waitUntil(() => controller.state.phase == PlaybackPhase.failed);

      expect(engine.openCalls, 1);
      await controller.shutdown();
    },
  );

  test('low space before open prevents a disk cache session', () async {
    final events = <String>[];
    final diagnostics = <String>[];
    final storage = _CacheStorage(events)..freeBytes = (2 << 30) + (100 << 20);
    final engine = _CacheEngine(events: events);
    final controller = _controller(
      engine: engine,
      storage: storage,
      diagnostics: _diagnostics(diagnostics),
    );

    await controller.start();

    expect(engine.openCalls, 1);
    expect(
      controller.state.cacheRuntimeMode,
      PlaybackCacheRuntimeMode.memoryFallback,
    );
    expect(
      controller.state.cacheFallbackReason,
      PlaybackCacheFallbackReason.lowSpace,
    );
    expect(events, contains('cleanup'));
    expect(
      diagnostics
          .where((line) => line.contains('event=playback_cache_low_space'))
          .length,
      1,
    );
    await controller.shutdown();
  });

  test(
    'memory pressure uses the shared safety reopen and 64 MiB cap',
    () async {
      final events = <String>[];
      final diagnostics = <String>[];
      final engine = _CacheEngine(events: events);
      final session = PlaybackItemSession.forTest('memory-pressure-session');
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        session: session,
        diagnostics: _diagnostics(diagnostics),
      );
      await controller.start();

      await controller.handleMemoryPressure();

      expect(engine.openCalls, 2);
      expect(
        controller.state.cacheFallbackReason,
        PlaybackCacheFallbackReason.memoryPressure,
      );
      expect(
        diagnostics,
        contains(contains('event=playback_cache_memory_pressure')),
      );
      expect(
        controller.state.cacheProfile?.totalMetadataBytes,
        lessThanOrEqualTo(64 << 20),
      );
      expect(
        session.hasUsed(AutomaticPlaybackOpenReason.cacheSafetyReopen),
        isTrue,
      );
      await controller.shutdown();
    },
  );

  test('cache safety reopen has one fixed total deadline', () async {
    final events = <String>[];
    final engine = _CacheEngine(events: events, noReadyOnOpen: const {2});
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
      readyTimeout: const Duration(hours: 1),
      recoveryPolicy: const PlaybackRecoveryPolicy(
        recoveryAttemptTimeout: Duration(milliseconds: 20),
      ),
    );
    await controller.start();

    await controller.handleMemoryPressure().timeout(
      const Duration(milliseconds: 500),
    );

    expect(engine.openCalls, 2);
    expect(controller.state.phase, PlaybackPhase.failed);
    expect(controller.state.errorMessage, '缓存调整失败，请返回后重试');
    engine.durationController.add(const Duration(hours: 2));
    engine.positionController.add(const Duration(minutes: 45));
    await Future<void>.delayed(Duration.zero);
    expect(engine.openCalls, 2);
    expect(controller.state.phase, PlaybackPhase.failed);
    expect(controller.state.position, isNot(const Duration(minutes: 45)));
    await controller.shutdown();
  });

  test(
    'recovery waits while inactive and resumes with prior play intent',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(events: events);
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        recoveryPolicy: const PlaybackRecoveryPolicy(
          seekRecoveryWindow: Duration(minutes: 1),
          stablePlaybackWindow: Duration(minutes: 1),
        ),
      );
      await controller.start();
      engine.playingController.add(true);
      await controller.seekAbsolute(
        const Duration(minutes: 5),
        source: SeekSource.remote,
      );
      await controller.pauseForLifecycle();
      engine.errorController.add('Input/output error');
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, PlaybackPhase.recoveryPending);
      expect(engine.openCalls, 1);

      await controller.resumeForLifecycle();
      await _waitUntil(() => engine.openCalls == 2);

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.isPlaying, isTrue);
      await controller.shutdown();
    },
  );

  test('100 requests perform only two post-seek cache checks', () async {
    final events = <String>[];
    final seekGate = Completer<void>();
    final engine = _CacheEngine(events: events, seekGate: seekGate);
    final storage = _CacheStorage(events);
    final controller = _controller(engine: engine, storage: storage);
    await controller.start();
    final readsBefore = engine.snapshotReads;
    final freeReadsBefore = storage.freeReads;

    final requests = List<Future<SeekResult>>.generate(
      100,
      (index) => controller.seekAbsolute(
        Duration(seconds: index + 1),
        source: SeekSource.horizontalDrag,
      ),
    );
    await _waitUntil(() => engine.seekCalls == 1);
    seekGate.complete();
    final results = await Future.wait(requests);

    expect(engine.seekCalls, 2);
    expect(engine.maxConcurrentSeeks, 1);
    expect(
      results.where((result) => result.disposition == SeekDisposition.executed),
      hasLength(2),
    );
    expect(engine.snapshotReads - readsBefore, 2);
    expect(storage.freeReads - freeReadsBefore, 2);
    await controller.shutdown();
  });

  test(
    'acceptance overrides replace profile targets for one controller',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(events: events);
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        testOverrides: const PlaybackDiagnosticsTestOverrides(
          streamBufferBytes: 2 << 20,
          sessionTargetBytes: 256 << 20,
        ),
      );

      await controller.start();

      expect(engine.lastProfile?.streamBufferBytes, 2 << 20);
      expect(engine.lastProfile?.sessionTargetBytes, 256 << 20);
      await controller.shutdown();
    },
  );

  test('simulated low storage uses the normal safe fallback path', () async {
    final events = <String>[];
    final engine = _CacheEngine(events: events);
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
      testOverrides: const PlaybackDiagnosticsTestOverrides(
        storageSimulation: PlaybackDiagnosticsStorageSimulation.lowSpace,
      ),
    );

    await controller.start();

    expect(
      controller.state.cacheRuntimeMode,
      PlaybackCacheRuntimeMode.memoryFallback,
    );
    expect(
      controller.state.cacheFallbackReason,
      PlaybackCacheFallbackReason.lowSpace,
    );
    await controller.shutdown();
  });

  test(
    'acceptance failure observations are bounded and use real recovery',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(
        events: events,
        snapshot: const PlaybackCacheEngineSnapshot(
          fileCacheBytes: null,
          rawInputRateBytesPerSecond: null,
          seekableRanges: [],
          pausedForCache: false,
          cacheBufferingPercent: null,
          cacheOnDisk: false,
        ),
      );
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        recoveryPolicy: const PlaybackRecoveryPolicy(
          seekRecoveryWindow: Duration(minutes: 1),
          stablePlaybackWindow: Duration(minutes: 1),
        ),
        testOverrides: const PlaybackDiagnosticsTestOverrides(
          injectApprovedSeekFailureAfterNextExecutedSeek: true,
          forceCacheCreateFailureObservation: true,
        ),
      );

      await controller.start();
      expect(controller.state.diskCacheFailureObserved, isTrue);
      expect(
        controller.state.cacheRuntimeMode,
        PlaybackCacheRuntimeMode.memoryFallback,
      );
      await controller.seekAbsolute(
        const Duration(minutes: 5),
        source: SeekSource.controls,
      );
      await _waitUntil(() => engine.openCalls == 2);

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(engine.openCalls, 2);
      await controller.shutdown();
    },
  );

  test(
    'same-method recovery failure uses one transcode fallback transaction',
    () async {
      final events = <String>[];
      final reporter = _TrackingReporter();
      final session = PlaybackItemSession.forTest('recovery-transcode');
      final engine = _CacheEngine(events: events, noReadyOnOpen: const {2});
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        session: session,
        reporter: reporter,
        readyTimeout: const Duration(milliseconds: 20),
        recoveryPolicy: const PlaybackRecoveryPolicy(
          seekRecoveryWindow: Duration(minutes: 1),
          stablePlaybackWindow: Duration(minutes: 1),
        ),
      );

      await controller.start();
      await controller.seekAbsolute(
        const Duration(minutes: 5),
        source: SeekSource.horizontalDrag,
      );
      engine.errorController.add('partial file');
      await _waitUntil(() => engine.openCalls == 3);

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.plan?.method, PlayMethod.transcode);
      expect(controller.sessionId, session.id);
      expect(reporter.activateCalls, 3);
      expect(reporter.stopCalls, 2);
      expect(
        session.hasUsed(AutomaticPlaybackOpenReason.runtimeSameMethodRecovery),
        isTrue,
      );
      expect(
        session.hasUsed(AutomaticPlaybackOpenReason.runtimeTranscodeRecovery),
        isTrue,
      );

      await controller.shutdown();
      expect(reporter.stopCalls, 3);
    },
  );

  test('runtime recovery has one fixed total deadline', () async {
    final events = <String>[];
    final diagnostics = <String>[];
    final engine = _CacheEngine(events: events, noReadyOnOpen: const {2});
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
      diagnostics: _diagnostics(diagnostics),
      readyTimeout: const Duration(hours: 1),
      recoveryPolicy: const PlaybackRecoveryPolicy(
        seekRecoveryWindow: Duration(minutes: 1),
        stablePlaybackWindow: Duration(minutes: 1),
        recoveryAttemptTimeout: Duration(milliseconds: 20),
      ),
    );
    await controller.start();
    await controller.seekAbsolute(
      const Duration(minutes: 5),
      source: SeekSource.controls,
    );

    engine.errorController.add('partial file');
    await _waitUntil(() => controller.state.phase == PlaybackPhase.failed);

    expect(engine.openCalls, 2);
    expect(controller.state.errorMessage, '播放连接异常，自动恢复失败，请返回后重试');
    expect(
      diagnostics,
      contains('event=playback_seek_recovery_failed fingerprint=partial_file'),
    );
    engine.durationController.add(const Duration(hours: 2));
    engine.positionController.add(const Duration(minutes: 45));
    await Future<void>.delayed(Duration.zero);
    expect(engine.openCalls, 2);
    expect(controller.state.phase, PlaybackPhase.failed);
    expect(controller.state.position, isNot(const Duration(minutes: 45)));
    await controller.shutdown();
  });

  test('stale engine events cannot write through a new generation', () async {
    final events = <String>[];
    final stopGate = Completer<void>();
    final engine = _CacheEngine(events: events, stopGate: stopGate);
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
    );
    await controller.start();
    engine.positionController.add(const Duration(minutes: 5));

    final reconfigure = controller.setMaximumBitrate(10 * 1000 * 1000);
    await _waitUntil(() => events.contains('stop'));
    engine.positionController.add(const Duration(minutes: 55));
    engine.errorController.add('late old-engine failure');

    expect(controller.state.position, const Duration(minutes: 5));
    expect(controller.state.phase, isNot(PlaybackPhase.failed));
    stopGate.complete();
    await reconfigure;
    expect(controller.state.position, const Duration(minutes: 5));
    await controller.shutdown();
  });

  test(
    'shutdown cancels queued reconfiguration before it can reopen',
    () async {
      final events = <String>[];
      final stopGate = Completer<void>();
      final engine = _CacheEngine(events: events, stopGate: stopGate);
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
      );
      await controller.start();

      final first = controller.setMaximumBitrate(10 * 1000 * 1000);
      await _waitUntil(() => events.contains('stop'));
      final pending = controller.setMaximumBitrate(20 * 1000 * 1000);
      final shutdown = controller.shutdown();

      await Future.wait([
        first,
        pending,
      ]).timeout(const Duration(milliseconds: 200));
      stopGate.complete();
      await shutdown;
      expect(engine.openCalls, 1);
      expect(controller.state.phase, PlaybackPhase.idle);
    },
  );

  test(
    'shutdown cancels active runtime recovery before it can reopen',
    () async {
      final events = <String>[];
      final stopGate = Completer<void>();
      final engine = _CacheEngine(events: events, stopGate: stopGate);
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
        recoveryPolicy: const PlaybackRecoveryPolicy(
          seekRecoveryWindow: Duration(minutes: 1),
          stablePlaybackWindow: Duration(minutes: 1),
        ),
      );
      await controller.start();
      await controller.seekAbsolute(
        const Duration(minutes: 5),
        source: SeekSource.controls,
      );

      engine.errorController.add('partial file');
      await _waitUntil(
        () => controller.state.phase == PlaybackPhase.recovering,
      );
      await _waitUntil(() => events.contains('stop'));
      final shutdown = controller.shutdown();
      await Future<void>.delayed(Duration.zero);

      expect(engine.openCalls, 1);
      stopGate.complete();
      await shutdown;
      expect(engine.openCalls, 1);
      expect(controller.state.phase, PlaybackPhase.idle);
    },
  );

  test('shutdown cancels active cache safety before it can reopen', () async {
    final events = <String>[];
    final stopGate = Completer<void>();
    final engine = _CacheEngine(events: events, stopGate: stopGate);
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
    );
    await controller.start();

    final safety = controller.handleMemoryPressure();
    await _waitUntil(() => events.contains('stop'));
    final shutdown = controller.shutdown();
    await safety.timeout(const Duration(milliseconds: 200));

    expect(engine.openCalls, 1);
    stopGate.complete();
    await shutdown;
    expect(engine.openCalls, 1);
    expect(controller.state.phase, PlaybackPhase.idle);
  });

  test('100 playback cycles leave no active cache sessions', () async {
    for (var index = 0; index < 100; index++) {
      final events = <String>[];
      final storage = _CacheStorage(events);
      final engine = _CacheEngine(events: events);
      final controller = _controller(engine: engine, storage: storage);

      await controller.start();
      await controller.shutdown();

      expect(storage.activeSessions, 0, reason: 'cycle ${index + 1}');
      expect(
        events.where((event) => event == 'cleanup'),
        hasLength(1),
        reason: 'cycle ${index + 1}',
      );
      expect(engine.hasAnyListener, isFalse, reason: 'cycle ${index + 1}');
    }
  });

  test('raw engine output and item metadata never enter diagnostics', () async {
    final lines = <String>[];
    DiagnosticLog.instance.setTestSink(lines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final events = <String>[];
    final engine = _CacheEngine(events: events);
    final controller = _controller(
      engine: engine,
      storage: _CacheStorage(events),
    );
    await controller.start();

    engine.logController.add(
      r'Authorization: Bearer secret-token https://private.example/media/'
      r'secret-title.mkv C:\Users\owner\private-cache',
    );
    engine.errorController.add('secret-title.mkv raw failure');
    await Future<void>.delayed(Duration.zero);
    await controller.shutdown();

    final joined = lines.join('\n').toLowerCase();
    expect(joined, contains('event=libmpv_log fingerprint=other'));
    for (final forbidden in const [
      'private-item-id',
      'secret-title',
      'secret-token',
      'private.example',
      r'c:\users',
      'authorization',
      'bearer',
    ]) {
      expect(joined, isNot(contains(forbidden)));
    }
  });
}

PlaybackController _controller({
  required _CacheEngine engine,
  required _CacheStorage storage,
  PlaybackItemSession? session,
  PlaybackEngineRecreator? engineRecreator,
  PlaybackRecoveryPolicy recoveryPolicy = const PlaybackRecoveryPolicy(),
  PlaybackDiagnosticsTestOverrides? testOverrides,
  PlaybackDiagnostics? diagnostics,
  PlaybackReporter? reporter,
  Duration readyTimeout = const Duration(seconds: 18),
  PlaybackClock? clock,
}) => PlaybackController(
  item: _item,
  engine: engine,
  resolver: const _Resolver(),
  reporter: reporter ?? _Reporter(),
  playbackHeaders: const {},
  session: session,
  engineRecreator: engineRecreator,
  cacheStorage: storage,
  cacheSettings: const PlaybackCacheSettings(
    mode: PlaybackCacheMode.balanced,
    reservedFreeBytes: 2 << 30,
  ),
  testOverrides: testOverrides,
  diagnostics: diagnostics,
  readyTimeout: readyTimeout,
  progressInterval: const Duration(hours: 1),
  cacheStatePollInterval: const Duration(hours: 1),
  cacheSpacePollInterval: const Duration(hours: 1),
  recoveryPolicy: recoveryPolicy,
  clock: clock,
);

class _CacheStorage implements PlaybackCacheStorage {
  _CacheStorage(this.events);

  final List<String> events;
  int prepares = 0;
  int freeReads = 0;
  int freeBytes = 20 << 30;
  int activeSessions = 0;

  @override
  Future<void> cleanupNonActiveMarkedSessions() async {}

  @override
  Future<void> cleanupSession(PlaybackCacheSession session) async {
    events.add('cleanup');
    activeSessions--;
  }

  @override
  Future<int?> freeBytesFor(Directory directory) async {
    freeReads++;
    return freeBytes;
  }

  @override
  Future<PlaybackCacheStorageSnapshot> prepareSession() async {
    prepares++;
    activeSessions++;
    events.add('prepare');
    return PlaybackCacheStorageSnapshot.available(
      session: PlaybackCacheSession(
        directory: Directory.systemTemp,
        nonce: '0123456789abcdef0123456789abcdef',
      ),
      freeBytes: freeBytes,
    );
  }
}

class _CacheEngine implements PlaybackEngine, PlaybackCacheEngine {
  _CacheEngine({
    required this.events,
    this.snapshot,
    this.requireRecreationAfterOpen = false,
    this.seekGate,
    this.stopGate,
    this.noReadyOnOpen = const {},
    this.logsOnOpen = const {},
  });

  final List<String> events;
  PlaybackCacheEngineSnapshot? snapshot;
  final bool requireRecreationAfterOpen;
  final Completer<void>? seekGate;
  final Completer<void>? stopGate;
  final Set<int> noReadyOnOpen;
  final Map<int, List<String>> logsOnOpen;
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<String>.broadcast(sync: true);
  final logController = StreamController<String>.broadcast(sync: true);
  final audioController = StreamController<List<EngineTrack>>.broadcast(
    sync: true,
  );
  final subtitleController = StreamController<List<EngineTrack>>.broadcast(
    sync: true,
  );
  int openCalls = 0;
  int snapshotReads = 0;
  int seekCalls = 0;
  int concurrentSeeks = 0;
  int maxConcurrentSeeks = 0;
  ResolvedPlaybackCacheProfile? lastProfile;
  final List<ResolvedPlaybackCacheProfile> configuredProfiles = [];

  bool get hasAnyListener =>
      positionController.hasListener ||
      durationController.hasListener ||
      bufferController.hasListener ||
      playingController.hasListener ||
      bufferingController.hasListener ||
      completedController.hasListener ||
      errorController.hasListener ||
      logController.hasListener ||
      audioController.hasListener ||
      subtitleController.hasListener;

  @override
  Stream<List<EngineTrack>> get audioTracksStream => audioController.stream;
  @override
  Stream<Duration> get bufferStream => bufferController.stream;
  @override
  Stream<bool> get bufferingStream => bufferingController.stream;
  @override
  Stream<bool> get completedStream => completedController.stream;
  @override
  Stream<Duration> get durationStream => durationController.stream;
  @override
  Stream<String> get errorStream => errorController.stream;
  @override
  Stream<String> get logStream => logController.stream;
  @override
  Stream<bool> get playingStream => playingController.stream;
  @override
  Stream<Duration> get positionStream => positionController.stream;
  @override
  Stream<List<EngineTrack>> get subtitleTracksStream =>
      subtitleController.stream;

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) async {
    events.add('configure');
    lastProfile = profile;
    configuredProfiles.add(profile);
    if (requireRecreationAfterOpen && openCalls > 0) {
      return PlaybackCacheApplyResult(
        requestedMode: profile.runtimeMode,
        actualMode: PlaybackCacheRuntimeMode.unconfirmed,
        fallbackReason: PlaybackCacheFallbackReason.actualModeUnconfirmed,
        requiresPlayerRecreation: true,
        readBack: const {},
      );
    }
    return PlaybackCacheApplyResult(
      requestedMode: profile.runtimeMode,
      actualMode: profile.runtimeMode,
      fallbackReason: profile.fallbackReason,
      requiresPlayerRecreation: false,
      readBack: const {'cache-on-disk': 'yes'},
    );
  }

  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {}

  @override
  Future<void> dispose() async {
    events.add('dispose');
    await Future.wait([
      positionController.close(),
      durationController.close(),
      bufferController.close(),
      playingController.close(),
      bufferingController.close(),
      completedController.close(),
      errorController.close(),
      logController.close(),
      audioController.close(),
      subtitleController.close(),
    ]);
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {}

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    openCalls++;
    events.add('open');
    for (final log in logsOnOpen[openCalls] ?? const <String>[]) {
      logController.add(log);
    }
    if (!noReadyOnOpen.contains(openCalls)) {
      durationController.add(const Duration(hours: 1));
    }
  }

  @override
  Future<void> pause() async => playingController.add(false);

  @override
  Future<void> play() async => playingController.add(true);

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() async {
    events.add('probe');
    return _capabilities();
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() async {
    snapshotReads++;
    return snapshot;
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    concurrentSeeks++;
    if (concurrentSeeks > maxConcurrentSeeks) {
      maxConcurrentSeeks = concurrentSeeks;
    }
    await seekGate?.future;
    positionController.add(position);
    concurrentSeeks--;
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {}

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {}

  @override
  Future<void> setAudioDelay(Duration delay) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setSubtitleDelay(Duration delay) async {}

  @override
  Future<void> stop() async {
    events.add('stop');
    await stopGate?.future;
  }
}

class _Resolver implements PlaybackStreamResolver {
  const _Resolver();

  @override
  bool get canForceTranscode => true;

  @override
  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async => PlaybackPlan(
    uri: Uri.https('media.test', '/video.mp4'),
    mediaSourceId: 'source',
    playSessionId: 'play-session',
    method: forceTranscode ? PlayMethod.transcode : PlayMethod.directPlay,
    usesServerAuthentication: false,
    mediaStreams: const [],
    transcodingReasons: const [],
    availableMediaSources: const [],
    bitrate: 8 * 1000 * 1000,
    duration: const Duration(hours: 1),
    transportKind: PlaybackTransportKind.progressiveHttp,
  );

  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
}

class _Reporter implements PlaybackReporter {
  @override
  void activate(PlaybackPlan plan) {}
  @override
  Future<void> cleanup(PlaybackPlan plan) async {}
  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {}
  @override
  Future<void> reportStart(Duration position) async {}
  @override
  Future<void> stop(Duration position) async {}
  @override
  void updatePlan(PlaybackPlan plan) {}
}

class _TrackingReporter implements PlaybackReporter {
  int activateCalls = 0;
  int stopCalls = 0;

  @override
  void activate(PlaybackPlan plan) => activateCalls++;
  @override
  Future<void> cleanup(PlaybackPlan plan) async {}
  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {}
  @override
  Future<void> reportStart(Duration position) async {}
  @override
  Future<void> stop(Duration position) async => stopCalls++;
  @override
  void updatePlan(PlaybackPlan plan) {}
}

PlaybackDiagnostics _diagnostics(List<String> lines) => PlaybackDiagnostics(
  writer: (_, _, message) => lines.add(message),
  seekFlushInterval: const Duration(hours: 1),
);

PlaybackCacheEngineCapabilities _capabilities() =>
    PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: 'mpv-test',
      platform: 'test',
      optionSupport: {
        for (final option in playbackCacheOptionNames) option: true,
      },
      propertySupport: {
        for (final property in playbackCachePropertyNames) property: true,
      },
      supportsImmediateUnlink: true,
      profileSwitchStrategy:
          PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      resetValues: {
        for (final option in playbackCacheProfileOptionNames)
          option: option == 'demuxer-cache-dir' ? '' : 'auto',
      },
    );

const _item = EmbyItem(
  id: 'private-item-id',
  name: 'secret-title',
  type: 'Movie',
  mediaType: 'Video',
  runTimeTicks: 36000000000,
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the playback state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
