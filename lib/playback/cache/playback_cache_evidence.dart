import '../playback_operation_coordinator.dart';
import 'playback_cache_engine.dart';
import 'playback_cache_policy.dart';
import 'playback_cache_telemetry.dart';

enum PlaybackCacheCreateResult { succeeded, failed, unavailable }

enum PlaybackCacheSnapshotResult { available, unavailable }

enum PlaybackCacheReopenReason { budget, lowSpace, memoryPressure, unknown }

enum PlaybackCacheCleanupResult { succeeded, failed, timedOut, notApplicable }

class PlaybackCacheEvidenceObservation {
  const PlaybackCacheEvidenceObservation({
    this.cacheEvidence = PlaybackCacheEvidence.unconfirmed,
    this.telemetryStatus,
    this.fileCacheBytes,
    this.actualForward,
    this.actualBackward,
    this.cacheCreateResult,
    this.cacheSnapshotResult,
    this.reopenReason,
    this.cleanupResult,
    this.cacheEnabled,
    this.cacheOnDisk,
    this.requestedMode,
    this.confirmedMode,
    this.fallbackReason,
    this.optionalTuningDegraded = false,
    this.optionalTuningUnavailableCount = 0,
    this.testOverrideActive = false,
  });

  final PlaybackCacheEvidence cacheEvidence;
  final PlaybackCacheTelemetryStatus? telemetryStatus;
  final int? fileCacheBytes;
  final Duration? actualForward;
  final Duration? actualBackward;
  final PlaybackCacheCreateResult? cacheCreateResult;
  final PlaybackCacheSnapshotResult? cacheSnapshotResult;
  final PlaybackCacheReopenReason? reopenReason;
  final PlaybackCacheCleanupResult? cleanupResult;
  final bool? cacheEnabled;
  final bool? cacheOnDisk;
  final PlaybackCacheRuntimeMode? requestedMode;
  final PlaybackCacheRuntimeMode? confirmedMode;
  final PlaybackCacheFallbackReason? fallbackReason;
  final bool optionalTuningDegraded;
  final int optionalTuningUnavailableCount;
  final bool testOverrideActive;
}

class PlaybackCacheEvidenceSummary {
  const PlaybackCacheEvidenceSummary({
    required this.sessionId,
    required this.cacheEvidence,
    required this.telemetryStatuses,
    required this.observedNonzeroBytes,
    required this.peakBytes,
    required this.maxActualForward,
    required this.maxActualBackward,
    required this.cacheCreateResults,
    required this.snapshotUnavailableCount,
    required this.reopenReasons,
    required this.cleanupResult,
    required this.observationCount,
    required this.cacheEnabledEver,
    required this.cacheOnDiskEver,
    required this.requestedMode,
    required this.finalConfirmedMode,
    required this.fallbackReason,
    required this.optionalTuningDegraded,
    required this.optionalTuningUnavailableCount,
    required this.testOverrideUsed,
    required this.seekRequested,
    required this.seekExecuted,
    required this.seekSuperseded,
    required this.seekFailed,
    required this.seekCancelled,
  });

  final PlaybackItemSessionId sessionId;
  final PlaybackCacheEvidence cacheEvidence;
  final Set<PlaybackCacheTelemetryStatus> telemetryStatuses;
  final bool observedNonzeroBytes;
  final int peakBytes;
  final Duration? maxActualForward;
  final Duration? maxActualBackward;
  final Set<PlaybackCacheCreateResult> cacheCreateResults;
  final int snapshotUnavailableCount;
  final Set<PlaybackCacheReopenReason> reopenReasons;
  final PlaybackCacheCleanupResult? cleanupResult;
  final int observationCount;
  final bool? cacheEnabledEver;
  final bool? cacheOnDiskEver;
  final PlaybackCacheRuntimeMode? requestedMode;
  final PlaybackCacheRuntimeMode? finalConfirmedMode;
  final PlaybackCacheFallbackReason? fallbackReason;
  final bool optionalTuningDegraded;
  final int optionalTuningUnavailableCount;
  final bool testOverrideUsed;
  final int seekRequested;
  final int seekExecuted;
  final int seekSuperseded;
  final int seekFailed;
  final int seekCancelled;
}

