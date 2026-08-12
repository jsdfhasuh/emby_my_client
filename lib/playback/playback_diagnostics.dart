import 'dart:async';

import '../core/diagnostic_log.dart';
import 'cache/native_playback_property_access.dart';
import 'cache/playback_cache_capabilities.dart';
import 'cache/playback_cache_coordinator.dart';
import 'cache/playback_cache_evidence.dart';
import 'cache/playback_cache_engine.dart';
import 'cache/playback_cache_policy.dart';
import 'cache/playback_cache_settings.dart';
import 'cache/playback_cache_storage.dart';
import 'cache/playback_cache_telemetry.dart';
import 'playback_operation_coordinator.dart';

enum PlaybackDiagnosticLevel { info, warning }

enum PlaybackDiagnosticEvent {
  cacheCapabilitiesResolved('playback_cache_capabilities_resolved'),
  cacheProfileSwitchStrategyResolved(
    'playback_cache_profile_switch_strategy_resolved',
  ),
  cacheSettingsLoaded('playback_cache_settings_loaded'),
  cacheProfileResolved('playback_cache_profile_resolved'),
  cacheDirectoryReady('playback_cache_directory_ready'),
  cacheDirectoryFailed('playback_cache_directory_failed'),
  cacheDiskEnabled('playback_cache_disk_enabled'),
  cacheMemoryFallback('playback_cache_memory_fallback'),
  cacheActualModeUnconfirmed('playback_cache_actual_mode_unconfirmed'),
  cacheMpvCreateFailed('playback_cache_mpv_create_failed'),
  cacheBudgetGuardReached('playback_cache_budget_guard_reached'),
  cacheLowSpace('playback_cache_low_space'),
  cacheMemoryPressure('playback_cache_memory_pressure'),
  cacheSessionCleaned('playback_cache_session_cleaned'),
  cacheStaleCleanup('playback_cache_stale_cleanup'),
  cacheSnapshotUnavailable('playback_cache_snapshot_unavailable'),
  cacheObservation('playback_cache_observation'),
  cacheSessionSummary('playback_cache_session_summary'),
  operationTimeout('playback_operation_timeout'),
  automaticOpenBudgetExhausted('playback_automatic_open_budget_exhausted'),
  seekRequested('playback_seek_requested'),
  seekCoalesced('playback_seek_coalesced'),
  seekExecuted('playback_seek_executed'),
  seekFailed('playback_seek_failed'),
  seekCancelled('playback_seek_cancelled'),
  seekRecoveryPending('playback_seek_recovery_pending'),
  seekRecoveryStarted('playback_seek_recovery_started'),
  seekRecoverySucceeded('playback_seek_recovery_succeeded'),
  seekRecoveryFailed('playback_seek_recovery_failed');

  const PlaybackDiagnosticEvent(this.code);

  final String code;
}

enum PlaybackOperationTimeoutKind {
  nativePropertyRead('native_property_read'),
  nativePropertyWrite('native_property_write'),
  engineOpen('engine_open'),
  seekCall('seek_call'),
  seekSettle('seek_settle'),
  engineStop('engine_stop'),
  engineDispose('engine_dispose'),
  reporterStop('reporter_stop'),
  cacheSnapshotRead('cache_snapshot_read'),
  cacheMonitorStart('cache_monitor_start'),
  cacheCleanup('cache_cleanup');

  const PlaybackOperationTimeoutKind(this.code);

  final String code;
}

enum PlaybackRecoveryFingerprint {
  seekFailed('seek_failed'),
  partialFile('partial_file'),
  inputOutputError('input_output_error'),
  packetReadError('packet_read_error');

  const PlaybackRecoveryFingerprint(this.code);

  final String code;
}

enum PlaybackRecoveryDiagnosticEvent { pending, started, succeeded, failed }

typedef PlaybackDiagnosticWriter =
    void Function(
      PlaybackDiagnosticLevel level,
      String component,
      String message,
    );
typedef PlaybackDiagnosticClock = DateTime Function();

