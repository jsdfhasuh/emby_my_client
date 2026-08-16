import 'dart:async';

import '../playback_operation_coordinator.dart';
import 'playback_cache_engine.dart';
import 'playback_cache_option_bindings.dart';
import 'playback_cache_policy.dart';
import 'playback_cache_settings.dart';
import 'playback_cache_telemetry.dart';
import '../playback_seek_statistics.dart';

enum PlaybackCacheCreateResult { succeeded, failed, unavailable }

enum PlaybackCacheSnapshotResult { available, unavailable }

enum PlaybackCacheReopenReason {
  budget,
  lowSpace,
  memoryPressure,
  none,
  multiple,
}

enum PlaybackCacheCleanupResult { succeeded, failed, timedOut, notApplicable }

enum PlaybackCacheRuntimeRecovery { notAttempted, succeeded, failed, cancelled }

bool playbackCacheHasObservedDiskData({
  required PlaybackCacheTelemetryStatus? telemetryStatus,
  required int? fileCacheBytes,
  required bool? cacheOnDisk,
}) =>
    telemetryStatus == PlaybackCacheTelemetryStatus.available &&
    cacheOnDisk == true &&
    fileCacheBytes != null &&
    fileCacheBytes > 0;

String playbackCacheRequestedModeName(PlaybackCacheRuntimeMode? mode) =>
    switch (mode) {
      PlaybackCacheRuntimeMode.disk => 'disk',
      PlaybackCacheRuntimeMode.memory ||
      PlaybackCacheRuntimeMode.memoryFallback => 'memory',
      PlaybackCacheRuntimeMode.disabled => 'disabled',
      PlaybackCacheRuntimeMode.unconfirmed || null => 'unavailable',
    };

String playbackCacheConfirmedModeName(PlaybackCacheRuntimeMode? mode) =>
    switch (mode) {
      PlaybackCacheRuntimeMode.disk => 'disk',
      PlaybackCacheRuntimeMode.memory => 'memory',
      PlaybackCacheRuntimeMode.memoryFallback => 'memoryFallback',
      PlaybackCacheRuntimeMode.disabled => 'disabled',
      PlaybackCacheRuntimeMode.unconfirmed || null => 'unconfirmed',
    };

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
    this.readAheadStrategy,
    this.budgetPolicy,
    this.sizeConfidence,
    this.fullReadAheadEligible,
    this.fullReadAheadReachedEnd,
    this.settingsMode = PlaybackCacheMode.automatic,
    this.optionalTuningDegraded = false,
    this.optionalTuningUnavailableCount = 0,
    this.optionalTuningUnavailable = const {},
    this.snapshotUnavailableAlreadyRecorded = false,
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
  final PlaybackCacheReadAheadStrategy? readAheadStrategy;
  final PlaybackCacheBudgetPolicy? budgetPolicy;
  final PlaybackCacheSizeConfidence? sizeConfidence;
  final bool? fullReadAheadEligible;
  final bool? fullReadAheadReachedEnd;
  final PlaybackCacheMode settingsMode;
  final bool optionalTuningDegraded;
  final int optionalTuningUnavailableCount;
  final Set<PlaybackCacheLogicalOption> optionalTuningUnavailable;
  final bool snapshotUnavailableAlreadyRecorded;
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
    required this.optionalTuningUnavailable,
    required this.settingsMode,
    required this.telemetryStatusEver,
    required this.cacheCreateFailedObserved,
    required this.cacheSnapshotUnavailableObserved,
    required this.safetyReopenReason,
    required this.runtimeRecovery,
    required this.cleanupAttemptCount,
    required this.testOverrideUsed,
    required this.seekRequested,
    required this.seekExecuted,
    required this.seekSuperseded,
    required this.seekFailed,
    required this.seekCancelled,
    this.readAheadStrategy,
    this.budgetPolicy,
    this.sizeConfidence,
    this.fullReadAheadEligible,
    this.fullReadAheadReachedEnd,
  });

  final PlaybackItemSessionId sessionId;
  final PlaybackCacheEvidence cacheEvidence;
  final Set<PlaybackCacheTelemetryStatus> telemetryStatuses;
  final bool observedNonzeroBytes;
  final int? peakBytes;
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
  final Set<PlaybackCacheLogicalOption> optionalTuningUnavailable;
  final PlaybackCacheMode settingsMode;
  final PlaybackCacheTelemetryStatusEver telemetryStatusEver;
  final bool cacheCreateFailedObserved;
  final bool cacheSnapshotUnavailableObserved;
  final PlaybackCacheReopenReason safetyReopenReason;
  final PlaybackCacheRuntimeRecovery runtimeRecovery;
  final int cleanupAttemptCount;
  final bool testOverrideUsed;
  final int seekRequested;
  final int seekExecuted;
  final int seekSuperseded;
  final int seekFailed;
  final int seekCancelled;
  final PlaybackCacheReadAheadStrategy? readAheadStrategy;
  final PlaybackCacheBudgetPolicy? budgetPolicy;
  final PlaybackCacheSizeConfidence? sizeConfidence;
  final bool? fullReadAheadEligible;
  final bool? fullReadAheadReachedEnd;
}