class PlaybackCacheEvidenceAccumulator {
  PlaybackCacheEvidenceAccumulator({
    required this.sessionId,
    DateTime Function()? clock,
    this.observationThrottle = const Duration(seconds: 5),
  }) : _clock = clock ?? DateTime.now;

  final PlaybackItemSessionId sessionId;
  final Duration observationThrottle;
  final DateTime Function() _clock;

  DateTime? _lastObservationAt;
  PlaybackCacheEvidenceObservation? _pending;
  PlaybackCacheEvidenceSummary? _summary;
  PlaybackCacheEvidence _evidence = PlaybackCacheEvidence.unconfirmed;
  final Set<PlaybackCacheTelemetryStatus> _telemetryStatuses = {};
  final Set<PlaybackCacheCreateResult> _createResults = {};
  final Set<PlaybackCacheReopenReason> _reopenReasons = {};
  bool _observedNonzeroBytes = false;
  int _peakBytes = 0;
  Duration? _maxForward;
  Duration? _maxBackward;
  int _snapshotUnavailableCount = 0;
  int _observationCount = 0;
  bool? _cacheEnabledEver;
  bool? _cacheOnDiskEver;
  PlaybackCacheCleanupResult? _cleanupResult;
  PlaybackCacheRuntimeMode? _requestedMode;
  PlaybackCacheRuntimeMode? _finalConfirmedMode;
  PlaybackCacheFallbackReason? _fallbackReason;
  bool _optionalTuningDegraded = false;
  int _optionalTuningUnavailableCount = 0;
  bool _testOverrideUsed = false;
  int _seekRequested = 0;
  int _seekExecuted = 0;
  int _seekSuperseded = 0;
  int _seekFailed = 0;
  int _seekCancelled = 0;

  bool get hasPendingObservation => _pending != null;
  bool get isFinalized => _summary != null;
  PlaybackCacheEvidenceObservation? get lastAppliedObservation => _lastApplied;

  PlaybackCacheEvidenceObservation? _lastApplied;

  bool observe(PlaybackCacheEvidenceObservation observation) {
    _checkOpen();
    final now = _clock();
    if (_lastObservationAt == null ||
        now.difference(_lastObservationAt!) >= observationThrottle) {
      _applyObservation(observation);
      _lastObservationAt = now;
      return true;
    }
    _pending = observation;
    return false;
  }

  bool flush() {
    _checkOpen();
    final observation = _pending;
    if (observation == null) return false;
    _pending = null;
    _applyObservation(observation);
    _lastObservationAt = _clock();
    return true;
  }

  void recordCacheCreate(PlaybackCacheCreateResult result) {
    _checkOpen();
    _createResults.add(result);
  }

  void recordCacheSnapshotUnavailable() {
    _checkOpen();
    _snapshotUnavailableCount++;
  }

  void recordReopen(PlaybackCacheReopenReason reason) {
    _checkOpen();
    _reopenReasons.add(reason);
  }

  void recordCleanup(PlaybackCacheCleanupResult result) {
    _checkOpen();
    if (_cleanupResult == null ||
        _cleanupPriority(result) > _cleanupPriority(_cleanupResult!)) {
      _cleanupResult = result;
    }
  }

  void recordSeekRequested() {
    _checkOpen();
    _seekRequested++;
  }

  void recordSeekCompleted(SeekDisposition disposition) {
    _checkOpen();
    switch (disposition) {
      case SeekDisposition.executed:
        _seekExecuted++;
      case SeekDisposition.superseded:
        _seekSuperseded++;
      case SeekDisposition.failed:
        _seekFailed++;
      case SeekDisposition.cancelled:
        _seekCancelled++;
    }
  }