class PlaybackDiagnostics {
  PlaybackDiagnostics({
    PlaybackDiagnosticWriter? writer,
    this.seekFlushInterval = const Duration(milliseconds: 250),
    this.timeoutRateLimit = const Duration(seconds: 2),
    PlaybackDiagnosticClock? clock,
  }) : _writer = writer ?? _writeToDiagnosticLog,
       _clock = clock ?? DateTime.now;

  final PlaybackDiagnosticWriter _writer;
  final Duration seekFlushInterval;
  final Duration timeoutRateLimit;
  final PlaybackDiagnosticClock _clock;

  Timer? _seekFlushTimer;
  int _seekRequested = 0;
  int _seekCoalesced = 0;
  int _seekExecuted = 0;
  int _seekFailed = 0;
  int _seekCancelled = 0;
  final Map<PlaybackOperationTimeoutKind, DateTime> _timeoutLastWritten = {};

  void cacheCapabilitiesResolved(PlaybackCacheEngineCapabilities capabilities) {
    _emit(PlaybackDiagnosticEvent.cacheCapabilitiesResolved, [
      'mpvVersionFingerprint=${_safeToken(capabilities.mpvVersionFingerprint)}',
      'platform=${_platform(capabilities.platform)}',
      for (final option in playbackCacheOptionNames)
        'option_${_safeCapabilityKey(option)}='
            '${capabilities.optionSupport[option] == true}',
      for (final property in playbackCachePropertyNames)
        'property_${_safeCapabilityKey(property)}='
            '${capabilities.propertySupport[property] == true}',
      'diskCache=${capabilities.supportsDiskCache}',
      'cacheDirectory=${capabilities.supportsCacheDirectory}',
      'immediateUnlink=${capabilities.supportsImmediateUnlink}',
      'nativeCacheState=${capabilities.supportsNativeCacheState}',
      'seekableRanges=${capabilities.supportsSeekableRanges}',
      'fileCacheBytes=${capabilities.supportsFileCacheBytes}',
      'rawInputRate=${capabilities.supportsRawInputRate}',
      'streamBufferSize=${capabilities.supportsStreamBufferSize}',
      'diskGatePassed=${capabilities.diskGatePassed}',
    ]);
    _emit(PlaybackDiagnosticEvent.cacheProfileSwitchStrategyResolved, [
      'strategy=${capabilities.profileSwitchStrategy.name}',
    ]);
  }

  void cacheSettingsLoaded(PlaybackCacheMode mode) {
    _emit(PlaybackDiagnosticEvent.cacheSettingsLoaded, ['mode=${mode.name}']);
  }

  void cacheDirectoryResult(PlaybackCacheStorageSnapshot snapshot) {
    if (snapshot.isAvailable) {
      _emit(PlaybackDiagnosticEvent.cacheDirectoryReady, const [
        'cacheDirectoryReady=true',
      ]);
      return;
    }
    _emit(
      PlaybackDiagnosticEvent.cacheDirectoryFailed,
      ['cacheDirectoryReady=false', 'reason=${snapshot.failureReason.name}'],
      level: PlaybackDiagnosticLevel.warning,
    );
  }

  void cacheProfileResolved(ResolvedPlaybackCacheProfile profile) {
    _emit(PlaybackDiagnosticEvent.cacheProfileResolved, [
      'mode=${profile.runtimeMode.name}',
      'forwardTarget=${_durationBucket(profile.forwardTarget)}',
      'backTarget=${_durationBucket(profile.backwardTarget)}',
      'sessionTarget=${_bytesBucket(profile.sessionTargetBytes)}',
      'fallbackReason=${profile.fallbackReason.name}',
    ]);
  }

  void cacheApplyResult(PlaybackCacheApplyResult result) {
    switch (result.actualMode) {
      case PlaybackCacheRuntimeMode.disk:
        _emit(PlaybackDiagnosticEvent.cacheDiskEnabled, [
          'mode=${result.actualMode.name}',
        ]);
      case PlaybackCacheRuntimeMode.memoryFallback:
        _emit(
          PlaybackDiagnosticEvent.cacheMemoryFallback,
          [
            'mode=${result.actualMode.name}',
            'fallbackReason=${result.fallbackReason.name}',
          ],
          level: PlaybackDiagnosticLevel.warning,
        );
      case PlaybackCacheRuntimeMode.unconfirmed:
        _emit(
          PlaybackDiagnosticEvent.cacheActualModeUnconfirmed,
          [
            'mode=${result.actualMode.name}',
            'fallbackReason=${result.fallbackReason.name}',
          ],
          level: PlaybackDiagnosticLevel.warning,
        );
      case PlaybackCacheRuntimeMode.disabled:
      case PlaybackCacheRuntimeMode.memory:
        break;
    }
  }

