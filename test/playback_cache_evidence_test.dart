import 'package:flutter_test/flutter_test.dart';
import 'package:emby_my_client/playback/cache/playback_cache_evidence.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';

void main() {
  test('observation is throttled and keeps the latest pending bucket', () {
    var now = DateTime(2026, 1, 1);
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('session-a'),
      clock: () => now,
    );

    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 1024),
      ),
      isTrue,
    );
    now = now.add(const Duration(seconds: 1));
    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 20 << 20),
      ),
      isFalse,
    );
    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 70 << 20),
      ),
      isFalse,
    );
    now = now.add(const Duration(seconds: 1));
    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 300 << 20),
      ),
      isFalse,
    );
    expect(accumulator.flush(), isTrue);

    final summary = accumulator.finalize();
    expect(summary.observationCount, 2);
    expect(summary.peakBytes, 300 << 20);
    expect(accumulator.lastAppliedObservation?.fileCacheBytes, 300 << 20);
    expect(accumulator.hasPendingObservation, isFalse);
  });

  test('600 identical one-second samples dedupe and finalize once', () {
    var now = DateTime.utc(2026, 8, 12);
    final applied = <PlaybackCacheEvidenceObservation>[];
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('stable-ten-minutes'),
      clock: () => now,
      onObservationApplied: applied.add,
    );
    const sample = PlaybackCacheEvidenceObservation(
      cacheEvidence: PlaybackCacheEvidence.memoryProfileConfirmed,
      telemetryStatus: PlaybackCacheTelemetryStatus.available,
      cacheEnabled: true,
      cacheOnDisk: false,
      requestedMode: PlaybackCacheRuntimeMode.memory,
      confirmedMode: PlaybackCacheRuntimeMode.memory,
    );

    for (var index = 0; index < 600; index++) {
      accumulator.observe(sample);
      now = now.add(const Duration(seconds: 1));
    }

    final first = accumulator.finalize();
    final second = accumulator.finalize();
    expect(applied.length, lessThanOrEqualTo(2));
    expect(first.observationCount, 1);
    expect(identical(first, second), isTrue);
  });

  test('summary write ownership is claimed once per session', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('summary-write-once'),
    );

    final first = accumulator.claimSummaryForWrite();
    final second = accumulator.claimSummaryForWrite();

    expect(first, isNotNull);
    expect(second, isNull);
    expect(accumulator.summaryWritten, isTrue);
  });

  test('aggregate-only observation changes are not deduplicated away', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('aggregate-fingerprint'),
    );
    accumulator.observe(const PlaybackCacheEvidenceObservation());
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        cacheCreateResult: PlaybackCacheCreateResult.failed,
        cacheSnapshotResult: PlaybackCacheSnapshotResult.unavailable,
        reopenReason: PlaybackCacheReopenReason.lowSpace,
        cleanupResult: PlaybackCacheCleanupResult.failed,
        optionalTuningUnavailableCount: 1,
      ),
    );

    final summary = accumulator.finalize();
    expect(summary.cacheCreateFailedObserved, isTrue);
    expect(summary.cacheSnapshotUnavailableObserved, isTrue);
    expect(summary.safetyReopenReason, PlaybackCacheReopenReason.lowSpace);
    expect(summary.cleanupResult, PlaybackCacheCleanupResult.failed);
    expect(summary.optionalTuningUnavailableCount, 1);
  });

  test('evidence precedence keeps the strongest evidence ever observed', () {
    var now = DateTime(2026, 1, 1);
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('session-b'),
      clock: () => now,
    );
    for (final evidence in [
      PlaybackCacheEvidence.disabled,
      PlaybackCacheEvidence.diskConfiguredOnly,
      PlaybackCacheEvidence.memoryProfileConfirmed,
      PlaybackCacheEvidence.diskDataObserved,
      PlaybackCacheEvidence.unconfirmed,
    ]) {
      accumulator.observe(
        PlaybackCacheEvidenceObservation(cacheEvidence: evidence),
      );
      accumulator.flush();
      now = now.add(const Duration(seconds: 5));
    }
    expect(
      accumulator.finalize().cacheEvidence,
      PlaybackCacheEvidence.diskDataObserved,
    );
  });

  test(
    'critical changes bypass throttle and identical fingerprints dedupe',
    () {
      var now = DateTime(2026, 1, 1);
      final applied = <PlaybackCacheEvidenceObservation>[];
      final accumulator = PlaybackCacheEvidenceAccumulator(
        sessionId: const PlaybackItemSessionId('session-immediate'),
        clock: () => now,
        onObservationApplied: applied.add,
      );
      const base = PlaybackCacheEvidenceObservation(
        cacheEvidence: PlaybackCacheEvidence.diskConfiguredOnly,
        telemetryStatus: PlaybackCacheTelemetryStatus.fieldTemporarilyAbsent,
        cacheOnDisk: true,
        fileCacheBytes: 0,
      );
      expect(accumulator.observe(base), isTrue);
      expect(accumulator.observe(base), isFalse);
      expect(applied, hasLength(1));

      now = now.add(const Duration(seconds: 1));
      expect(
        accumulator.observe(
          const PlaybackCacheEvidenceObservation(
            cacheEvidence: PlaybackCacheEvidence.diskConfiguredOnly,
            telemetryStatus: PlaybackCacheTelemetryStatus.available,
            cacheOnDisk: true,
            fileCacheBytes: 0,
          ),
        ),
        isTrue,
      );
      expect(applied, hasLength(2));
    },
  );

  test(
    'pending bucket flushes automatically at the throttle boundary',
    () async {
      final applied = <PlaybackCacheEvidenceObservation>[];
      final accumulator = PlaybackCacheEvidenceAccumulator(
        sessionId: const PlaybackItemSessionId('session-timer'),
        observationThrottle: const Duration(milliseconds: 20),
        onObservationApplied: applied.add,
      );
      expect(
        accumulator.observe(
          const PlaybackCacheEvidenceObservation(fileCacheBytes: 1),
        ),
        isTrue,
      );
      expect(
        accumulator.observe(
          const PlaybackCacheEvidenceObservation(fileCacheBytes: 20 << 20),
        ),
        isFalse,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(applied, hasLength(2));
      expect(applied.last.fileCacheBytes, 20 << 20);
    },
  );

  test('summary is idempotent and finalization is immutable', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('session-c'),
    );
    accumulator.recordCleanup(PlaybackCacheCleanupResult.succeeded);
    final first = accumulator.finalize();
    final second = accumulator.finalize();
    expect(identical(first, second), isTrue);
    expect(
      () => accumulator.recordReopen(PlaybackCacheReopenReason.lowSpace),
      throwsStateError,
    );
  });

  test('cleanup result uses failure and timeout priority', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('session-d'),
    );
    accumulator.recordCleanup(PlaybackCacheCleanupResult.succeeded);
    accumulator.recordCleanup(PlaybackCacheCleanupResult.notApplicable);
    expect(
      accumulator.finalize().cleanupResult,
      PlaybackCacheCleanupResult.succeeded,
    );
  });

  test('cleanup result gives failure paths deterministic priority', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('session-d-priority'),
    );
    accumulator.recordCleanup(PlaybackCacheCleanupResult.notApplicable);
    accumulator.recordCleanup(PlaybackCacheCleanupResult.succeeded);
    accumulator.recordCleanup(PlaybackCacheCleanupResult.failed);
    accumulator.recordCleanup(PlaybackCacheCleanupResult.timedOut);
    accumulator.recordCleanup(PlaybackCacheCleanupResult.succeeded);
    expect(
      accumulator.finalize().cleanupResult,
      PlaybackCacheCleanupResult.timedOut,
    );
  });

  test(
    'summary contains aggregate telemetry, ranges, bytes, and event counts',
    () {
      final accumulator = PlaybackCacheEvidenceAccumulator(
        sessionId: const PlaybackItemSessionId('session-e'),
      );
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(
          telemetryStatus: PlaybackCacheTelemetryStatus.available,
          fileCacheBytes: 8,
          actualForward: Duration(seconds: 4),
          actualBackward: Duration(seconds: 2),
          cacheCreateResult: PlaybackCacheCreateResult.succeeded,
          cacheSnapshotResult: PlaybackCacheSnapshotResult.unavailable,
          reopenReason: PlaybackCacheReopenReason.budget,
          cacheEnabled: true,
          cacheOnDisk: true,
          requestedMode: PlaybackCacheRuntimeMode.disk,
          confirmedMode: PlaybackCacheRuntimeMode.disk,
          cacheEvidence: PlaybackCacheEvidence.diskConfiguredOnly,
          readAheadStrategy: PlaybackCacheReadAheadStrategy.mediaEnd,
          budgetPolicy: PlaybackCacheBudgetPolicy.lowSpaceOnly,
          sizeConfidence: PlaybackCacheSizeConfidence.estimated,
          fullReadAheadEligible: true,
          fullReadAheadReachedEnd: true,
        ),
      );
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(
          telemetryStatus: PlaybackCacheTelemetryStatus.readFailed,
          fileCacheBytes: 0,
          actualForward: Duration(seconds: 7),
          actualBackward: Duration(seconds: 1),
          cacheCreateResult: PlaybackCacheCreateResult.failed,
          reopenReason: PlaybackCacheReopenReason.lowSpace,
          cleanupResult: PlaybackCacheCleanupResult.failed,
          cacheEnabled: false,
          cacheOnDisk: false,
          requestedMode: PlaybackCacheRuntimeMode.disk,
          confirmedMode: PlaybackCacheRuntimeMode.memoryFallback,
          cacheEvidence: PlaybackCacheEvidence.memoryProfileConfirmed,
        ),
      );
      final summary = accumulator.finalize();
      expect(summary.sessionId, const PlaybackItemSessionId('session-e'));
      expect(
        summary.telemetryStatuses,
        containsAll([
          PlaybackCacheTelemetryStatus.available,
          PlaybackCacheTelemetryStatus.readFailed,
        ]),
      );
      expect(summary.observedNonzeroBytes, isTrue);
      expect(summary.peakBytes, 8);
      expect(summary.maxActualForward, const Duration(seconds: 7));
      expect(summary.maxActualBackward, const Duration(seconds: 2));
      expect(
        summary.cacheCreateResults,
        containsAll([
          PlaybackCacheCreateResult.succeeded,
          PlaybackCacheCreateResult.failed,
        ]),
      );
      expect(summary.snapshotUnavailableCount, 1);
      expect(
        summary.reopenReasons,
        containsAll([
          PlaybackCacheReopenReason.budget,
          PlaybackCacheReopenReason.lowSpace,
        ]),
      );
      expect(summary.cacheEnabledEver, isTrue);
      expect(summary.cacheOnDiskEver, isTrue);
      expect(
        summary.telemetryStatusEver,
        PlaybackCacheTelemetryStatusEver.available,
      );
      expect(summary.cacheCreateFailedObserved, isTrue);
      expect(summary.cacheSnapshotUnavailableObserved, isTrue);
      expect(summary.safetyReopenReason, PlaybackCacheReopenReason.multiple);
      expect(
        summary.runtimeRecovery,
        PlaybackCacheRuntimeRecovery.notAttempted,
      );
      expect(summary.cleanupAttemptCount, 1);
      expect(
        summary.readAheadStrategy,
        PlaybackCacheReadAheadStrategy.mediaEnd,
      );
      expect(summary.budgetPolicy, PlaybackCacheBudgetPolicy.lowSpaceOnly);
      expect(summary.sizeConfidence, PlaybackCacheSizeConfidence.estimated);
      expect(summary.fullReadAheadEligible, isTrue);
      expect(summary.fullReadAheadReachedEnd, isTrue);
    },
  );

  test(
    'runtime recovery aggregation keeps failed over success and cancellation',
    () {
      final accumulator = PlaybackCacheEvidenceAccumulator(
        sessionId: const PlaybackItemSessionId('recovery-priority'),
      );
      accumulator.recordRuntimeRecovery(PlaybackCacheRuntimeRecovery.cancelled);
      accumulator.recordRuntimeRecovery(PlaybackCacheRuntimeRecovery.succeeded);
      accumulator.recordRuntimeRecovery(PlaybackCacheRuntimeRecovery.failed);
      accumulator.recordRuntimeRecovery(PlaybackCacheRuntimeRecovery.cancelled);

      expect(
        accumulator.finalize().runtimeRecovery,
        PlaybackCacheRuntimeRecovery.failed,
      );
    },
  );

  test('missing values remain unavailable rather than becoming zero', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('missing-values'),
    );
    final summary = accumulator.finalize();
    expect(summary.peakBytes, isNull);
    expect(summary.maxActualForward, isNull);
    expect(summary.maxActualBackward, isNull);
    expect(summary.readAheadStrategy, isNull);
    expect(summary.budgetPolicy, isNull);
    expect(summary.sizeConfidence, isNull);
    expect(summary.fullReadAheadEligible, isNull);
    expect(summary.fullReadAheadReachedEnd, isNull);
  });

  test('full read-ahead completion evidence is sticky once confirmed', () {
    var now = DateTime.utc(2026, 8, 16);
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('completion-evidence'),
      clock: () => now,
    );
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        readAheadStrategy: PlaybackCacheReadAheadStrategy.mediaEnd,
        budgetPolicy: PlaybackCacheBudgetPolicy.lowSpaceOnly,
        sizeConfidence: PlaybackCacheSizeConfidence.unknown,
        fullReadAheadEligible: true,
        fullReadAheadReachedEnd: false,
      ),
    );
    now = now.add(const Duration(seconds: 5));
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        readAheadStrategy: PlaybackCacheReadAheadStrategy.mediaEnd,
        budgetPolicy: PlaybackCacheBudgetPolicy.lowSpaceOnly,
        sizeConfidence: PlaybackCacheSizeConfidence.unknown,
        fullReadAheadEligible: true,
        fullReadAheadReachedEnd: true,
      ),
    );
    now = now.add(const Duration(seconds: 5));
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        readAheadStrategy: PlaybackCacheReadAheadStrategy.mediaEnd,
        budgetPolicy: PlaybackCacheBudgetPolicy.lowSpaceOnly,
        sizeConfidence: PlaybackCacheSizeConfidence.unknown,
        fullReadAheadEligible: true,
        fullReadAheadReachedEnd: false,
      ),
    );

    final summary = accumulator.finalize();
    expect(summary.fullReadAheadReachedEnd, isTrue);
  });

  test('unconfirmed updates do not replace the last confirmed mode', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('confirmed-then-unconfirmed'),
    );
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        confirmedMode: PlaybackCacheRuntimeMode.disk,
        cacheEvidence: PlaybackCacheEvidence.diskConfiguredOnly,
      ),
    );
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        confirmedMode: PlaybackCacheRuntimeMode.unconfirmed,
        cacheEvidence: PlaybackCacheEvidence.unconfirmed,
      ),
    );

    expect(
      accumulator.finalize().finalConfirmedMode,
      PlaybackCacheRuntimeMode.disk,
    );
  });

  test(
    'profile failure before resolution reports requested mode unavailable',
    () {
      final accumulator = PlaybackCacheEvidenceAccumulator(
        sessionId: const PlaybackItemSessionId('profile-not-resolved'),
      );
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(
          requestedMode: PlaybackCacheRuntimeMode.unconfirmed,
          confirmedMode: PlaybackCacheRuntimeMode.unconfirmed,
        ),
      );

      expect(accumulator.finalize().requestedMode, isNull);
    },
  );

  test('controller-marked unavailable snapshot is counted only once', () {
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('snapshot-once'),
    );
    accumulator.recordCacheSnapshotUnavailable();
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        cacheSnapshotResult: PlaybackCacheSnapshotResult.unavailable,
        snapshotUnavailableAlreadyRecorded: true,
      ),
    );

    expect(accumulator.finalize().snapshotUnavailableCount, 1);
  });

  test(
    'memory fallback keeps requested mode as the original memory request',
    () {
      final accumulator = PlaybackCacheEvidenceAccumulator(
        sessionId: const PlaybackItemSessionId('memory-fallback-mode'),
      );
      accumulator.recordProfileResolved(
        PlaybackCacheRuntimeMode.memoryFallback,
      );

      expect(
        accumulator.finalize().requestedMode,
        PlaybackCacheRuntimeMode.memory,
      );
    },
  );

  test('disk data evidence requires available telemetry', () {
    expect(
      playbackCacheHasObservedDiskData(
        telemetryStatus: PlaybackCacheTelemetryStatus.readFailed,
        fileCacheBytes: 1024,
        cacheOnDisk: true,
      ),
      isFalse,
    );
    expect(
      playbackCacheHasObservedDiskData(
        telemetryStatus: PlaybackCacheTelemetryStatus.available,
        fileCacheBytes: 1024,
        cacheOnDisk: true,
      ),
      isTrue,
    );
  });
}