class PlaybackCacheEvidenceAccumulator {
  PlaybackCacheEvidenceAccumulator({
    required this.sessionId,
    DateTime Function()? clock,
    this.observationThrottle = const Duration(seconds: 5),
    this.settingsMode = PlaybackCacheMode.automatic,
    this.onObservationApplied,
  }) : _clock = clock ?? DateTime.now;

  final PlaybackItemSessionId sessionId;
  final Duration observationThrottle;
  final PlaybackCacheMode settingsMode;
  final void Function(PlaybackCacheEvidenceObservation observation)?
  onObservationApplied;
  final DateTime Function() _clock;

  DateTime? _lastObservationAt;
  PlaybackCacheEvidenceObservation? _pending;
  Timer? _pendingTimer;
  PlaybackCacheEvidenceSummary? _summary;
  bool _summaryWriteClaimed = false;
  PlaybackCacheEvidence _evidence = PlaybackCacheEvidence.unconfirmed;
  final Set<PlaybackCacheTelemetryStatus> _telemetryStatuses = {};
  final Set<PlaybackCacheCreateResult> _createResults = {};
  final Set<PlaybackCacheReopenReason> _reopenReasons = {};
  final Set<PlaybackCacheLogicalOption> _optionalTuningUnavailable = {};
  bool _observedNonzeroBytes = false;
  int? _peakBytes;
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
  PlaybackCacheReadAheadStrategy? _readAheadStrategy;
  PlaybackCacheBudgetPolicy? _budgetPolicy;
  PlaybackCacheSizeConfidence? _sizeConfidence;
  bool? _fullReadAheadEligible;
  bool? _fullReadAheadReachedEnd;
  bool _optionalTuningDegraded = false;
  int _optionalTuningUnavailableCount = 0;
  int _cleanupAttemptCount = 0;
  PlaybackCacheRuntimeRecovery _runtimeRecovery =
      PlaybackCacheRuntimeRecovery.notAttempted;
  bool _testOverrideUsed = false;
  int _seekRequested = 0;
  int _seekExecuted = 0;
  int _seekSuperseded = 0;
  int _seekFailed = 0;
  int _seekCancelled = 0;

  bool get hasPendingObservation => _pending != null;
  bool get isFinalized => _summary != null;
  bool get summaryWritten => _summaryWriteClaimed;
  PlaybackCacheEvidenceObservation? get lastAppliedObservation => _lastApplied;

  PlaybackCacheEvidenceObservation? _lastApplied;
  String? _lastFingerprint;

  void recordProfileResolved(PlaybackCacheRuntimeMode mode) {
    _checkOpen();
    if (mode == PlaybackCacheRuntimeMode.unconfirmed) return;
    _requestedMode ??= _requestedModeValue(mode);
  }

  void recordRuntimeRecovery(PlaybackCacheRuntimeRecovery value) {
    _checkOpen();
    if (_runtimeRecoveryPriority(value) >
        _runtimeRecoveryPriority(_runtimeRecovery)) {
      _runtimeRecovery = value;
    }
  }

  bool observe(PlaybackCacheEvidenceObservation observation) {
    _checkOpen();
    final now = _clock();
    final fingerprint = _fingerprint(observation);
    if (fingerprint == _lastFingerprint) return false;
    final critical = _isCriticalChange(observation);
    if (critical ||
        _lastObservationAt == null ||
        now.difference(_lastObservationAt!) >= observationThrottle) {
      _pending = null;
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _applyObservation(observation, fingerprint: fingerprint);
      _lastObservationAt = now;
      return true;
    }
    _pending = observation;
    _schedulePendingFlush(now);
    return false;
  }