  void cacheMpvCreateFailed() {
    _emit(
      PlaybackDiagnosticEvent.cacheMpvCreateFailed,
      const ['observed=true'],
      level: PlaybackDiagnosticLevel.warning,
    );
  }

  void cacheSafetyTriggered(PlaybackCacheSafetyReason reason) {
    final event = switch (reason) {
      PlaybackCacheSafetyReason.budget =>
        PlaybackDiagnosticEvent.cacheBudgetGuardReached,
      PlaybackCacheSafetyReason.lowSpace =>
        PlaybackDiagnosticEvent.cacheLowSpace,
      PlaybackCacheSafetyReason.memoryPressure =>
        PlaybackDiagnosticEvent.cacheMemoryPressure,
    };
    _emit(event, [
      'reason=${reason.name}',
    ], level: PlaybackDiagnosticLevel.warning);
  }

  void cacheSessionCleaned() {
    _emit(PlaybackDiagnosticEvent.cacheSessionCleaned, const [
      'cacheDirectoryReady=false',
    ]);
  }

  void cacheStaleCleanup() {
    _emit(PlaybackDiagnosticEvent.cacheStaleCleanup, const ['completed=true']);
  }

  void cacheSnapshotUnavailable() {
    _emit(
      PlaybackDiagnosticEvent.cacheSnapshotUnavailable,
      const ['snapshotAvailable=false'],
      level: PlaybackDiagnosticLevel.warning,
    );
  }

  void cacheObservation(PlaybackCacheEvidenceObservation observation) {
    _emit(
      PlaybackDiagnosticEvent.cacheObservation,
      _cacheObservationFields(observation),
    );
  }

  void cacheSessionSummary(PlaybackCacheEvidenceSummary summary) {
    _emit(PlaybackDiagnosticEvent.cacheSessionSummary, [
      'requestedMode=${summary.requestedMode?.name ?? 'unknown'}',
      'finalConfirmedMode=${summary.finalConfirmedMode?.name ?? 'unknown'}',
      'cacheEvidence=${summary.cacheEvidence.name}',
      'telemetryStatus=${_telemetryStatusSet(summary.telemetryStatuses)}',
      'telemetryAvailableEver=${summary.telemetryStatuses.contains(PlaybackCacheTelemetryStatus.available)}',
      'observedNonZeroFileCache=${summary.observedNonzeroBytes}',
      'peakFileCacheBytes=${_bytesBucket(summary.peakBytes)}',
      'maxActualForward=${_durationBucket(summary.maxActualForward ?? Duration.zero)}',
      'maxActualBackward=${_durationBucket(summary.maxActualBackward ?? Duration.zero)}',
      'cacheCreateResult=${_enumSet(summary.cacheCreateResults)}',
      'cacheSnapshotUnavailable=${_countBucket(summary.snapshotUnavailableCount)}',
      'safetyReopenReason=${_reopenReasonSet(summary.reopenReasons)}',
      'cleanupResult=${summary.cleanupResult?.name ?? 'notApplicable'}',
      'observationCount=${_countBucket(summary.observationCount)}',
      'optionalTuningDegraded=${summary.optionalTuningDegraded}',
      'optionalTuningUnavailable=${_countBucket(summary.optionalTuningUnavailableCount)}',
      'testOverrideUsed=${summary.testOverrideUsed}',
      'seekRequested=${_countBucket(summary.seekRequested)}',
      'seekExecuted=${_countBucket(summary.seekExecuted)}',
      'seekSuperseded=${_countBucket(summary.seekSuperseded)}',
      'seekFailed=${_countBucket(summary.seekFailed)}',
      'seekCancelled=${_countBucket(summary.seekCancelled)}',
    ]);
  }