  PlaybackCacheEvidenceSummary finalize() {
    final existing = _summary;
    if (existing != null) return existing;
    if (_pending != null) flush();
    return _summary = PlaybackCacheEvidenceSummary(
      sessionId: sessionId,
      cacheEvidence: _evidence,
      telemetryStatuses: Set.unmodifiable({..._telemetryStatuses}),
      observedNonzeroBytes: _observedNonzeroBytes,
      peakBytes: _peakBytes,
      maxActualForward: _maxForward,
      maxActualBackward: _maxBackward,
      cacheCreateResults: Set.unmodifiable({..._createResults}),
      snapshotUnavailableCount: _snapshotUnavailableCount,
      reopenReasons: Set.unmodifiable({..._reopenReasons}),
      cleanupResult: _cleanupResult,
      observationCount: _observationCount,
      cacheEnabledEver: _cacheEnabledEver,
      cacheOnDiskEver: _cacheOnDiskEver,
      requestedMode: _requestedMode,
      finalConfirmedMode: _finalConfirmedMode,
      fallbackReason: _fallbackReason,
      optionalTuningDegraded: _optionalTuningDegraded,
      optionalTuningUnavailableCount: _optionalTuningUnavailableCount,
      testOverrideUsed: _testOverrideUsed,
      seekRequested: _seekRequested,
      seekExecuted: _seekExecuted,
      seekSuperseded: _seekSuperseded,
      seekFailed: _seekFailed,
      seekCancelled: _seekCancelled,
    );
  }

  void _applyObservation(PlaybackCacheEvidenceObservation observation) {
    _lastApplied = observation;
    _observationCount++;
    if (_evidencePriority(observation.cacheEvidence) >
        _evidencePriority(_evidence)) {
      _evidence = observation.cacheEvidence;
    }
    final telemetry = observation.telemetryStatus;
    if (telemetry != null) _telemetryStatuses.add(telemetry);
    final bytes = observation.fileCacheBytes;
    if (bytes != null && bytes >= 0) {
      _observedNonzeroBytes = _observedNonzeroBytes || bytes > 0;
      if (bytes > _peakBytes) _peakBytes = bytes;
    }
    _maxForward = _maxDuration(_maxForward, observation.actualForward);
    _maxBackward = _maxDuration(_maxBackward, observation.actualBackward);
    if (observation.cacheCreateResult != null) {
      _createResults.add(observation.cacheCreateResult!);
    }
    if (observation.cacheSnapshotResult ==
        PlaybackCacheSnapshotResult.unavailable) {
      _snapshotUnavailableCount++;
    }
    if (observation.reopenReason != null) {
      _reopenReasons.add(observation.reopenReason!);
    }
    if (observation.cleanupResult != null) {
      recordCleanup(observation.cleanupResult!);
    }
    if (observation.cacheEnabled == true) _cacheEnabledEver = true;
    if (observation.cacheEnabled == false && _cacheEnabledEver == null) {
      _cacheEnabledEver = false;
    }
    if (observation.cacheOnDisk == true) {
      _cacheOnDiskEver = true;
    }
    if (observation.cacheOnDisk == false && _cacheOnDiskEver == null) {
      _cacheOnDiskEver = false;
    }
    _requestedMode ??= observation.requestedMode;
    if (observation.confirmedMode != null) {
      _finalConfirmedMode = observation.confirmedMode;
    }
    if (observation.fallbackReason != null) {
      _fallbackReason = observation.fallbackReason;
    }
    _optionalTuningDegraded =
        _optionalTuningDegraded || observation.optionalTuningDegraded;
    _optionalTuningUnavailableCount +=
        observation.optionalTuningUnavailableCount;
    _testOverrideUsed = _testOverrideUsed || observation.testOverrideActive;
  }

  void _checkOpen() {
    if (_summary != null) {
      throw StateError('Playback cache evidence is finalized');
    }
  }

  static Duration? _maxDuration(Duration? a, Duration? b) =>
      b == null || (a != null && a >= b) ? a : b;

  static int _evidencePriority(PlaybackCacheEvidence value) => switch (value) {
    PlaybackCacheEvidence.unconfirmed => 0,
    PlaybackCacheEvidence.disabled => 1,
    PlaybackCacheEvidence.memoryProfileConfirmed => 2,
    PlaybackCacheEvidence.diskConfiguredOnly => 3,
    PlaybackCacheEvidence.diskDataObserved => 4,
  };

  static int _cleanupPriority(PlaybackCacheCleanupResult value) =>
      switch (value) {
        PlaybackCacheCleanupResult.notApplicable => 0,
        PlaybackCacheCleanupResult.succeeded => 1,
        PlaybackCacheCleanupResult.failed => 2,
        PlaybackCacheCleanupResult.timedOut => 3,
      };
}