  bool flush() {
    _checkOpen();
    final observation = _pending;
    if (observation == null) return false;
    _pending = null;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final fingerprint = _fingerprint(observation);
    if (fingerprint == _lastFingerprint) return false;
    _applyObservation(observation, fingerprint: fingerprint);
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
    if (result != PlaybackCacheCleanupResult.notApplicable) {
      _cleanupAttemptCount++;
    }
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

  PlaybackCacheEvidenceSummary finalize({
    PlaybackSeekStatisticsSnapshot? seekStatistics,
  }) {
    final existing = _summary;
    if (existing != null) return existing;
    if (_pending != null) flush();
    _pendingTimer?.cancel();
    _pendingTimer = null;
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
      optionalTuningUnavailable: Set.unmodifiable({
        ..._optionalTuningUnavailable,
      }),
      settingsMode: settingsMode,
      telemetryStatusEver: _telemetryStatusEver,
      cacheCreateFailedObserved: _createResults.contains(
        PlaybackCacheCreateResult.failed,
      ),
      cacheSnapshotUnavailableObserved: _snapshotUnavailableCount > 0,
      safetyReopenReason: _safeReopenReason,
      runtimeRecovery: _runtimeRecovery,
      cleanupAttemptCount: _cleanupAttemptCount,
      testOverrideUsed: _testOverrideUsed,
      seekRequested: seekStatistics?.requested ?? _seekRequested,
      seekExecuted: seekStatistics?.executed ?? _seekExecuted,
      seekSuperseded: seekStatistics?.superseded ?? _seekSuperseded,
      seekFailed: seekStatistics?.failed ?? _seekFailed,
      seekCancelled: seekStatistics?.cancelled ?? _seekCancelled,
      readAheadStrategy: _readAheadStrategy,
      budgetPolicy: _budgetPolicy,
      sizeConfidence: _sizeConfidence,
      fullReadAheadEligible: _fullReadAheadEligible,
      fullReadAheadReachedEnd: _fullReadAheadReachedEnd,
    );
  }

  PlaybackCacheEvidenceSummary? claimSummaryForWrite({
    PlaybackSeekStatisticsSnapshot? seekStatistics,
  }) {
    if (_summaryWriteClaimed) return null;
    _summaryWriteClaimed = true;
    return finalize(seekStatistics: seekStatistics);
  }