  void operationTimeout(PlaybackOperationTimeoutKind kind) {
    final now = _clock();
    final lastWritten = _timeoutLastWritten[kind];
    if (lastWritten != null && now.difference(lastWritten) < timeoutRateLimit) {
      return;
    }
    _timeoutLastWritten[kind] = now;
    _emit(
      PlaybackDiagnosticEvent.operationTimeout,
      ['kind=${kind.code}'],
      level: PlaybackDiagnosticLevel.warning,
    );
  }

  void nativeOperationTimeout(NativePlaybackOperationKind operation) {
    operationTimeout(switch (operation) {
      NativePlaybackOperationKind.propertyRead =>
        PlaybackOperationTimeoutKind.nativePropertyRead,
      NativePlaybackOperationKind.propertyWrite =>
        PlaybackOperationTimeoutKind.nativePropertyWrite,
    });
  }

  void automaticOpenBudgetExhausted({
    required AutomaticPlaybackOpenReason reason,
    required int automaticOpenCount,
  }) {
    _emit(
      PlaybackDiagnosticEvent.automaticOpenBudgetExhausted,
      [
        'reason=${reason.name}',
        'automaticOpenCount=${_openCountBucket(automaticOpenCount)}',
      ],
      level: PlaybackDiagnosticLevel.warning,
    );
  }

  void seekRequested() {
    _seekRequested++;
    _scheduleSeekFlush();
  }

  void seekCompleted(SeekResult result) {
    switch (result.disposition) {
      case SeekDisposition.executed:
        _seekExecuted++;
      case SeekDisposition.superseded:
        _seekCoalesced++;
      case SeekDisposition.cancelled:
        _seekCancelled++;
      case SeekDisposition.failed:
        _seekFailed++;
        switch (result.failureKind) {
          case SeekFailureKind.callTimeout:
            operationTimeout(PlaybackOperationTimeoutKind.seekCall);
          case SeekFailureKind.settleTimeout:
            operationTimeout(PlaybackOperationTimeoutKind.seekSettle);
          case SeekFailureKind.engineError:
          case SeekFailureKind.higherPriorityOperation:
          case SeekFailureKind.staleSession:
          case null:
            break;
        }
    }
    _scheduleSeekFlush();
  }

  void seekRecovery(
    PlaybackRecoveryDiagnosticEvent recoveryEvent, {
    PlaybackRecoveryFingerprint? fingerprint,
  }) {
    final event = switch (recoveryEvent) {
      PlaybackRecoveryDiagnosticEvent.pending =>
        PlaybackDiagnosticEvent.seekRecoveryPending,
      PlaybackRecoveryDiagnosticEvent.started =>
        PlaybackDiagnosticEvent.seekRecoveryStarted,
      PlaybackRecoveryDiagnosticEvent.succeeded =>
        PlaybackDiagnosticEvent.seekRecoverySucceeded,
      PlaybackRecoveryDiagnosticEvent.failed =>
        PlaybackDiagnosticEvent.seekRecoveryFailed,
    };
    _emit(
      event,
      [if (fingerprint != null) 'fingerprint=${fingerprint.code}'],
      level: recoveryEvent == PlaybackRecoveryDiagnosticEvent.succeeded
          ? PlaybackDiagnosticLevel.info
          : PlaybackDiagnosticLevel.warning,
    );
  }

  void flushSeekSummary() {
    _seekFlushTimer?.cancel();
    _seekFlushTimer = null;
    _emitSeekCount(PlaybackDiagnosticEvent.seekRequested, _seekRequested);
    _emitSeekCount(PlaybackDiagnosticEvent.seekCoalesced, _seekCoalesced);
    _emitSeekCount(PlaybackDiagnosticEvent.seekExecuted, _seekExecuted);
    _emitSeekCount(PlaybackDiagnosticEvent.seekFailed, _seekFailed);
    _emitSeekCount(PlaybackDiagnosticEvent.seekCancelled, _seekCancelled);
    _seekRequested = 0;
    _seekCoalesced = 0;
    _seekExecuted = 0;
    _seekFailed = 0;
    _seekCancelled = 0;
  }

  void _scheduleSeekFlush() {
    _seekFlushTimer ??= Timer(seekFlushInterval, flushSeekSummary);
  }

