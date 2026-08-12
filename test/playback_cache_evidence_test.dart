import 'package:flutter_test/flutter_test.dart';
import 'package:emby_my_client/playback/cache/playback_cache_evidence.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';

void main() {
  test('observation is throttled and keeps only the latest pending value', () {
    var now = DateTime(2026, 1, 1);
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('session-a'),
      clock: () => now,
    );

    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 2),
      ),
      isTrue,
    );
    now = now.add(const Duration(seconds: 1));
    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 3),
      ),
      isFalse,
    );
    expect(
      accumulator.observe(
        const PlaybackCacheEvidenceObservation(fileCacheBytes: 9),
      ),
      isFalse,
    );
    expect(accumulator.flush(), isTrue);

    final summary = accumulator.finalize();
    expect(summary.observationCount, 2);
    expect(summary.peakBytes, 9);
    expect(accumulator.hasPendingObservation, isFalse);
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
    },
  );
}