  void _applyObservation(
    PlaybackCacheEvidenceObservation observation, {
    required String fingerprint,
  }) {
    _lastApplied = observation;
    _lastFingerprint = fingerprint;
    _observationCount++;
    onObservationApplied?.call(observation);
    if (_evidencePriority(observation.cacheEvidence) >
        _evidencePriority(_evidence)) {
      _evidence = observation.cacheEvidence;
    }
    final telemetry = observation.telemetryStatus;
    if (telemetry != null) _telemetryStatuses.add(telemetry);
    final bytes = observation.fileCacheBytes;
    if (bytes != null && bytes >= 0) {
      _observedNonzeroBytes = _observedNonzeroBytes || bytes > 0;
      if (_peakBytes == null || bytes > _peakBytes!) _peakBytes = bytes;
    }
    _maxForward = _maxDuration(_maxForward, observation.actualForward);
    _maxBackward = _maxDuration(_maxBackward, observation.actualBackward);
    if (observation.cacheCreateResult != null) {
      _createResults.add(observation.cacheCreateResult!);
    }
    if (observation.cacheSnapshotResult ==
        PlaybackCacheSnapshotResult.unavailable) {
      if (!observation.snapshotUnavailableAlreadyRecorded) {
        _snapshotUnavailableCount++;
      }
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
    if (observation.requestedMode != null &&
        observation.requestedMode != PlaybackCacheRuntimeMode.unconfirmed) {
      _requestedMode ??= _requestedModeValue(observation.requestedMode!);
    }
    if (observation.confirmedMode != null &&
        observation.confirmedMode != PlaybackCacheRuntimeMode.unconfirmed) {
      _finalConfirmedMode = observation.confirmedMode;
    }
    if (observation.fallbackReason != null) {
      _fallbackReason = observation.fallbackReason;
    }
    if (observation.readAheadStrategy != null) {
      _readAheadStrategy = observation.readAheadStrategy;
    }
    if (observation.budgetPolicy != null) {
      _budgetPolicy = observation.budgetPolicy;
    }
    if (observation.sizeConfidence != null) {
      _sizeConfidence = observation.sizeConfidence;
    }
    if (observation.fullReadAheadEligible != null) {
      _fullReadAheadEligible = observation.fullReadAheadEligible;
    }
    if (observation.fullReadAheadReachedEnd == true) {
      _fullReadAheadReachedEnd = true;
    } else if (_fullReadAheadReachedEnd == null &&
        observation.fullReadAheadReachedEnd != null) {
      _fullReadAheadReachedEnd = false;
    }
    _optionalTuningDegraded =
        _optionalTuningDegraded || observation.optionalTuningDegraded;
    _optionalTuningUnavailableCount +=
        observation.optionalTuningUnavailableCount;
    _optionalTuningUnavailable.addAll(observation.optionalTuningUnavailable);
    _testOverrideUsed = _testOverrideUsed || observation.testOverrideActive;
  }

  void _schedulePendingFlush(DateTime now) {
    final last = _lastObservationAt;
    if (last == null || _pendingTimer != null) return;
    final elapsed = now.difference(last);
    final remaining = observationThrottle - elapsed;
    _pendingTimer = Timer(
      remaining.isNegative || remaining == Duration.zero
          ? const Duration(milliseconds: 1)
          : remaining,
      () {
        _pendingTimer = null;
        if (_summary != null || _pending == null) return;
        flush();
      },
    );
  }

  bool _isCriticalChange(PlaybackCacheEvidenceObservation observation) {
    final previous = _lastApplied;
    if (previous == null) return true;
    if (previous.confirmedMode != observation.confirmedMode ||
        previous.telemetryStatus != observation.telemetryStatus ||
        previous.cacheOnDisk != observation.cacheOnDisk ||
        previous.cacheEvidence != observation.cacheEvidence ||
        previous.fallbackReason != observation.fallbackReason ||
        previous.readAheadStrategy != observation.readAheadStrategy ||
        previous.budgetPolicy != observation.budgetPolicy ||
        previous.sizeConfidence != observation.sizeConfidence ||
        previous.fullReadAheadEligible != observation.fullReadAheadEligible ||
        (observation.fullReadAheadReachedEnd == true &&
            previous.fullReadAheadReachedEnd != true)) {
      return true;
    }
    final previousBytes = previous.fileCacheBytes ?? 0;
    final currentBytes = observation.fileCacheBytes ?? 0;
    return previousBytes <= 0 && currentBytes > 0;
  }

  String _fingerprint(PlaybackCacheEvidenceObservation observation) => [
    '1',
    settingsMode.name,
    playbackCacheRequestedModeName(observation.requestedMode),
    playbackCacheConfirmedModeName(observation.confirmedMode),
    observation.cacheEvidence.name,
    observation.telemetryStatus?.name ?? 'fieldTemporarilyAbsent',
    observation.cacheCreateResult?.name ?? 'none',
    observation.cacheSnapshotResult?.name ?? 'none',
    observation.reopenReason?.name ?? 'none',
    observation.cleanupResult?.name ?? 'none',
    observation.cacheEnabled?.toString() ?? 'unknown',
    observation.cacheOnDisk?.toString() ?? 'unknown',
    _bytesBucket(observation.fileCacheBytes),
    _durationBucket(observation.actualForward),
    _durationBucket(observation.actualBackward),
    observation.fallbackReason?.name ?? 'none',
    observation.readAheadStrategy?.name ?? 'unavailable',
    observation.budgetPolicy?.name ?? 'unavailable',
    observation.sizeConfidence?.name ?? 'unavailable',
    observation.fullReadAheadEligible?.toString() ?? 'unavailable',
    observation.fullReadAheadReachedEnd?.toString() ?? 'unavailable',
    observation.optionalTuningDegraded.toString(),
    observation.optionalTuningUnavailableCount.toString(),
    _optionalTuningName(observation.optionalTuningUnavailable),
    observation.snapshotUnavailableAlreadyRecorded.toString(),
    observation.testOverrideActive.toString(),
  ].join('|');

  PlaybackCacheTelemetryStatusEver get _telemetryStatusEver {
    if (_telemetryStatuses.contains(PlaybackCacheTelemetryStatus.available)) {
      return PlaybackCacheTelemetryStatusEver.available;
    }
    if (_telemetryStatuses.contains(PlaybackCacheTelemetryStatus.readFailed)) {
      return PlaybackCacheTelemetryStatusEver.readFailed;
    }
    if (_telemetryStatuses.contains(
      PlaybackCacheTelemetryStatus.fieldTemporarilyAbsent,
    )) {
      return PlaybackCacheTelemetryStatusEver.temporarilyAbsentOnly;
    }
    if (_telemetryStatuses.contains(PlaybackCacheTelemetryStatus.unsupported)) {
      return PlaybackCacheTelemetryStatusEver.unsupported;
    }
    return PlaybackCacheTelemetryStatusEver.neverAttempted;
  }

  PlaybackCacheReopenReason get _safeReopenReason {
    if (_reopenReasons.isEmpty) return PlaybackCacheReopenReason.none;
    if (_reopenReasons.length > 1) return PlaybackCacheReopenReason.multiple;
    return _reopenReasons.single;
  }

  void _checkOpen() {
    if (_summary != null) {
      throw StateError('Playback cache evidence is finalized');
    }
  }

  static Duration? _maxDuration(Duration? a, Duration? b) =>
      b == null || (a != null && a >= b) ? a : b;

  static PlaybackCacheRuntimeMode _requestedModeValue(
    PlaybackCacheRuntimeMode mode,
  ) => mode == PlaybackCacheRuntimeMode.memoryFallback
      ? PlaybackCacheRuntimeMode.memory
      : mode;

  static int _evidencePriority(PlaybackCacheEvidence value) => switch (value) {
    PlaybackCacheEvidence.unconfirmed => 0,
    PlaybackCacheEvidence.disabled => 1,
    PlaybackCacheEvidence.diskConfiguredOnly => 3,
    PlaybackCacheEvidence.memoryProfileConfirmed => 4,
    PlaybackCacheEvidence.diskDataObserved => 5,
  };

  static int _cleanupPriority(PlaybackCacheCleanupResult value) =>
      switch (value) {
        PlaybackCacheCleanupResult.notApplicable => 0,
        PlaybackCacheCleanupResult.succeeded => 1,
        PlaybackCacheCleanupResult.failed => 2,
        PlaybackCacheCleanupResult.timedOut => 3,
      };

  static int _runtimeRecoveryPriority(PlaybackCacheRuntimeRecovery value) =>
      switch (value) {
        PlaybackCacheRuntimeRecovery.notAttempted => 0,
        PlaybackCacheRuntimeRecovery.cancelled => 1,
        PlaybackCacheRuntimeRecovery.succeeded => 2,
        PlaybackCacheRuntimeRecovery.failed => 3,
      };

  static String _bytesBucket(int? value) => switch (value) {
    null => 'unavailable',
    <= 0 => 'zero',
    <= 16 * 1024 * 1024 => 'lte16MiB',
    <= 64 * 1024 * 1024 => 'lte64MiB',
    <= 256 * 1024 * 1024 => 'lte256MiB',
    <= 512 * 1024 * 1024 => 'lte512MiB',
    <= 1024 * 1024 * 1024 => 'lte1GiB',
    _ => 'gt1GiB',
  };

  static String _durationBucket(Duration? value) => switch (value) {
    null => 'unavailable',
    Duration(inMicroseconds: <= 0) => 'zero',
    Duration(inSeconds: <= 30) => 'lte30s',
    Duration(inSeconds: <= 60) => 'lte60s',
    Duration(inSeconds: <= 120) => 'lte120s',
    Duration(inSeconds: <= 180) => 'lte180s',
    Duration(inSeconds: <= 300) => 'lte300s',
    _ => 'gt300s',
  };

  static String _optionalTuningName(Set<PlaybackCacheLogicalOption> values) {
    final names = <String>{};
    var hasUnrepresentableOption = false;
    for (final value in values) {
      switch (value) {
        case PlaybackCacheLogicalOption.streamBufferSize:
          names.add('streamBufferSize');
        case PlaybackCacheLogicalOption.cachePause:
          names.add('cachePause');
        case PlaybackCacheLogicalOption.cachePauseWait:
          names.add('cachePauseWait');
        case PlaybackCacheLogicalOption.donateBuffer:
        case PlaybackCacheLogicalOption.seekableCache:
          hasUnrepresentableOption = true;
        case PlaybackCacheLogicalOption.cache:
        case PlaybackCacheLogicalOption.cacheOnDisk:
        case PlaybackCacheLogicalOption.cacheDirectory:
        case PlaybackCacheLogicalOption.cacheUnlinkFiles:
        case PlaybackCacheLogicalOption.cacheSeconds:
        case PlaybackCacheLogicalOption.forwardMetadataBytes:
        case PlaybackCacheLogicalOption.backwardMetadataBytes:
          break;
      }
    }
    if (hasUnrepresentableOption) return 'multiple';
    if (names.isEmpty) return 'none';
    if (names.length > 1) return 'multiple';
    return names.single;
  }
}

enum PlaybackCacheTelemetryStatusEver {
  available,
  temporarilyAbsentOnly,
  unsupported,
  readFailed,
  neverAttempted,
}