  void _emitSeekCount(PlaybackDiagnosticEvent event, int count) {
    if (count == 0) return;
    _emit(event, ['count=${count.clamp(1, 9999)}']);
  }

  void _emit(
    PlaybackDiagnosticEvent event,
    List<String> fields, {
    PlaybackDiagnosticLevel level = PlaybackDiagnosticLevel.info,
  }) {
    final suffix = fields.isEmpty ? '' : ' ${fields.join(' ')}';
    _writer(level, 'playback', 'event=${event.code}$suffix');
  }

  static void _writeToDiagnosticLog(
    PlaybackDiagnosticLevel level,
    String component,
    String message,
  ) {
    switch (level) {
      case PlaybackDiagnosticLevel.info:
        DiagnosticLog.instance.info(component, message);
      case PlaybackDiagnosticLevel.warning:
        DiagnosticLog.instance.warning(component, message);
    }
  }

  static String _safeToken(String value) {
    if (value.length > 63) return 'unavailable';
    return RegExp(
          r'^(?:mpv-[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?|unavailable)$',
          caseSensitive: false,
        ).hasMatch(value)
        ? value
        : 'unavailable';
  }

  static String _platform(String value) => switch (value.toLowerCase()) {
    'ipados' || 'ios' || 'darwin' => 'iPadOS',
    'android' => 'Android',
    _ => 'unsupported',
  };

  static String _safeCapabilityKey(String value) => value.replaceAll('-', '_');

  static String _durationBucket(Duration value) => switch (value.inSeconds) {
    <= 0 => 'none',
    <= 30 => 'lte30s',
    <= 60 => 'lte60s',
    <= 180 => 'lte180s',
    <= 300 => 'lte300s',
    _ => 'gt300s',
  };

  static String _bytesBucket(int value) => switch (value) {
    <= 0 => 'none',
    <= 64 * 1024 * 1024 => 'lte64MiB',
    <= 256 * 1024 * 1024 => 'lte256MiB',
    <= 512 * 1024 * 1024 => 'lte512MiB',
    <= 1024 * 1024 * 1024 => 'lte1GiB',
    _ => 'gt1GiB',
  };

  static String _openCountBucket(int count) => switch (count) {
    <= 0 => '0',
    <= 2 => '1_2',
    <= 4 => '3_4',
    <= PlaybackItemSession.maximumAutomaticOpenCount => '5_6',
    _ => 'exhausted',
  };

  static List<String> _cacheObservationFields(
    PlaybackCacheEvidenceObservation observation,
  ) => [
    'requestedMode=${observation.requestedMode?.name ?? 'unknown'}',
    'confirmedMode=${observation.confirmedMode?.name ?? 'unknown'}',
    'cacheEvidence=${observation.cacheEvidence.name}',
    'telemetryStatus=${observation.telemetryStatus?.name ?? 'unknown'}',
    'fileCacheBytes=${_bytesBucket(observation.fileCacheBytes ?? 0)}',
    'actualForward=${_durationBucket(observation.actualForward ?? Duration.zero)}',
    'actualBackward=${_durationBucket(observation.actualBackward ?? Duration.zero)}',
    'fallbackReason=${observation.fallbackReason?.name ?? 'none'}',
    'optionalTuningDegraded=${observation.optionalTuningDegraded}',
    'optionalTuningUnavailable=${_countBucket(observation.optionalTuningUnavailableCount)}',
    'testOverrideActive=${observation.testOverrideActive}',
  ];

  static String _telemetryStatusSet(Set<PlaybackCacheTelemetryStatus> values) =>
      _enumSet(values);

  static String _reopenReasonSet(Set<PlaybackCacheReopenReason> values) {
    if (values.isEmpty) return 'none';
    if (values.length > 1) return 'multiple';
    return values.single.name;
  }

  static String _enumSet(Iterable<Enum> values) {
    final names = values.map((value) => value.name).toList()..sort();
    return names.isEmpty ? 'none' : names.join(',');
  }

  static String _countBucket(int value) => switch (value) {
    <= 0 => '0',
    <= 2 => '1_2',
    <= 10 => '3_10',
    <= 100 => '11_100',
    _ => 'gt100',
  };
}
