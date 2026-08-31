import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import 'cache/playback_cache_capabilities.dart';
import 'cache/playback_cache_coordinator.dart';
import 'cache/playback_cache_evidence.dart';
import 'cache/playback_cache_engine.dart';
import 'cache/playback_cache_policy.dart';
import 'cache/playback_cache_settings.dart';
import 'cache/playback_cache_storage.dart';
import 'cache/playback_cache_telemetry.dart';
import 'emby_stream_resolver.dart';
import 'playback_diagnostics.dart';
import 'playback_diagnostics_test_overrides.dart';
import 'playback_engine.dart';
import 'playback_operation_coordinator.dart';
import 'playback_recovery_policy.dart';
import 'playback_session_reporter.dart';
import 'playback_seek_statistics.dart';
import 'playback_state.dart';
import 'track_mapper.dart';

typedef PlaybackEngineRecreator =
    Future<PlaybackEngine> Function(PlaybackItemSession session);
typedef PlaybackClock = DateTime Function();
typedef PlaybackEngineDisposalUnconfirmed = void Function();

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.item,
    required PlaybackEngine engine,
    required this.resolver,
    required this.reporter,
    required this.playbackHeaders,
    this.engineRecreator,
    PlaybackItemSession? session,
    this.cacheSettings = const PlaybackCacheSettings(),
    this.testOverrides,
    PlaybackCacheStorage? cacheStorage,
    PlaybackDiagnostics? diagnostics,
    int maxStreamingBitrate = 120000000,
    this.readyTimeout = const Duration(seconds: 18),
    this.openTimeout = const Duration(seconds: 18),
    this.resumeVerificationTimeout = const Duration(seconds: 2),
    this.seekCallTimeout = const Duration(seconds: 8),
    this.playPauseTimeout = const Duration(seconds: 3),
    this.propertyWriteTimeout = const Duration(seconds: 2),
    this.lifecycleQuiesceTimeout = const Duration(seconds: 2),
    this.retirementQuiesceTimeout = const Duration(seconds: 3),
    this.shutdownBarrierTimeout = const Duration(seconds: 5),
    this.stopTimeout = const Duration(seconds: 5),
    this.disposeTimeout = const Duration(seconds: 5),
    this.reporterTimeout = const Duration(seconds: 3),
    this.cacheCleanupTimeout = const Duration(seconds: 3),
    this.progressInterval = const Duration(seconds: 10),
    this.trackWaitTimeout = const Duration(seconds: 2),
    this.lateSubtitleTrackWaitTimeout = const Duration(seconds: 8),
    this.cacheStatePollInterval = const Duration(seconds: 1),
    this.cacheSpacePollInterval = const Duration(seconds: 10),
    this.recoveryPolicy = const PlaybackRecoveryPolicy(),
    this.onEngineDisposalUnconfirmed,
    PlaybackClock? clock,
  }) : assert(trackWaitTimeout > Duration.zero),
       assert(lateSubtitleTrackWaitTimeout > Duration.zero),
       _engine = engine,
       session = session ?? PlaybackItemSession.create(),
       cacheStorage = cacheStorage ?? PlatformPlaybackCacheStorage(),
       _diagnostics = diagnostics ?? PlaybackDiagnostics(),
       _clock = clock ?? DateTime.now,
       _maxStreamingBitrate = maxStreamingBitrate {
    _testSeekFailurePending =
        testOverrides?.injectApprovedSeekFailureAfterNextExecutedSeek ?? false;
    _testCacheFailureObservationPending =
        testOverrides?.forceCacheCreateFailureObservation ?? false;
    _createOperationCoordinator();
  }

  final EmbyItem item;
  PlaybackEngine _engine;
  final PlaybackStreamResolver resolver;
  final PlaybackReporter reporter;
  final Map<String, String> playbackHeaders;
  final PlaybackEngineRecreator? engineRecreator;
  final PlaybackItemSession session;
  final PlaybackCacheSettings cacheSettings;
  final PlaybackDiagnosticsTestOverrides? testOverrides;
  final PlaybackCacheStorage cacheStorage;
  final PlaybackDiagnostics _diagnostics;
  final Duration readyTimeout;
  final Duration openTimeout;
  final Duration resumeVerificationTimeout;
  final Duration seekCallTimeout;
  final Duration playPauseTimeout;
  final Duration propertyWriteTimeout;
  final Duration lifecycleQuiesceTimeout;
  final Duration retirementQuiesceTimeout;
  final Duration shutdownBarrierTimeout;
  final Duration stopTimeout;
  final Duration disposeTimeout;
  final Duration reporterTimeout;
  final Duration cacheCleanupTimeout;
  final Duration progressInterval;
  final Duration trackWaitTimeout;
  final Duration lateSubtitleTrackWaitTimeout;
  final Duration cacheStatePollInterval;
  final Duration cacheSpacePollInterval;
  final PlaybackRecoveryPolicy recoveryPolicy;
  final PlaybackEngineDisposalUnconfirmed? onEngineDisposalUnconfirmed;
  final PlaybackClock _clock;
  final TrackMapper _trackMapper = const TrackMapper();

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late PlaybackOperationCoordinator _operationCoordinator;
  PlaybackState _state = const PlaybackState();
  Completer<void>? _readyCompleter;
  Timer? _progressTimer;
  Future<void>? _shutdownOperation;
  Future<void>? _retirementQuiescenceOperation;
  Future<void>? _lifecycleQuiescenceOperation;
  Future<void>? _lifecycleResumeOperation;
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex;
  SubtitleSelection _desiredSubtitleSelection =
      const SubtitleSelection.followServerDefault();
  PlaybackEngine? _appliedAudioEngine;
  PlaybackEngine? _appliedSubtitleEngine;
  PlaybackEngine? _subtitleApplicationEngine;
  Future<void>? _subtitleApplication;
  SubtitleSelection? _subtitleApplicationSelection;
  int? _subtitleApplicationGeneration;
  _LateSubtitleTask? _lateSubtitleTask;
  final Set<Completer<void>> _subtitleTrackWaitCancellations = {};
  int _maxStreamingBitrate;
  int _generation = 0;
  bool _sawBuffering = false;
  bool _startupFailureSignaled = false;
  bool _disposed = false;
  bool _shuttingDown = false;
  bool _engineDisposed = false;
  PlaybackRetirementState _retirementState = PlaybackRetirementState.active;
  bool _engineDisposalUnconfirmedReported = false;
  PlaybackCacheSession? _cacheSession;
  PlaybackCacheCoordinator? _cacheCoordinator;
  PlaybackCacheFallbackReason? _forcedCacheFallbackReason;
  bool _runtimeRecoveryScheduled = false;
  DateTime? _lastExecutedSeekAt;
  DateTime? _stablePlaybackSince;
  Duration? _lastStabilityPosition;
  bool _seekBecameStable = false;
  bool _lifecycleSuspended = false;
  int _lifecycleQuiescenceRevision = 0;
  PlaybackRecoveryFingerprint? _pendingRecoveryFingerprint;
  final Map<PlaybackRecoveryFingerprint, DateTime>
  _recoveryFingerprintLastSeen = {};
  double _desiredPlaybackRate = 1;
  bool _desiredPlaying = true;
  Duration _desiredAudioDelay = Duration.zero;
  Duration _desiredSubtitleDelay = Duration.zero;
  _SubtitleStyle? _desiredSubtitleStyle;
  final Map<String, DateTime> _engineLogLastWritten = {};
  bool _testSeekFailurePending = false;
  bool _testCacheFailureObservationPending = false;
  bool _cacheSnapshotUnavailableLogged = false;
  PlaybackSeekStatisticsSnapshot? _frozenSeekStatistics;
  final Set<Future<void>> _activeSeekBookkeeping = {};
  PlaybackCacheEvidence? _lastNativeCacheEvidence;
  PlaybackCacheRuntimeMode? _lastNativeConfirmedMode;
  int _cacheFailureObservationGeneration = 0;
  final Set<PlaybackCacheSafetyReason> _cacheSafetyDiagnosticsWritten = {};
  late final PlaybackCacheEvidenceAccumulator _cacheEvidence =
      PlaybackCacheEvidenceAccumulator(
        sessionId: session.id,
        clock: _clock,
        settingsMode: cacheSettings.mode,
        onObservationApplied: _onCacheObservationApplied,
      );

  PlaybackState get state => _state;
  PlaybackEngine get engine => _engine;
  int get maxStreamingBitrate => _maxStreamingBitrate;
  PlaybackItemSessionId get sessionId => session.id;
  PlaybackRetirementState get retirementState => _retirementState;

  bool get _retiring => _retirementState != PlaybackRetirementState.active;

  Future<void> start({
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    Duration? resumePosition,
    bool playAfterReady = true,
  }) {
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) {
      return Future<void>.value();
    }
    _selectedMediaSourceId = mediaSourceId;
    _selectedAudioStreamIndex = audioStreamIndex;
    _desiredSubtitleSelection = subtitleDisabled
        ? const SubtitleSelection.disabled()
        : subtitleStreamIndex == null
        ? const SubtitleSelection.followServerDefault()
        : SubtitleSelection.explicitStream(subtitleStreamIndex);
    if (!_tryReserveAutomaticOpen(AutomaticPlaybackOpenReason.initial)) {
      return Future.error(StateError('Initial playback open is unavailable'));
    }
    return _startPlayback(
      resumePosition: resumePosition,
      playAfterReady: playAfterReady,
    );
  }

  Future<void> _startPlayback({
    Duration? resumePosition,
    bool playAfterReady = true,
    bool forceTranscodeInitially = false,
    AutomaticPlaybackOpenReason transcodeFallbackReason =
        AutomaticPlaybackOpenReason.startupTranscodeFallback,
    String? openingStatusMessage,
  }) async {
    final token = _advanceGeneration();
    await _bindEngine(token);
    _throwIfStale(token);
    _desiredPlaying = playAfterReady;
    var currentOpeningStatusMessage = openingStatusMessage;
    _setState(
      PlaybackState(
        phase: PlaybackPhase.resolving,
        isBuffering: true,
        playbackRate: _desiredPlaybackRate,
        desiredSubtitleSelection: _desiredSubtitleSelection,
        subtitleSelectionStatus: SubtitleSelectionStatus.notApplied,
        appliedSubtitleKind: AppliedSubtitleKind.none,
        audioSelectionStatus: AudioSelectionStatus.notApplied,
        statusMessage: currentOpeningStatusMessage,
      ),
    );
    var forceTranscode = forceTranscodeInitially;
    var retriedWithTranscode = forceTranscodeInitially;
    var fellBackToTranscode = false;

    while (_isCurrent(token)) {
      _cacheFailureObservationGeneration++;
      PlaybackPlan? plan;
      var engineOpenTimedOut = false;
      try {
        plan = await resolver.resolve(
          item,
          mediaSourceId: _selectedMediaSourceId,
          audioStreamIndex: _selectedAudioStreamIndex,
          subtitleStreamIndex: _desiredSubtitleSelection.streamIndex,
          subtitleDisabled: _desiredSubtitleSelection.isDisabled,
          maxStreamingBitrate: _maxStreamingBitrate,
          forceTranscode: forceTranscode,
        );
        if (!_isCurrent(token)) {
          await reporter.cleanup(plan);
          return;
        }

        final resume = _resumePositionForPlan(plan, resumePosition);
        reporter.activate(plan);
        await _prepareCacheForPlan(plan, token, readAheadAnchor: resume);
        _throwIfStale(token);
        _setState(
          _state.copyWith(
            phase: PlaybackPhase.opening,
            plan: plan,
            desiredSubtitleSelection: _desiredSubtitleSelection,
            subtitleSelectionStatus: SubtitleSelectionStatus.applying,
            appliedSubtitleKind: AppliedSubtitleKind.none,
            clearAppliedSubtitleStreamIndex: true,
            clearSubtitleSelectionError: true,
            audioSelectionStatus: AudioSelectionStatus.applying,
            clearAppliedAudioStreamIndex: true,
            clearError: true,
            isBuffering: true,
            statusMessage: currentOpeningStatusMessage,
          ),
        );
        _prepareReadyWait();
        try {
          final boundEngine = engine;
          final openingPlan = plan;
          await _withDeadline(
            _operationCoordinator.runTrackedNativeOperation(
              kind: PlaybackNativeOperationKind.open,
              operation: () => boundEngine.open(
                openingPlan.uri,
                headers: openingPlan.usesServerAuthentication
                    ? playbackHeaders
                    : const <String, String>{},
                play: resume == Duration.zero && playAfterReady,
              ),
              barrierTimeout: openTimeout,
            ),
            openTimeout,
            PlaybackOperationTimeoutKind.engineOpen,
          );
        } on PlaybackNativeOperationTimedOut catch (error) {
          if (error.kind == PlaybackNativeOperationKind.open) {
            engineOpenTimedOut = true;
            _diagnostics.operationTimeout(
              PlaybackOperationTimeoutKind.engineOpen,
            );
            throw const _PlaybackOperationTimedOut(
              PlaybackOperationTimeoutKind.engineOpen,
            );
          }
          rethrow;
        } on _PlaybackOperationTimedOut catch (error) {
          engineOpenTimedOut =
              error.kind == PlaybackOperationTimeoutKind.engineOpen;
          rethrow;
        }
        _throwIfStale(token);
        _setState(
          _state.copyWith(
            phase: PlaybackPhase.waitingForReady,
            isBuffering: true,
            statusMessage: currentOpeningStatusMessage,
          ),
        );
        await _waitUntilReady(token);
        _throwIfStale(token);
        if (plan.method == PlayMethod.directPlay) {
          await _applySelectedDirectPlayTracks(plan, token);
        } else {
          _markServerSubtitleApplied(plan, token, engine);
        }
        await _restoreEnginePresentation(token);

        if (resume > Duration.zero) {
          final target = plan.duration == null
              ? _clampToDuration(resume)
              : resume;
          _setState(_state.copyWith(phase: PlaybackPhase.seekingResume));
          final result = await seekAbsolute(target, source: SeekSource.resume);
          if (result.disposition != SeekDisposition.executed) {
            throw TimeoutException('Resume seek did not settle');
          }
          _throwIfStale(token);
          if (playAfterReady) {
            final boundEngine = engine;
            await _operationCoordinator.runTrackedNativeOperation(
              kind: PlaybackNativeOperationKind.play,
              operation: boundEngine.play,
              barrierTimeout: playPauseTimeout,
            );
          }
        }

        _setState(
          _state.copyWith(
            phase: PlaybackPhase.ready,
            isBuffering: false,
            clearError: true,
            clearStatus: true,
          ),
        );
        _throwIfStale(token);
        try {
          await reporter.reportStart(
            _state.position,
            isPaused: !playAfterReady,
          );
        } catch (error) {
          DiagnosticLog.instance.warning(
            'playback',
            'event=playback_start_report_failed '
                'errorType=${error.runtimeType}',
          );
        }
        _throwIfStale(token);
        _startProgressTimer();
        await _startCacheMonitoring(token);
        DiagnosticLog.instance.info(
          'player',
          'event=playback_ready method=${plan.method.serverValue}',
        );
        return;
      } on _PlaybackCancelled {
        if (plan != null) await _stopReporterSafely();
        return;
      } catch (error) {
        if (!_isCurrent(token)) return;
        _discardReadyWaitAfterStartupError();
        final canRetryCacheInMemory =
            !engineOpenTimedOut &&
            plan != null &&
            _state.diskCacheFailureObserved &&
            _state.cacheProfile?.runtimeMode == PlaybackCacheRuntimeMode.disk &&
            _tryReserveAutomaticOpen(
              AutomaticPlaybackOpenReason.cacheCreateMemoryRetry,
            );
        if (canRetryCacheInMemory) {
          _forcedCacheFallbackReason =
              PlaybackCacheFallbackReason.mpvCacheCreateFailed;
          currentOpeningStatusMessage = '文件缓存不可用，正在使用内存缓存…';
          _setState(
            _state.copyWith(
              phase: PlaybackPhase.resolving,
              isBuffering: true,
              statusMessage: currentOpeningStatusMessage,
              cacheFallbackReason: _forcedCacheFallbackReason,
              clearError: true,
            ),
          );
          await _stopForControlledRestart(_state.position);
          await _cleanupCacheSessionSafely();
          continue;
        }
        final canRetry =
            !engineOpenTimedOut &&
            !retriedWithTranscode &&
            resolver.canForceTranscode &&
            plan != null &&
            plan.method != PlayMethod.transcode &&
            _state.phase != PlaybackPhase.ready &&
            _tryReserveAutomaticOpen(transcodeFallbackReason);
        if (canRetry) {
          retriedWithTranscode = true;
          fellBackToTranscode = true;
          forceTranscode = true;
          currentOpeningStatusMessage = '直连失败，正在切换到服务器转码…';
          DiagnosticLog.instance.warning(
            'player',
            'Playback did not become ready; retrying once with Transcode '
                'errorType=${error.runtimeType}',
          );
          _setState(
            _state.copyWith(
              phase: PlaybackPhase.retryingWithTranscode,
              isBuffering: true,
              statusMessage: currentOpeningStatusMessage,
            ),
          );
          await _stopCacheCoordinator();
          await _stopForControlledRestart(_state.position);
          await _cleanupCacheSessionSafely();
          continue;
        }

        DiagnosticLog.instance.warning(
          'player',
          'event=playback_start_failed errorType=${error.runtimeType}',
        );
        if (_isCurrent(token)) {
          final friendly = friendlyPlaybackError(error);
          _setState(
            _state.copyWith(
              phase: PlaybackPhase.failed,
              isBuffering: false,
              errorMessage: fellBackToTranscode
                  ? '直连失败，服务器转码也不可用：$friendly'
                  : friendly,
              clearStatus: true,
            ),
          );
          _advanceGeneration();
        }
        final quiescence = quiesce();
        _shuttingDown = true;
        final nativeBarrier = _operationCoordinator.shutdown();
        await _awaitQuiescenceSafely(quiescence);
        await nativeBarrier;
        await _waitForSeekBookkeeping();
        _frozenSeekStatistics ??= _diagnostics.snapshotSeekStatistics();
        await _cancelSubscriptions();
        final pendingSubtitleApplication = _subtitleApplication;
        if (pendingSubtitleApplication != null) {
          await _awaitSubtitleApplication(pendingSubtitleApplication);
        }
        await _stopCacheCoordinator();
        if (plan != null) await _stopReporterSafely();
        await _stopEngine();
        await _disposeEngine();
        await _cleanupCacheSessionSafely();
        _writeTerminalSummaries();
        return;
      }
    }
  }

  Future<void> _prepareCacheForPlan(
    PlaybackPlan plan,
    int token, {
    Duration readAheadAnchor = Duration.zero,
  }) async {
    final cacheEngine = engine is PlaybackCacheEngine
        ? engine as PlaybackCacheEngine
        : null;
    PlaybackCacheEngineCapabilities capabilities;
    try {
      capabilities = cacheEngine == null
          ? PlaybackCacheEngineCapabilities.unsupported()
          : await cacheEngine.probeCacheCapabilities();
    } catch (_) {
      capabilities = PlaybackCacheEngineCapabilities.unsupported();
    }
    _throwIfStale(token);
    _diagnostics.cacheCapabilitiesResolved(capabilities);

    final effectiveCacheSettings = testOverrides?.sessionTargetBytes == null
        ? cacheSettings
        : cacheSettings.copyWith(
            mode: PlaybackCacheMode.custom,
            customSessionTargetBytes: testOverrides!.sessionTargetBytes,
          );
    final effectiveSpacePollInterval =
        effectiveCacheSettings.mode == PlaybackCacheMode.fullReadAhead &&
            isFullReadAheadEligible(plan)
        ? const Duration(seconds: 2)
        : cacheSpacePollInterval;
    PlaybackCacheStorageSnapshot storageSnapshot =
        const PlaybackCacheStorageSnapshot.unavailable(
          PlaybackCacheStorageFailureReason.storageCapacityUnknown,
        );
    final mayUseDisk =
        plan.transportKind == PlaybackTransportKind.progressiveHttp &&
        effectiveCacheSettings.mode != PlaybackCacheMode.memoryOnly &&
        _forcedCacheFallbackReason == null &&
        capabilities.diskGatePassed;
    if (mayUseDisk) {
      storageSnapshot = await cacheStorage.prepareSession();
      _throwIfStale(token);
      _diagnostics.cacheDirectoryResult(storageSnapshot);
      _cacheSession = storageSnapshot.session;
      storageSnapshot =
          testOverrides?.applyStorageSimulation(storageSnapshot) ??
          storageSnapshot;
      if (!storageSnapshot.isAvailable &&
          storageSnapshot.failureReason ==
              PlaybackCacheStorageFailureReason.storageCapacityUnknown &&
          !_cacheSnapshotUnavailableLogged) {
        _cacheEvidence.recordCacheSnapshotUnavailable();
        _cacheSnapshotUnavailableLogged = true;
        _diagnostics.cacheSnapshotUnavailable();
      }
      final preliminaryRate = ((plan.bitrate ?? 0) / 8 * 2)
          .round()
          .clamp(8 * 1024 * 1024, 1 << 62)
          .toInt();
      final preliminaryLowSpaceTrigger = cacheLowSpaceTriggerBytes(
        reservedFreeBytes: effectiveCacheSettings.reservedFreeBytes,
        inputRateBytesPerSecond: preliminaryRate,
        pollInterval: effectiveSpacePollInterval,
        expectedCloseLatency: const Duration(seconds: 2),
      );
      final available = storageSnapshot.freeBytes;
      if (available != null && available <= preliminaryLowSpaceTrigger) {
        _forcedCacheFallbackReason = PlaybackCacheFallbackReason.lowSpace;
        _recordCacheSafetyDiagnostic(PlaybackCacheSafetyReason.lowSpace);
      }
    }

    var profile = const PlaybackCacheProfileResolver().resolve(
      plan: plan,
      settings: effectiveCacheSettings,
      capabilities: capabilities,
      storage: storageSnapshot,
      readAheadAnchor: readAheadAnchor,
      spacePollInterval: effectiveSpacePollInterval,
    );
    final forcedReason = _forcedCacheFallbackReason;
    if (forcedReason != null &&
        profile.runtimeMode != PlaybackCacheRuntimeMode.disabled) {
      profile = profile.memoryFallback(
        forcedReason,
        sizeConfidence: profile.sizeConfidence,
        readAheadAnchor: profile.readAheadAnchor,
        estimatedSourceBytes: profile.estimatedSourceBytes,
      );
    }
    final streamBufferBytes = testOverrides?.streamBufferBytes;
    if (streamBufferBytes != null) {
      profile = profile.copyWith(streamBufferBytes: streamBufferBytes);
    }
    if (profile.runtimeMode == PlaybackCacheRuntimeMode.disk) {
      final inputRate = ((plan.bitrate ?? 0) / 8 * 2).round().clamp(
        8 * 1024 * 1024,
        1 << 62,
      );
      final lowSpaceTrigger = cacheLowSpaceTriggerBytes(
        reservedFreeBytes: profile.reservedFreeBytes,
        inputRateBytesPerSecond: inputRate,
        pollInterval: effectiveSpacePollInterval,
        expectedCloseLatency: const Duration(seconds: 2),
      );
      if ((storageSnapshot.freeBytes ?? 0) <= lowSpaceTrigger) {
        _forcedCacheFallbackReason = PlaybackCacheFallbackReason.lowSpace;
        _recordCacheSafetyDiagnostic(PlaybackCacheSafetyReason.lowSpace);
        profile = profile.memoryFallback(PlaybackCacheFallbackReason.lowSpace);
      }
    }
    _diagnostics.cacheProfileResolved(profile);
    _cacheEvidence.recordProfileResolved(profile.runtimeMode);
    PlaybackCacheApplyResult applyResult;
    if (cacheEngine == null) {
      applyResult = PlaybackCacheApplyResult(
        requestedMode: profile.runtimeMode,
        actualMode: profile.runtimeMode == PlaybackCacheRuntimeMode.disabled
            ? PlaybackCacheRuntimeMode.disabled
            : PlaybackCacheRuntimeMode.unconfirmed,
        fallbackReason: profile.runtimeMode == PlaybackCacheRuntimeMode.disabled
            ? profile.fallbackReason
            : PlaybackCacheFallbackReason.engineCapabilityUnavailable,
        requiresPlayerRecreation: false,
        readBack: const {},
      );
    } else {
      applyResult = await cacheEngine.configureCache(profile, capabilities);
    }
    _throwIfStale(token);
    if (applyResult.requiresPlayerRecreation) {
      await _cleanupCacheSessionSafely();
      await _recreateEngine(token);
      return _prepareCacheForPlan(
        plan,
        token,
        readAheadAnchor: readAheadAnchor,
      );
    }
    _diagnostics.cacheApplyResult(applyResult);
    if (applyResult.cacheEvidence != PlaybackCacheEvidence.unconfirmed) {
      _lastNativeCacheEvidence = applyResult.cacheEvidence;
      _lastNativeConfirmedMode = applyResult.actualMode;
    }
    final cacheCreateResult = _cacheCreateResult(applyResult);
    if (cacheCreateResult != null) {
      _cacheEvidence.recordCacheCreate(cacheCreateResult);
    }
    _cacheEvidence.observe(
      PlaybackCacheEvidenceObservation(
        cacheEvidence: applyResult.cacheEvidence,
        requestedMode: applyResult.requestedMode,
        confirmedMode: applyResult.actualMode,
        fallbackReason: applyResult.fallbackReason,
        readAheadStrategy: profile.readAheadStrategy,
        budgetPolicy: profile.budgetPolicy,
        sizeConfidence: profile.sizeConfidence,
        fullReadAheadEligible:
            profile.readAheadStrategy ==
            PlaybackCacheReadAheadStrategy.mediaEnd,
        settingsMode: cacheSettings.mode,
        optionalTuningDegraded: applyResult.optionalTuningDegraded,
        optionalTuningUnavailableCount:
            applyResult.optionalTuningUnavailable.length,
        optionalTuningUnavailable: applyResult.optionalTuningUnavailable,
        cacheCreateResult: cacheCreateResult,
        cacheEnabled:
            applyResult.actualMode != PlaybackCacheRuntimeMode.disabled,
        cacheOnDisk: applyResult.actualMode == PlaybackCacheRuntimeMode.disk,
        testOverrideActive: testOverrides?.isActive ?? false,
      ),
    );
    if (applyResult.actualMode != PlaybackCacheRuntimeMode.disk) {
      await _cleanupCacheSessionSafely();
    }
    _setState(
      _state.copyWith(
        cacheProfile: profile,
        cacheCapabilities: capabilities,
        cacheRuntimeMode: applyResult.actualMode,
        cacheFallbackReason: applyResult.fallbackReason,
        clearCacheSnapshot: true,
        clearCacheObservation: true,
        diskCacheFailureObserved: false,
      ),
    );
    if (_testCacheFailureObservationPending) {
      _testCacheFailureObservationPending = false;
      _handleEngineLog('Failed to create file cache');
    }
  }

  Future<void> playOrPause() async {
    if (_state.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    if (_retiring ||
        _shuttingDown ||
        _disposed ||
        _engineDisposed ||
        _lifecycleSuspended) {
      return;
    }
    final token = _generation;
    final boundEngine = engine;
    _desiredPlaying = true;
    var playSucceeded = _state.isPlaying;
    if (!_state.isPlaying) {
      try {
        await _operationCoordinator.runTrackedNativeOperation(
          kind: PlaybackNativeOperationKind.play,
          operation: boundEngine.play,
          barrierTimeout: playPauseTimeout,
        );
        playSucceeded = true;
      } on PlaybackNativeOperationTimedOut {
        _desiredPlaying = false;
        if (_state.isPlaying) _setState(_state.copyWith(isPlaying: false));
        return;
      }
    }
    if (!_isCurrent(token) ||
        !identical(engine, boundEngine) ||
        _lifecycleSuspended) {
      _setState(_state.copyWith(isPlaying: false));
      return;
    }
    if (playSucceeded) await _reportProgress(isPaused: false);
  }

  Future<void> pause() async {
    final shouldPause = _desiredPlaying || _state.isPlaying;
    _desiredPlaying = false;
    if (shouldPause && !_engineDisposed && !_shuttingDown) {
      final boundEngine = engine;
      try {
        await _operationCoordinator.runTrackedNativeOperation(
          kind: PlaybackNativeOperationKind.pause,
          operation: boundEngine.pause,
          barrierTimeout: playPauseTimeout,
        );
      } on PlaybackNativeOperationTimedOut {
        // Logical pause state still wins; a late native completion cannot
        // restore playing state through a retired generation.
      }
    }
    if (_state.isPlaying) _setState(_state.copyWith(isPlaying: false));
    await _reportProgress();
  }

  Future<void> quiesce() {
    final existing = _retirementQuiescenceOperation;
    if (existing != null) return existing;

    if (_retirementState == PlaybackRetirementState.active) {
      _retirementState = PlaybackRetirementState.quiescing;
    }
    _desiredPlaying = false;
    _advanceGeneration();
    _cacheCoordinator?.pause();
    if (_state.isPlaying) _setState(_state.copyWith(isPlaying: false));
    if (_engineDisposed) {
      if (_retirementState != PlaybackRetirementState.quarantined) {
        _retirementState = PlaybackRetirementState.closed;
      }
      return _retirementQuiescenceOperation = Future<void>.value();
    }
    final boundEngine = engine;
    final operation = _operationCoordinator.beginQuiescence(
      kind: PlaybackNativeOperationKind.retirementQuiesce,
      operation: boundEngine.quiesce,
      barrierTimeout: retirementQuiesceTimeout,
      onTimeout: () {
        _retirementState = PlaybackRetirementState.quarantined;
      },
    );
    return _retirementQuiescenceOperation = operation.then<void>(
      (_) {
        if (_retirementState == PlaybackRetirementState.quiescing) {
          _retirementState = PlaybackRetirementState.retiring;
        }
      },
      onError: (Object _, StackTrace _) {
        _retirementState = PlaybackRetirementState.quarantined;
      },
    );
  }

  Future<void> quiesceForLifecycle() {
    _lifecycleQuiescenceRevision++;
    final resumeInFlight = _lifecycleResumeOperation != null;
    _lifecycleSuspended = true;
    _cacheCoordinator?.pause();
    if (_state.isPlaying) _setState(_state.copyWith(isPlaying: false));
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) {
      return Future<void>.value();
    }
    final existing = _lifecycleQuiescenceOperation;
    if (existing != null && !resumeInFlight) return existing;

    final boundEngine = engine;
    final operation = _operationCoordinator.beginQuiescence(
      kind: PlaybackNativeOperationKind.lifecycleQuiesce,
      operation: boundEngine.quiesceForLifecycle,
      barrierTimeout: lifecycleQuiesceTimeout,
    );
    _lifecycleQuiescenceOperation = operation;
    unawaited(
      operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return operation;
  }

  Future<void> pauseForLifecycle() async {
    await quiesceForLifecycle();
    await _reportProgress();
  }

  Future<void> resumeForLifecycle() {
    final existing = _lifecycleResumeOperation;
    if (existing != null) return existing;
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) {
      return Future<void>.value();
    }
    final revision = _lifecycleQuiescenceRevision;
    late final Future<void> operation;
    operation = _resumeForLifecycle(revision).whenComplete(() {
      if (identical(_lifecycleResumeOperation, operation)) {
        _lifecycleResumeOperation = null;
      }
    });
    _lifecycleResumeOperation = operation;
    return operation;
  }

  Future<void> _resumeForLifecycle(int revision) async {
    final quiescence = _lifecycleQuiescenceOperation;
    if (quiescence != null) await quiescence;
    if (!_canResumeLifecycle(revision)) return;

    final boundEngine = engine;
    await _operationCoordinator.runTrackedNativeOperation(
      kind: PlaybackNativeOperationKind.lifecycleQuiesce,
      operation: boundEngine.resumeFromLifecycleQuiescence,
      barrierTimeout: lifecycleQuiesceTimeout,
    );
    if (!_canResumeLifecycle(revision)) {
      if (!_retiring && identical(engine, boundEngine)) {
        await _operationCoordinator.beginQuiescence(
          kind: PlaybackNativeOperationKind.lifecycleQuiesce,
          operation: boundEngine.quiesceForLifecycle,
          barrierTimeout: lifecycleQuiesceTimeout,
        );
      }
      return;
    }

    await _cacheCoordinator?.resume();
    if (!_canResumeLifecycle(revision)) {
      _cacheCoordinator?.pause();
      if (!_retiring && identical(engine, boundEngine)) {
        await _operationCoordinator.beginQuiescence(
          kind: PlaybackNativeOperationKind.lifecycleQuiesce,
          operation: boundEngine.quiesceForLifecycle,
          barrierTimeout: lifecycleQuiesceTimeout,
        );
      }
      return;
    }
    _lifecycleSuspended = false;
    _lifecycleQuiescenceOperation = null;
    if (_pendingRecoveryFingerprint != null) _scheduleRuntimeRecovery();
  }

  Future<void> handleMemoryPressure() async {
    await _cacheCoordinator?.handleMemoryPressure();
  }

  Future<SeekResult> seekAbsolute(
    Duration position, {
    required SeekSource source,
  }) {
    if (_retiring || _lifecycleSuspended || _shuttingDown || _disposed) {
      return Future.value(_cancelledSeekResult(position));
    }
    final bookkeeping = Completer<void>();
    return _trackSeekOperation(
      _seekAbsolute(position, source: source, bookkeeping: bookkeeping),
      bookkeeping,
    );
  }

  Future<SeekResult> _seekAbsolute(
    Duration position, {
    required SeekSource source,
    required Completer<void> bookkeeping,
  }) async {
    _diagnostics.seekRequested();
    _cacheEvidence.recordSeekRequested();
    late final SeekResult result;
    try {
      result = await _operationCoordinator.seekAbsolute(
        position,
        source: source,
      );
    } catch (_) {
      _cacheEvidence.recordSeekCompleted(SeekDisposition.failed);
      _completeSeekBookkeeping(bookkeeping);
      rethrow;
    }
    _cacheEvidence.recordSeekCompleted(result.disposition);
    _diagnostics.seekCompleted(result);
    _completeSeekBookkeeping(bookkeeping);
    if (result.disposition == SeekDisposition.executed) {
      _recordExecutedSeek();
      final committedPosition = result.committedPosition ?? _state.position;
      _updateReadAheadAnchorAfterExecutedSeek(committedPosition);
      _injectApprovedSeekFailureIfPending();
      await _reportProgress();
      await _cacheCoordinator?.afterExecutedSeek(
        committedPosition: committedPosition,
      );
    }
    return result;
  }

  Future<SeekResult> seekRelative(
    Duration offset, {
    required SeekSource source,
  }) {
    if (_retiring || _lifecycleSuspended || _shuttingDown || _disposed) {
      return Future.value(
        _cancelledSeekResult(_state.displayPosition + offset),
      );
    }
    final bookkeeping = Completer<void>();
    return _trackSeekOperation(
      _seekRelative(offset, source: source, bookkeeping: bookkeeping),
      bookkeeping,
    );
  }

  Future<SeekResult> _seekRelative(
    Duration offset, {
    required SeekSource source,
    required Completer<void> bookkeeping,
  }) async {
    _diagnostics.seekRequested();
    _cacheEvidence.recordSeekRequested();
    late final SeekResult result;
    try {
      result = await _operationCoordinator.seekRelative(offset, source: source);
    } catch (_) {
      _cacheEvidence.recordSeekCompleted(SeekDisposition.failed);
      _completeSeekBookkeeping(bookkeeping);
      rethrow;
    }
    _cacheEvidence.recordSeekCompleted(result.disposition);
    _diagnostics.seekCompleted(result);
    _completeSeekBookkeeping(bookkeeping);
    if (result.disposition == SeekDisposition.executed) {
      _recordExecutedSeek();
      final committedPosition = result.committedPosition ?? _state.position;
      _updateReadAheadAnchorAfterExecutedSeek(committedPosition);
      _injectApprovedSeekFailureIfPending();
      await _reportProgress();
      await _cacheCoordinator?.afterExecutedSeek(
        committedPosition: committedPosition,
      );
    }
    return result;
  }

  void _handleRequestedPositionChanged(Duration? position) {
    if (_disposed) return;
    _setState(
      _state.copyWith(
        requestedPosition: position,
        clearRequestedPosition: position == null,
      ),
    );
  }

  Future<void> selectMediaSource(String mediaSourceId) =>
      reconfigure(mediaSourceId: mediaSourceId);

  Future<void> setMaximumBitrate(int bitrate) =>
      reconfigure(maxStreamingBitrate: bitrate);

  Future<void> selectAudioStream(int streamIndex) async {
    final plan = _state.plan;
    if (plan == null) return;
    final boundEngine = engine;
    final token = _generation;
    if (_isAudioApplied(streamIndex, token, boundEngine)) return;
    _selectedAudioStreamIndex = streamIndex;
    _setState(
      _state.copyWith(
        audioSelectionStatus: AudioSelectionStatus.applying,
        clearAppliedAudioStreamIndex: true,
      ),
    );
    try {
      if (plan.method == PlayMethod.directPlay) {
        final tracks = await _waitForTracks(
          audio: true,
          token: token,
          boundEngine: boundEngine,
        );
        _throwIfCurrentEngine(token, boundEngine);
        final serverTrack = _trackMapper.findByIndex(
          plan,
          'audio',
          streamIndex,
        );
        final engineTrackId = serverTrack == null
            ? null
            : _trackMapper.engineTrackId(serverTrack, tracks);
        if (engineTrackId != null) {
          await _runPropertyWrite(
            boundEngine,
            () => boundEngine.selectAudioTrack(engineTrackId),
          );
          _throwIfCurrentEngine(token, boundEngine);
          _markAudioApplied(streamIndex, token, boundEngine);
          reporter.updatePlan(plan.copyWith(audioStreamIndex: streamIndex));
          await _reportProgress();
          return;
        }
      }
      await reconfigure(
        audioStreamIndex: streamIndex,
        forceTranscode: plan.method == PlayMethod.directPlay,
      );
    } on _PlaybackCancelled {
      return;
    } catch (error) {
      if (_isCurrent(token)) {
        _setState(
          _state.copyWith(audioSelectionStatus: AudioSelectionStatus.failed),
        );
      }
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_audio_apply_failed errorType=${error.runtimeType}',
      );
    }
  }

  Future<void> selectSubtitleStream(int? streamIndex) async {
    final plan = _state.plan;
    if (plan == null) return;
    final selection = streamIndex == null
        ? const SubtitleSelection.disabled()
        : SubtitleSelection.explicitStream(streamIndex);
    final boundEngine = engine;
    final token = _generation;
    if (_isSubtitleApplied(selection, token, boundEngine)) return;
    _cancelLateSubtitleTask();
    _desiredSubtitleSelection = selection;
    _setState(
      _state.copyWith(
        desiredSubtitleSelection: selection,
        subtitleSelectionStatus: SubtitleSelectionStatus.applying,
        clearAppliedSubtitleStreamIndex: true,
        clearSubtitleSelectionError: true,
      ),
    );
    try {
      if (plan.method == PlayMethod.directPlay) {
        await _applySubtitleSelection(plan, token, boundEngine);
        if (_isSubtitleApplied(selection, token, boundEngine)) {
          await _reportProgress();
        }
        return;
      }
      await reconfigure(
        subtitleStreamIndex: streamIndex,
        clearSubtitle: streamIndex == null,
      );
    } on _PlaybackCancelled {
      return;
    } catch (error) {
      _markSubtitleFailed(
        selection: selection,
        token: token,
        boundEngine: boundEngine,
        error: error,
      );
    }
  }

  Future<void> setPlaybackRate(double rate) async {
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) return;
    final safeRate = rate.clamp(0.25, 3.0).toDouble();
    final boundEngine = engine;
    await _runPropertyWrite(boundEngine, () => boundEngine.setRate(safeRate));
    _desiredPlaybackRate = safeRate;
    _setState(_state.copyWith(playbackRate: safeRate));
  }

  Future<void> setAudioDelay(Duration delay) async {
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) return;
    final boundEngine = engine;
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.setAudioDelay(delay),
    );
    _desiredAudioDelay = delay;
  }

  Future<void> setSubtitleDelay(Duration delay) async {
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) return;
    final boundEngine = engine;
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.setSubtitleDelay(delay),
    );
    _desiredSubtitleDelay = delay;
  }

  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) return;
    final boundEngine = engine;
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.configureSubtitleStyle(
        fontSize: fontSize,
        color: color,
        outlineColor: outlineColor,
        position: position,
      ),
    );
    _desiredSubtitleStyle = _SubtitleStyle(
      fontSize: fontSize,
      color: color,
      outlineColor: outlineColor,
      position: position,
    );
  }

  Future<void> reconfigure({
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool clearSubtitle = false,
    int? maxStreamingBitrate,
    bool forceTranscode = false,
  }) {
    if (_retiring || _shuttingDown || _disposed || _engineDisposed) {
      return Future<void>.value();
    }
    return _operationCoordinator.runControlOperation(
      priority: PlaybackControlOperationPriority.userReconfigure,
      operation: (lease) async {
        if (_retiring ||
            _disposed ||
            _shuttingDown ||
            _engineDisposed ||
            !lease.isCurrent) {
          return;
        }
        final position = _state.position;
        final wasPlaying = _desiredPlaying;
        _advanceGeneration();
        _progressTimer?.cancel();
        await _stopCacheCoordinator();
        if (!lease.isCurrent || _shuttingDown) return;
        _setState(
          _state.copyWith(
            phase: PlaybackPhase.resolving,
            isBuffering: true,
            clearError: true,
          ),
        );
        await _stopForControlledRestart(position);
        if (!lease.isCurrent || _shuttingDown) return;
        await _cleanupCacheSessionSafely();
        if (!lease.isCurrent || _shuttingDown) return;

        if (mediaSourceId != null) _selectedMediaSourceId = mediaSourceId;
        if (audioStreamIndex != null) {
          _selectedAudioStreamIndex = audioStreamIndex;
        }
        if (clearSubtitle) {
          _desiredSubtitleSelection = const SubtitleSelection.disabled();
        } else if (subtitleStreamIndex != null) {
          _desiredSubtitleSelection = SubtitleSelection.explicitStream(
            subtitleStreamIndex,
          );
        }
        if (maxStreamingBitrate != null) {
          _maxStreamingBitrate = maxStreamingBitrate;
        }
        if (!lease.isCurrent || _shuttingDown) return;
        await _startPlayback(
          resumePosition: position,
          playAfterReady: wasPlaying,
          forceTranscodeInitially: forceTranscode,
        );
      },
    );
  }

  Future<void> shutdown() {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    final quiescence = quiesce();
    _shuttingDown = true;
    final nativeBarrier = _operationCoordinator.shutdown();
    final operation = _shutdown(quiescence, nativeBarrier);
    _shutdownOperation = operation;
    return operation;
  }

  Future<void> _shutdown(
    Future<void> quiescence,
    Future<void> nativeBarrier,
  ) async {
    final nativeBudget = _ShutdownNativeBarrierBudget(shutdownBarrierTimeout);
    _advanceGeneration();
    _pendingRecoveryFingerprint = null;
    _progressTimer?.cancel();
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.stopping,
        isPlaying: false,
        isBuffering: false,
      ),
    );
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _PlaybackCancelled());
    }
    await _cancelSubscriptions();
    await _stopCacheCoordinator(flushEvidence: false);
    final pendingSubtitleApplication = _subtitleApplication;
    if (pendingSubtitleApplication != null) {
      await _awaitSubtitleApplication(pendingSubtitleApplication);
    }
    await _waitForSeekBookkeeping();
    _frozenSeekStatistics ??= _diagnostics.snapshotSeekStatistics();

    final initialNativeBarrier = Future.wait<void>([
      _awaitQuiescenceSafely(quiescence),
      nativeBarrier,
    ]);
    if (!await nativeBudget.wait(initialNativeBarrier)) {
      _retirementState = PlaybackRetirementState.quarantined;
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_shutdown_barrier_timeout phase=quiescence',
      );
    }

    DiagnosticLog.instance.info('player', 'event=playback_closing');
    await _stopEngine(timeout: nativeBudget.remaining);
    await _stopReporterSafely();
    final disposalConfirmed = await _disposeEngine(
      timeout: nativeBudget.remaining,
    );
    await _cleanupCacheSessionSafely();
    _writeTerminalSummaries();
    if (disposalConfirmed &&
        _retirementState != PlaybackRetirementState.quarantined) {
      _retirementState = PlaybackRetirementState.closed;
    }
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.idle,
        isPlaying: false,
        isBuffering: false,
      ),
    );
  }

  Future<void> _bindEngine(int token) async {
    final pendingSubtitleApplication = _subtitleApplication;
    _cancelLateSubtitleTask();
    _cancelSubtitleTrackWaits();
    if (pendingSubtitleApplication != null) {
      await _awaitSubtitleApplication(pendingSubtitleApplication);
    }
    await _cancelSubscriptions();
    _throwIfStale(token);
    final boundEngine = engine;
    _appliedAudioEngine = null;
    _appliedSubtitleEngine = null;
    _subtitleApplicationEngine = null;
    _subtitleApplication = null;
    _subtitleApplicationSelection = null;
    _subtitleApplicationGeneration = null;
    _setState(
      _state.copyWith(
        audioTracks: const [],
        subtitleTracks: const [],
        audioSelectionStatus: AudioSelectionStatus.notApplied,
        clearAppliedAudioStreamIndex: true,
        desiredSubtitleSelection: _desiredSubtitleSelection,
        subtitleSelectionStatus: SubtitleSelectionStatus.notApplied,
        appliedSubtitleKind: AppliedSubtitleKind.none,
        clearAppliedSubtitleStreamIndex: true,
        subtitleApplicationGeneration: token,
        clearSubtitleSelectionError: true,
      ),
    );
    bool eventIsCurrent() =>
        identical(engine, boundEngine) && _isCurrent(token);
    _subscriptions.addAll([
      boundEngine.positionStream.listen((position) {
        if (!eventIsCurrent()) return;
        _operationCoordinator.updateCommittedPosition(position);
        _updateStablePlayback(position);
        _setState(_state.copyWith(position: position));
        if (position > Duration.zero) _markReady();
      }),
      boundEngine.durationStream.listen((duration) {
        if (!eventIsCurrent()) return;
        _setState(_state.copyWith(duration: duration));
        if (duration > Duration.zero) _markReady();
      }),
      boundEngine.bufferStream.listen((buffer) {
        if (!eventIsCurrent()) return;
        _setState(_state.copyWith(buffer: buffer));
        if (buffer > Duration.zero) _markReady();
      }),
      boundEngine.playingStream.listen((playing) {
        if (!eventIsCurrent()) return;
        _setState(
          _state.copyWith(
            isPlaying: playing && !_retiring && !_lifecycleSuspended,
          ),
        );
      }),
      boundEngine.bufferingStream.listen((buffering) {
        if (!eventIsCurrent()) return;
        if (buffering) _sawBuffering = true;
        if (buffering) _stablePlaybackSince = null;
        _setState(_state.copyWith(isBuffering: buffering));
        if (!buffering && _sawBuffering) _markReady();
      }),
      boundEngine.completedStream.listen((completed) {
        if (!eventIsCurrent()) return;
        _setState(_state.copyWith(isCompleted: completed));
      }),
      boundEngine.errorStream.listen((error) {
        if (!eventIsCurrent()) return;
        _handleEngineError(error);
      }),
      boundEngine.logStream.listen((log) {
        if (!eventIsCurrent()) return;
        _handleEngineLog(log);
      }),
      boundEngine.audioTracksStream.listen((tracks) {
        if (!eventIsCurrent()) return;
        _setState(_state.copyWith(audioTracks: tracks));
      }),
      boundEngine.subtitleTracksStream.listen((tracks) {
        if (!eventIsCurrent()) return;
        _setState(_state.copyWith(subtitleTracks: tracks));
      }),
    ]);
  }

  void _handleEngineError(String error) {
    final fingerprint = _approvedRecoveryFingerprint(error);
    final diagnosticFingerprint = _engineDiagnosticFingerprint(error);
    if (_shouldWriteEngineFingerprint(diagnosticFingerprint)) {
      DiagnosticLog.instance.error(
        'player',
        'event=playback_engine_error fingerprint=$diagnosticFingerprint',
      );
    }
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
      return;
    }
    if (_state.phase == PlaybackPhase.ready) {
      if (_requestRuntimeRecovery(error)) return;
      if (fingerprint != null &&
          session.hasUsed(
            AutomaticPlaybackOpenReason.runtimeSameMethodRecovery,
          )) {
        _setRuntimeRecoveryFailed(fingerprint);
        return;
      }
      _setState(
        _state.copyWith(
          phase: PlaybackPhase.failed,
          isBuffering: false,
          errorMessage: friendlyPlaybackError(error),
        ),
      );
    }
  }

  void _handleEngineLog(String log) {
    final lower = log.toLowerCase();
    if (lower.contains('failed to create file cache') &&
        !_state.diskCacheFailureObserved) {
      _cacheEvidence.recordCacheCreate(PlaybackCacheCreateResult.failed);
      _diagnostics.cacheMpvCreateFailed();
      _setState(
        _state.copyWith(
          diskCacheFailureObserved: true,
          cacheRuntimeMode: PlaybackCacheRuntimeMode.unconfirmed,
          cacheFallbackReason:
              PlaybackCacheFallbackReason.actualModeUnconfirmed,
        ),
      );
      unawaited(
        _resolveObservedCacheFailure(
          _generation,
          _cacheFailureObservationGeneration,
        ),
      );
    }
    final fingerprint = _engineDiagnosticFingerprint(log);
    if (_shouldWriteEngineFingerprint(fingerprint)) {
      DiagnosticLog.instance.warning(
        'libmpv',
        'event=libmpv_log fingerprint=$fingerprint',
      );
    }
    if ((_state.phase == PlaybackPhase.ready ||
            _state.phase == PlaybackPhase.recoveryPending ||
            _state.phase == PlaybackPhase.recovering) &&
        _requestRuntimeRecovery(log)) {
      return;
    }

    if (_startupFailureSignaled || !_isStartupPhase(_state.phase)) return;
    if (!_isFatalStartupLog(lower)) return;

    final completer = _readyCompleter;
    if (completer == null || completer.isCompleted) return;
    _startupFailureSignaled = true;
    completer.completeError(log);
  }

  Future<void> _resolveObservedCacheFailure(
    int token,
    int observationGeneration,
  ) async {
    final cacheEngine = engine is PlaybackCacheEngine
        ? engine as PlaybackCacheEngine
        : null;
    PlaybackCacheEngineSnapshot? snapshot;
    try {
      snapshot = cacheEngine == null
          ? null
          : await _withDeadline(
              cacheEngine.readCacheSnapshot(),
              cacheCleanupTimeout,
              PlaybackOperationTimeoutKind.cacheSnapshotRead,
            );
    } catch (_) {
      snapshot = null;
    }
    if (!_isCurrent(token) ||
        observationGeneration != _cacheFailureObservationGeneration) {
      return;
    }
    if (snapshot == null && !_cacheSnapshotUnavailableLogged) {
      _cacheEvidence.recordCacheSnapshotUnavailable();
      _cacheSnapshotUnavailableLogged = true;
      _diagnostics.cacheSnapshotUnavailable();
    }
    final mode = snapshot?.cacheOnDisk == false
        ? PlaybackCacheRuntimeMode.memoryFallback
        : (snapshot?.fileCacheBytes ?? 0) > 0
        ? PlaybackCacheRuntimeMode.disk
        : PlaybackCacheRuntimeMode.unconfirmed;
    final reason = switch (mode) {
      PlaybackCacheRuntimeMode.disk => PlaybackCacheFallbackReason.none,
      PlaybackCacheRuntimeMode.memoryFallback =>
        PlaybackCacheFallbackReason.mpvCacheCreateFailed,
      _ => PlaybackCacheFallbackReason.actualModeUnconfirmed,
    };
    _setState(
      _state.copyWith(
        cacheSnapshot: snapshot,
        clearCacheSnapshot: snapshot == null,
        cacheRuntimeMode: mode,
        cacheFallbackReason: reason,
      ),
    );
  }

  Future<void> _startCacheMonitoring(int token) async {
    await _stopCacheCoordinator();
    _throwIfStale(token);
    final cacheEngine = engine is PlaybackCacheEngine
        ? engine as PlaybackCacheEngine
        : null;
    final profile = _state.cacheProfile;
    final cacheSession = _cacheSession;
    if (cacheEngine == null ||
        profile == null ||
        cacheSession == null ||
        _state.cacheRuntimeMode != PlaybackCacheRuntimeMode.disk) {
      return;
    }
    late final PlaybackCacheCoordinator coordinator;
    coordinator = PlaybackCacheCoordinator(
      engine: cacheEngine,
      storage: cacheStorage,
      session: cacheSession,
      profile: profile,
      mediaBitrate: _state.plan?.bitrate,
      committedPosition: () => _state.position,
      generation: token,
      isGenerationCurrent: _isCurrent,
      playbackItemSessionIdentity: session.id,
      isReadIdentityCurrent: (identity) =>
          identity.sessionIdentity == session.id &&
          identical(identity.engineIdentity, engine) &&
          _isCurrent(identity.operationGeneration),
      onObservation: (observation) {
        if (_disposed ||
            !_isCurrent(token) ||
            !identical(_cacheCoordinator, coordinator)) {
          return;
        }
        if (observation.engineSnapshot == null &&
            !_cacheSnapshotUnavailableLogged) {
          _cacheEvidence.recordCacheSnapshotUnavailable();
          _cacheSnapshotUnavailableLogged = true;
          _diagnostics.cacheSnapshotUnavailable();
        }
        _setState(
          _state.copyWith(
            cacheSnapshot: observation.engineSnapshot,
            clearCacheSnapshot: observation.engineSnapshot == null,
            cacheObservation: observation,
          ),
        );
        final evidenceObservation = _cacheEvidenceObservation(observation);
        _cacheEvidence.observe(evidenceObservation);
      },
      onSafetyReopen: _handleCacheSafetyReopen,
      statePollInterval: cacheStatePollInterval,
      spacePollInterval:
          profile.readAheadStrategy == PlaybackCacheReadAheadStrategy.mediaEnd
          ? const Duration(seconds: 2)
          : cacheSpacePollInterval,
      mediaDuration: _state.plan?.duration,
    );
    _cacheCoordinator = coordinator;
    try {
      await _withDeadline(
        coordinator.start(),
        cacheCleanupTimeout,
        PlaybackOperationTimeoutKind.cacheMonitorStart,
      );
    } catch (error) {
      if (identical(_cacheCoordinator, coordinator)) {
        _cacheCoordinator = null;
      }
      coordinator.cancel();
      if (_isCurrent(token)) {
        if (!_cacheSnapshotUnavailableLogged) {
          _cacheEvidence.recordCacheSnapshotUnavailable();
          _cacheSnapshotUnavailableLogged = true;
          _diagnostics.cacheSnapshotUnavailable();
        }
        _setState(
          _state.copyWith(
            cacheRuntimeMode: PlaybackCacheRuntimeMode.unconfirmed,
            cacheFallbackReason:
                PlaybackCacheFallbackReason.actualModeUnconfirmed,
            clearCacheObservation: true,
          ),
        );
      }
      DiagnosticLog.instance.warning(
        'playback-cache',
        'event=playback_cache_monitor_start_failed '
            'errorType=${error.runtimeType}',
      );
    }
    _throwIfStale(token);
  }

  Future<void> _stopCacheCoordinator({bool flushEvidence = true}) async {
    final coordinator = _cacheCoordinator;
    _cacheCoordinator = null;
    if (coordinator == null) {
      if (flushEvidence) _flushCacheEvidenceObservation();
      return;
    }
    try {
      await _withDeadline(
        coordinator.stop(),
        cacheCleanupTimeout,
        PlaybackOperationTimeoutKind.cacheCleanup,
      );
    } catch (error) {
      DiagnosticLog.instance.warning(
        'playback-cache',
        'event=playback_cache_monitor_stop_failed '
            'errorType=${error.runtimeType}',
      );
    } finally {
      if (flushEvidence) _flushCacheEvidenceObservation();
    }
  }

  void _cancelCacheCoordinator() {
    final coordinator = _cacheCoordinator;
    _cacheCoordinator = null;
    coordinator?.cancel();
  }

  Future<void> _handleCacheSafetyReopen(
    PlaybackCacheSafetyReason safetyReason,
  ) {
    if (_disposed || _shuttingDown || _engineDisposed) {
      return Future<void>.value();
    }
    _cacheEvidence.recordReopen(_reopenReason(safetyReason));
    if (!_tryReserveAutomaticOpen(
      AutomaticPlaybackOpenReason.cacheSafetyReopen,
    )) {
      return Future<void>.value();
    }
    _recordCacheSafetyDiagnostic(safetyReason);
    _forcedCacheFallbackReason = switch (safetyReason) {
      PlaybackCacheSafetyReason.budget =>
        PlaybackCacheFallbackReason.sessionBudgetReached,
      PlaybackCacheSafetyReason.lowSpace =>
        PlaybackCacheFallbackReason.lowSpace,
      PlaybackCacheSafetyReason.memoryPressure =>
        PlaybackCacheFallbackReason.memoryPressure,
    };
    return _operationCoordinator.runControlOperation(
      priority: PlaybackControlOperationPriority.cacheSafety,
      operation: (lease) async {
        if (_disposed || _shuttingDown || _engineDisposed || !lease.isCurrent) {
          return;
        }
        await _performCacheSafetyReopen(lease).timeout(
          recoveryPolicy.recoveryAttemptTimeout,
          onTimeout: () {
            if (!lease.isCurrent || _disposed || _shuttingDown) return;
            _invalidateCurrentControllerOperation();
            _setState(
              _state.copyWith(
                phase: PlaybackPhase.failed,
                isBuffering: false,
                errorMessage: '缓存调整失败，请返回后重试',
                clearStatus: true,
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _performCacheSafetyReopen(
    PlaybackControlOperationLease lease,
  ) async {
    final position = _state.requestedPosition ?? _state.position;
    final wasPlaying = _desiredPlaying;
    _advanceGeneration();
    _progressTimer?.cancel();
    _cancelCacheCoordinator();
    if (!lease.isCurrent || _shuttingDown) return;
    _setState(
      _state.copyWith(
        isBuffering: true,
        statusMessage: '正在调整缓存…',
        cacheFallbackReason: _forcedCacheFallbackReason,
      ),
    );
    await _stopForControlledRestart(position);
    if (!lease.isCurrent || _shuttingDown) return;
    await _cleanupCacheSessionSafely();
    if (_disposed || _shuttingDown || !lease.isCurrent) return;
    await _startPlayback(
      resumePosition: position,
      playAfterReady: wasPlaying,
      openingStatusMessage: '正在调整缓存…',
    );
    if (!_disposed &&
        !_shuttingDown &&
        lease.isCurrent &&
        _state.phase == PlaybackPhase.failed) {
      _setState(
        _state.copyWith(errorMessage: '缓存调整失败，请返回后重试', clearStatus: true),
      );
    }
  }

  Future<void> _stopForControlledRestart(Duration position) async {
    try {
      await _withDeadline(
        reporter.stop(position),
        reporterTimeout,
        PlaybackOperationTimeoutKind.reporterStop,
      );
    } catch (_) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_reporter_stop_failed operation=controlled_restart',
      );
    }
    try {
      await _withDeadline(
        _operationCoordinator.runTrackedNativeOperation(
          kind: PlaybackNativeOperationKind.stop,
          operation: engine.stop,
          barrierTimeout: stopTimeout,
        ),
        stopTimeout,
        PlaybackOperationTimeoutKind.engineStop,
      );
    } catch (_) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_engine_stop_failed operation=controlled_restart',
      );
    }
  }

  Future<void> _runPropertyWrite(
    PlaybackEngine boundEngine,
    PlaybackEngineOperation operation,
  ) {
    if (!identical(engine, boundEngine) || _engineDisposed || _retiring) {
      return Future<void>.value();
    }
    return _operationCoordinator.runTrackedNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: operation,
      barrierTimeout: propertyWriteTimeout,
    );
  }

  Future<void> _restoreEnginePresentation(int token) async {
    final boundEngine = engine;
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.setRate(_desiredPlaybackRate),
    );
    _throwIfStale(token);
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.setAudioDelay(_desiredAudioDelay),
    );
    _throwIfStale(token);
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.setSubtitleDelay(_desiredSubtitleDelay),
    );
    _throwIfStale(token);
    final style = _desiredSubtitleStyle;
    if (style == null) return;
    await _runPropertyWrite(
      boundEngine,
      () => boundEngine.configureSubtitleStyle(
        fontSize: style.fontSize,
        color: style.color,
        outlineColor: style.outlineColor,
        position: style.position,
      ),
    );
    _throwIfStale(token);
  }

  void _recordExecutedSeek() {
    _lastExecutedSeekAt = _clock();
    _stablePlaybackSince = null;
    _lastStabilityPosition = _state.position;
    _seekBecameStable = false;
  }

  void _updateReadAheadAnchorAfterExecutedSeek(Duration committedPosition) {
    final profile = _state.cacheProfile;
    if (profile == null ||
        profile.readAheadStrategy != PlaybackCacheReadAheadStrategy.mediaEnd) {
      return;
    }
    final candidate = committedPosition < Duration.zero
        ? Duration.zero
        : committedPosition;
    if (candidate >= profile.readAheadAnchor) return;
    final updatedProfile = profile.copyWith(readAheadAnchor: candidate);
    _setState(_state.copyWith(cacheProfile: updatedProfile));
    _cacheCoordinator?.lowerReadAheadAnchor(candidate);
  }

  void _injectApprovedSeekFailureIfPending() {
    if (!_testSeekFailurePending || _state.phase != PlaybackPhase.ready) return;
    _testSeekFailurePending = false;
    _handleEngineError('partial file');
  }

  void _updateStablePlayback(Duration position) {
    final lastSeek = _lastExecutedSeekAt;
    if (lastSeek == null || _seekBecameStable) {
      _lastStabilityPosition = position;
      return;
    }
    final now = _clock();
    if (now.difference(lastSeek) > recoveryPolicy.seekRecoveryWindow ||
        !_state.isPlaying ||
        _state.isBuffering) {
      _stablePlaybackSince = null;
      _lastStabilityPosition = position;
      return;
    }
    final previous = _lastStabilityPosition;
    _lastStabilityPosition = position;
    if (previous == null || position <= previous) {
      _stablePlaybackSince = null;
      return;
    }
    final stableSince = _stablePlaybackSince ?? now;
    _stablePlaybackSince = stableSince;
    if (now.difference(stableSince) >= recoveryPolicy.stablePlaybackWindow) {
      _seekBecameStable = true;
    }
  }

  bool _requestRuntimeRecovery(String rawFailure) {
    final fingerprint = _approvedRecoveryFingerprint(rawFailure);
    if (fingerprint == null) return false;
    if (_state.phase == PlaybackPhase.recoveryPending ||
        _state.phase == PlaybackPhase.recovering) {
      return true;
    }
    if (_state.phase != PlaybackPhase.ready || _disposed || _shuttingDown) {
      return false;
    }
    final plan = _state.plan;
    final lastSeek = _lastExecutedSeekAt;
    if (plan == null ||
        plan.transportKind != PlaybackTransportKind.progressiveHttp ||
        lastSeek == null ||
        _seekBecameStable ||
        session.hasUsed(
          AutomaticPlaybackOpenReason.runtimeSameMethodRecovery,
        )) {
      return false;
    }
    final now = _clock();
    if (now.difference(lastSeek) > recoveryPolicy.seekRecoveryWindow) {
      return false;
    }
    final lastFingerprint = _recoveryFingerprintLastSeen[fingerprint];
    if (lastFingerprint != null &&
        now.difference(lastFingerprint) <
            recoveryPolicy.fingerprintDedupeWindow) {
      return true;
    }
    _recoveryFingerprintLastSeen[fingerprint] = now;
    _pendingRecoveryFingerprint = fingerprint;
    _stablePlaybackSince = null;
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.recoveryPending,
        isBuffering: true,
        statusMessage: '正在恢复播放…',
        clearError: true,
      ),
    );
    _diagnostics.seekRecovery(
      PlaybackRecoveryDiagnosticEvent.pending,
      fingerprint: fingerprint,
    );
    if (!_lifecycleSuspended) _scheduleRuntimeRecovery();
    return true;
  }

  void _scheduleRuntimeRecovery() {
    if (_runtimeRecoveryScheduled ||
        _pendingRecoveryFingerprint == null ||
        _disposed ||
        _shuttingDown ||
        _lifecycleSuspended) {
      return;
    }
    _runtimeRecoveryScheduled = true;
    final fingerprint = _pendingRecoveryFingerprint!;
    unawaited(
      _operationCoordinator
          .runControlOperation(
            priority: PlaybackControlOperationPriority.runtimeRecovery,
            operation: (lease) async {
              try {
                await _performRuntimeRecovery(lease, fingerprint).timeout(
                  recoveryPolicy.recoveryAttemptTimeout,
                  onTimeout: () {
                    if (!lease.isCurrent || _disposed || _shuttingDown) return;
                    _invalidateCurrentControllerOperation();
                    _setRuntimeRecoveryFailed(fingerprint);
                  },
                );
              } catch (_) {
                if (lease.isCurrent && !_disposed && !_shuttingDown) {
                  _invalidateCurrentControllerOperation();
                  _setRuntimeRecoveryFailed(fingerprint);
                }
              }
            },
          )
          .whenComplete(() => _runtimeRecoveryScheduled = false),
    );
  }

  Future<void> _performRuntimeRecovery(
    PlaybackControlOperationLease lease,
    PlaybackRecoveryFingerprint fingerprint,
  ) async {
    if (_pendingRecoveryFingerprint != fingerprint ||
        _disposed ||
        _shuttingDown ||
        _lifecycleSuspended ||
        !lease.isCurrent) {
      _recordRuntimeRecoveryCancelled();
      return;
    }
    _pendingRecoveryFingerprint = null;
    final plan = _state.plan;
    if (plan == null ||
        !_tryReserveAutomaticOpen(
          AutomaticPlaybackOpenReason.runtimeSameMethodRecovery,
        )) {
      _setRuntimeRecoveryFailed(fingerprint);
      return;
    }
    final position = _state.requestedPosition ?? _state.position;
    final wasPlaying = _desiredPlaying;
    final wasTranscoding = plan.method == PlayMethod.transcode;
    _advanceGeneration();
    _progressTimer?.cancel();
    _cancelCacheCoordinator();
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.recovering,
        isBuffering: true,
        statusMessage: '正在恢复播放…',
        clearError: true,
      ),
    );
    _diagnostics.seekRecovery(
      PlaybackRecoveryDiagnosticEvent.started,
      fingerprint: fingerprint,
    );
    await _stopForControlledRestart(position);
    if (!lease.isCurrent || _disposed || _shuttingDown) {
      _recordRuntimeRecoveryCancelled();
      return;
    }
    await _cleanupCacheSessionSafely();
    if (_disposed || _shuttingDown || _lifecycleSuspended || !lease.isCurrent) {
      _recordRuntimeRecoveryCancelled();
      return;
    }
    await _startPlayback(
      resumePosition: position,
      playAfterReady: wasPlaying,
      forceTranscodeInitially: wasTranscoding,
      transcodeFallbackReason:
          AutomaticPlaybackOpenReason.runtimeTranscodeRecovery,
      openingStatusMessage: '正在恢复播放…',
    );
    if (_disposed || _shuttingDown || !lease.isCurrent) {
      _recordRuntimeRecoveryCancelled();
      return;
    }
    if (_state.phase == PlaybackPhase.ready) {
      _diagnostics.seekRecovery(
        PlaybackRecoveryDiagnosticEvent.succeeded,
        fingerprint: fingerprint,
      );
      _cacheEvidence.recordRuntimeRecovery(
        PlaybackCacheRuntimeRecovery.succeeded,
      );
      return;
    }
    _setRuntimeRecoveryFailed(fingerprint);
  }

  void _setRuntimeRecoveryFailed(PlaybackRecoveryFingerprint? fingerprint) {
    if (_disposed || _shuttingDown) return;
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.failed,
        isBuffering: false,
        errorMessage: '播放连接异常，自动恢复失败，请返回后重试',
        clearStatus: true,
      ),
    );
    _diagnostics.seekRecovery(
      PlaybackRecoveryDiagnosticEvent.failed,
      fingerprint: fingerprint,
    );
    _cacheEvidence.recordRuntimeRecovery(PlaybackCacheRuntimeRecovery.failed);
  }

  void _recordRuntimeRecoveryCancelled() {
    if (_cacheEvidence.isFinalized) return;
    _cacheEvidence.recordRuntimeRecovery(
      PlaybackCacheRuntimeRecovery.cancelled,
    );
  }

  static PlaybackRecoveryFingerprint? _approvedRecoveryFingerprint(
    String failure,
  ) {
    final normalized = failure.toLowerCase();
    if (normalized.contains('seek failed')) {
      return PlaybackRecoveryFingerprint.seekFailed;
    }
    if (normalized.contains('partial file')) {
      return PlaybackRecoveryFingerprint.partialFile;
    }
    if (normalized.contains('input/output error') ||
        normalized.contains('i/o error')) {
      return PlaybackRecoveryFingerprint.inputOutputError;
    }
    if (normalized.contains('error reading packet')) {
      return PlaybackRecoveryFingerprint.packetReadError;
    }
    return null;
  }

  void _createOperationCoordinator() {
    _operationCoordinator = PlaybackOperationCoordinator(
      sessionId: session.id,
      seekEngine: engine.seek,
      clampTarget: _clampToDuration,
      onRequestedPositionChanged: _handleRequestedPositionChanged,
      onControlOperationInvalidated: _invalidateCurrentControllerOperation,
      isSessionCurrent: (candidate) =>
          identical(candidate, session.id) && !_disposed && !_shuttingDown,
      seekCallTimeout: seekCallTimeout,
      seekSettleTimeout: resumeVerificationTimeout,
      nativeOperationTimeouts: PlaybackNativeOperationTimeouts(
        open: openTimeout,
        play: playPauseTimeout,
        pause: playPauseTimeout,
        seek: seekCallTimeout,
        stop: stopTimeout,
        propertyWrite: propertyWriteTimeout,
        lifecycleQuiesce: lifecycleQuiesceTimeout,
        retirementQuiesce: retirementQuiesceTimeout,
        dispose: disposeTimeout,
        shutdownBarrier: shutdownBarrierTimeout,
      ),
    );
  }

  void _invalidateCurrentControllerOperation() {
    _advanceGeneration();
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _PlaybackCancelled());
    }
  }

  static bool _isStartupPhase(PlaybackPhase phase) =>
      phase == PlaybackPhase.opening ||
      phase == PlaybackPhase.waitingForReady ||
      phase == PlaybackPhase.retryingWithTranscode;

  static bool _isFatalStartupLog(String lower) {
    if (lower.contains('failed to resolve hostname') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('unknown host')) {
      return true;
    }
    if (lower.contains('inflate return value') &&
        lower.contains('incorrect header check')) {
      return true;
    }
    if (lower.contains('failed to open http://') ||
        lower.contains('failed to open https://')) {
      return true;
    }
    return lower.contains('http error 4') ||
        lower.contains('http error 5') ||
        lower.contains('server returned 4') ||
        lower.contains('server returned 5');
  }

  static String _engineLogFingerprint(String lower) {
    if (lower.contains('inflate return value')) return 'http-inflate';
    if (lower.contains('log message buffer overflow')) return 'log-overflow';
    if (lower.contains('failed to resolve hostname')) return 'dns-resolution';
    if (lower.contains('failed to open http')) return 'http-open';
    return 'other';
  }

  static String _engineDiagnosticFingerprint(String value) =>
      _approvedRecoveryFingerprint(value)?.code ??
      _engineLogFingerprint(value.toLowerCase());

  bool _isCurrentEngine(int token, PlaybackEngine boundEngine) =>
      _isCurrent(token) && identical(engine, boundEngine);

  void _throwIfCurrentEngine(int token, PlaybackEngine boundEngine) {
    if (_isCurrentEngine(token, boundEngine)) return;
    _diagnostics.subtitleApplySkippedStale(generation: token);
    throw const _PlaybackCancelled();
  }

  bool _isAudioApplied(
    int streamIndex,
    int token,
    PlaybackEngine boundEngine,
  ) =>
      _state.audioSelectionStatus == AudioSelectionStatus.applied &&
      _state.appliedAudioStreamIndex == streamIndex &&
      _isCurrentEngine(token, boundEngine) &&
      identical(_appliedAudioEngine, boundEngine);

  bool _isSubtitleApplied(
    SubtitleSelection selection,
    int token,
    PlaybackEngine boundEngine,
  ) {
    if (!_isCurrentEngine(token, boundEngine) ||
        !identical(_appliedSubtitleEngine, boundEngine) ||
        _state.subtitleApplicationGeneration != token) {
      return false;
    }
    if (selection.isDisabled) {
      return _state.subtitleSelectionStatus == SubtitleSelectionStatus.disabled;
    }
    if (selection.source == SubtitleSelectionSource.explicit) {
      return (_state.subtitleSelectionStatus ==
                  SubtitleSelectionStatus.appliedEmbedded ||
              _state.subtitleSelectionStatus ==
                  SubtitleSelectionStatus.appliedExternal ||
              _state.subtitleSelectionStatus ==
                  SubtitleSelectionStatus.appliedServer) &&
          _state.appliedSubtitleStreamIndex == selection.streamIndex;
    }
    return _state.subtitleSelectionStatus ==
            SubtitleSelectionStatus.appliedNone ||
        _state.subtitleSelectionStatus ==
            SubtitleSelectionStatus.appliedEmbedded ||
        _state.subtitleSelectionStatus ==
            SubtitleSelectionStatus.appliedExternal ||
        _state.subtitleSelectionStatus == SubtitleSelectionStatus.appliedServer;
  }

  bool _isCurrentSubtitleSelection(
    SubtitleSelection selection,
    int token,
    PlaybackEngine boundEngine,
  ) =>
      _isCurrentEngine(token, boundEngine) &&
      _desiredSubtitleSelection == selection;

  void _throwIfCurrentSubtitleSelection(
    SubtitleSelection selection,
    int token,
    PlaybackEngine boundEngine,
  ) {
    if (_isCurrentSubtitleSelection(selection, token, boundEngine)) return;
    _diagnostics.subtitleApplySkippedStale(generation: token);
    throw const _PlaybackCancelled();
  }

  void _markAudioApplied(
    int streamIndex,
    int token,
    PlaybackEngine boundEngine,
  ) {
    if (!_isCurrentEngine(token, boundEngine)) return;
    _appliedAudioEngine = boundEngine;
    _setState(
      _state.copyWith(
        audioSelectionStatus: AudioSelectionStatus.applied,
        appliedAudioStreamIndex: streamIndex,
      ),
    );
  }

  void _markSubtitleApplied({
    required SubtitleSelection selection,
    required SubtitleSelectionStatus status,
    required AppliedSubtitleKind kind,
    required int? streamIndex,
    required int token,
    required PlaybackEngine boundEngine,
  }) {
    if (!_isCurrentSubtitleSelection(selection, token, boundEngine)) return;
    _appliedSubtitleEngine = boundEngine;
    _setState(
      _state.copyWith(
        desiredSubtitleSelection: selection,
        subtitleSelectionStatus: status,
        appliedSubtitleKind: kind,
        appliedSubtitleStreamIndex: streamIndex,
        clearAppliedSubtitleStreamIndex: streamIndex == null,
        subtitleApplicationGeneration: token,
        clearSubtitleSelectionError: true,
      ),
    );
  }

  void _markSubtitleFailed({
    required SubtitleSelection selection,
    required int token,
    required PlaybackEngine boundEngine,
    required Object error,
    int? streamIndex,
  }) {
    if (!_isCurrentSubtitleSelection(selection, token, boundEngine)) {
      _diagnostics.subtitleApplySkippedStale(generation: token);
      return;
    }
    _appliedSubtitleEngine = null;
    _setState(
      _state.copyWith(
        subtitleSelectionStatus: SubtitleSelectionStatus.failed,
        appliedSubtitleKind: AppliedSubtitleKind.none,
        clearAppliedSubtitleStreamIndex: true,
        subtitleApplicationGeneration: token,
        subtitleSelectionError: '字幕加载失败，请重试',
      ),
    );
    _diagnostics.subtitleApplyFailed(
      selectionSource: selection.source.name,
      subtitleKind: 'embedded_or_external',
      streamIndex: streamIndex ?? selection.streamIndex,
      generation: token,
      error: error,
    );
  }

  void _markSubtitleWaitingForTracks({
    required SubtitleSelection selection,
    required int token,
    required PlaybackEngine boundEngine,
  }) {
    if (!_isCurrentSubtitleSelection(selection, token, boundEngine)) return;
    _appliedSubtitleEngine = null;
    _setState(
      _state.copyWith(
        desiredSubtitleSelection: selection,
        subtitleSelectionStatus: SubtitleSelectionStatus.waitingForTracks,
        appliedSubtitleKind: AppliedSubtitleKind.none,
        clearAppliedSubtitleStreamIndex: true,
        subtitleApplicationGeneration: token,
        clearSubtitleSelectionError: true,
      ),
    );
  }

  void _markServerSubtitleApplied(
    PlaybackPlan plan,
    int token,
    PlaybackEngine boundEngine,
  ) {
    final selection = _desiredSubtitleSelection;
    if (!_isCurrentSubtitleSelection(selection, token, boundEngine)) {
      _diagnostics.subtitleApplySkippedStale(generation: token);
      return;
    }
    if (selection.isDisabled || plan.subtitleDisabled) {
      _markSubtitleApplied(
        selection: selection,
        status: SubtitleSelectionStatus.disabled,
        kind: AppliedSubtitleKind.none,
        streamIndex: null,
        token: token,
        boundEngine: boundEngine,
      );
      _diagnostics.subtitleDisabled(generation: token);
      return;
    }
    final streamIndex = plan.subtitleStreamIndex;
    if (selection.source == SubtitleSelectionSource.explicit &&
        streamIndex != selection.streamIndex) {
      _markSubtitleFailed(
        selection: selection,
        token: token,
        boundEngine: boundEngine,
        streamIndex: streamIndex,
        error: StateError('Server did not resolve the requested subtitle'),
      );
      return;
    }
    _markSubtitleApplied(
      selection: selection,
      status: streamIndex == null
          ? SubtitleSelectionStatus.appliedNone
          : SubtitleSelectionStatus.appliedServer,
      kind: streamIndex == null
          ? AppliedSubtitleKind.none
          : AppliedSubtitleKind.server,
      streamIndex: streamIndex,
      token: token,
      boundEngine: boundEngine,
    );
    _diagnostics.subtitleApplied(
      selectionSource: selection.source.name,
      subtitleKind: streamIndex == null ? 'none' : 'server',
      streamIndex: streamIndex,
      generation: token,
    );
  }

  void _updateReporterSubtitlePlan(
    PlaybackPlan plan,
    SubtitleSelection selection,
    int? streamIndex,
  ) {
    final updated = selection.isDisabled
        ? plan.copyWith(clearSubtitleStreamIndex: true, subtitleDisabled: true)
        : plan.copyWith(
            clearSubtitleStreamIndex: streamIndex == null,
            subtitleStreamIndex: streamIndex,
            subtitleDisabled: false,
          );
    reporter.updatePlan(updated);
  }

  void _markExternalSubtitleApplied({
    required PlaybackPlan plan,
    required SubtitleSelection selection,
    required int streamIndex,
    required int token,
    required PlaybackEngine boundEngine,
  }) {
    _markSubtitleApplied(
      selection: selection,
      status: SubtitleSelectionStatus.appliedExternal,
      kind: AppliedSubtitleKind.external,
      streamIndex: streamIndex,
      token: token,
      boundEngine: boundEngine,
    );
    if (!_isSubtitleApplied(selection, token, boundEngine)) return;
    _diagnostics.subtitleApplied(
      selectionSource: selection.source.name,
      subtitleKind: 'external',
      streamIndex: streamIndex,
      generation: token,
    );
    _updateReporterSubtitlePlan(plan, selection, streamIndex);
  }

  Future<void> _applySelectedDirectPlayTracks(
    PlaybackPlan plan,
    int token,
  ) async {
    final boundEngine = engine;
    final audioIndex = _selectedAudioStreamIndex ?? plan.audioStreamIndex;
    if (audioIndex != null) {
      final tracks = await _waitForTracks(
        audio: true,
        token: token,
        boundEngine: boundEngine,
      );
      _throwIfCurrentEngine(token, boundEngine);
      final track = _trackMapper.findByIndex(plan, 'audio', audioIndex);
      final engineId = track == null
          ? null
          : _trackMapper.engineTrackId(track, tracks);
      if (engineId == null) {
        throw StateError('Unable to map Emby audio track $audioIndex');
      }
      await _runPropertyWrite(
        boundEngine,
        () => boundEngine.selectAudioTrack(engineId),
      );
      _throwIfCurrentEngine(token, boundEngine);
      _markAudioApplied(audioIndex, token, boundEngine);
    } else if (_isCurrent(token)) {
      _setState(
        _state.copyWith(audioSelectionStatus: AudioSelectionStatus.applied),
      );
    }

    await _applySubtitleSelection(plan, token, boundEngine);
  }

  Future<void> _applySubtitleSelection(
    PlaybackPlan plan,
    int token,
    PlaybackEngine boundEngine,
  ) async {
    final selection = _desiredSubtitleSelection;
    final existing = _subtitleApplication;
    if (existing != null &&
        identical(_subtitleApplicationEngine, boundEngine) &&
        identical(_subtitleApplicationSelection, selection) &&
        _subtitleApplicationGeneration == token) {
      await existing;
      return;
    }

    final operation = _applySubtitleSelectionInternal(
      plan,
      selection,
      token,
      boundEngine,
    );
    _subtitleApplication = operation;
    _subtitleApplicationEngine = boundEngine;
    _subtitleApplicationSelection = selection;
    _subtitleApplicationGeneration = token;
    try {
      await operation;
    } finally {
      if (identical(_subtitleApplication, operation)) {
        _subtitleApplication = null;
        _subtitleApplicationEngine = null;
        _subtitleApplicationSelection = null;
        _subtitleApplicationGeneration = null;
      }
    }
  }

  Future<void> _applySubtitleSelectionInternal(
    PlaybackPlan plan,
    SubtitleSelection selection,
    int token,
    PlaybackEngine boundEngine,
  ) async {
    int? resolvedSubtitleIndex;
    try {
      _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
      resolvedSubtitleIndex = selection.isDisabled
          ? null
          : selection.source == SubtitleSelectionSource.explicit
          ? selection.streamIndex
          : plan.subtitleStreamIndex;
      _diagnostics.subtitleApplyRequested(
        selectionSource: selection.source.name,
        subtitleKind: selection.isDisabled ? 'none' : 'embedded_or_external',
        streamIndex: resolvedSubtitleIndex,
        generation: token,
      );

      if (selection.isDisabled) {
        await _runPropertyWrite(
          boundEngine,
          () => boundEngine.selectSubtitleTrack(null),
        );
        _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
        _markSubtitleApplied(
          selection: selection,
          status: SubtitleSelectionStatus.disabled,
          kind: AppliedSubtitleKind.none,
          streamIndex: null,
          token: token,
          boundEngine: boundEngine,
        );
        _diagnostics.subtitleDisabled(generation: token);
        _updateReporterSubtitlePlan(plan, selection, null);
        return;
      }

      if (resolvedSubtitleIndex == null) {
        _markSubtitleApplied(
          selection: selection,
          status: SubtitleSelectionStatus.appliedNone,
          kind: AppliedSubtitleKind.none,
          streamIndex: null,
          token: token,
          boundEngine: boundEngine,
        );
        _diagnostics.subtitleApplied(
          selectionSource: selection.source.name,
          subtitleKind: 'none',
          streamIndex: null,
          generation: token,
        );
        _updateReporterSubtitlePlan(plan, selection, null);
        return;
      }

      final track = _trackMapper.findByIndex(
        plan,
        'subtitle',
        resolvedSubtitleIndex,
      );
      if (track?.isExternal == true && track?.deliveryUrl != null) {
        _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
        final externalLoad = boundEngine.loadExternalSubtitle(
          resolver.resolveExternalUrl(track!.deliveryUrl!),
          title: track.title,
          language: track.language,
        );
        try {
          await externalLoad.timeout(
            trackWaitTimeout,
            onTimeout: () {
              _diagnostics.operationTimeout(
                PlaybackOperationTimeoutKind.subtitleTrackWait,
              );
              throw const _InitialSubtitleWaitTimedOut();
            },
          );
        } on _InitialSubtitleWaitTimedOut {
          _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
          _markSubtitleWaitingForTracks(
            selection: selection,
            token: token,
            boundEngine: boundEngine,
          );
          _scheduleLateExternalSubtitle(
            plan: plan,
            selection: selection,
            streamIndex: resolvedSubtitleIndex,
            token: token,
            boundEngine: boundEngine,
            externalLoad: externalLoad,
          );
          return;
        }
        _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
        _markExternalSubtitleApplied(
          plan: plan,
          selection: selection,
          streamIndex: resolvedSubtitleIndex,
          token: token,
          boundEngine: boundEngine,
        );
        return;
      }

      late final List<EngineTrack> tracks;
      try {
        tracks = await _waitForTracks(
          audio: false,
          token: token,
          boundEngine: boundEngine,
        );
      } on TimeoutException {
        _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
        _markSubtitleWaitingForTracks(
          selection: selection,
          token: token,
          boundEngine: boundEngine,
        );
        _scheduleLateEmbeddedSubtitle(
          plan: plan,
          selection: selection,
          streamIndex: resolvedSubtitleIndex,
          token: token,
          boundEngine: boundEngine,
        );
        return;
      }
      _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
      final engineId = track == null
          ? null
          : _trackMapper.engineTrackId(track, tracks);
      if (engineId == null) {
        _diagnostics.subtitleMappingFailed(
          selectionSource: selection.source.name,
          subtitleKind: 'embedded',
          streamIndex: resolvedSubtitleIndex,
          generation: token,
        );
        throw StateError('Unable to map Emby subtitle track');
      }
      await _runPropertyWrite(
        boundEngine,
        () => boundEngine.selectSubtitleTrack(engineId),
      );
      _throwIfCurrentSubtitleSelection(selection, token, boundEngine);
      _markSubtitleApplied(
        selection: selection,
        status: SubtitleSelectionStatus.appliedEmbedded,
        kind: AppliedSubtitleKind.embedded,
        streamIndex: resolvedSubtitleIndex,
        token: token,
        boundEngine: boundEngine,
      );
      _diagnostics.subtitleApplied(
        selectionSource: selection.source.name,
        subtitleKind: 'embedded',
        streamIndex: resolvedSubtitleIndex,
        generation: token,
      );
      _updateReporterSubtitlePlan(plan, selection, resolvedSubtitleIndex);
    } on _PlaybackCancelled {
      _diagnostics.subtitleApplyCancelled(generation: token);
      rethrow;
    } catch (error) {
      _markSubtitleFailed(
        selection: selection,
        token: token,
        boundEngine: boundEngine,
        streamIndex: resolvedSubtitleIndex,
        error: error,
      );
    }
  }

  void _scheduleLateEmbeddedSubtitle({
    required PlaybackPlan plan,
    required SubtitleSelection selection,
    required int streamIndex,
    required int token,
    required PlaybackEngine boundEngine,
  }) {
    final task = _beginLateSubtitleTask(
      plan: plan,
      selection: selection,
      resolvedStreamIndex: streamIndex,
      token: token,
      boundEngine: boundEngine,
    );
    _observeLateSubtitleTask(
      task,
      _continueLateEmbeddedSubtitle(
        task: task,
        plan: plan,
        selection: selection,
        token: token,
        boundEngine: boundEngine,
      ),
    );
  }

  void _scheduleLateExternalSubtitle({
    required PlaybackPlan plan,
    required SubtitleSelection selection,
    required int streamIndex,
    required int token,
    required PlaybackEngine boundEngine,
    required Future<void> externalLoad,
  }) {
    final task = _beginLateSubtitleTask(
      plan: plan,
      selection: selection,
      resolvedStreamIndex: streamIndex,
      token: token,
      boundEngine: boundEngine,
    );
    _observeLateSubtitleTask(
      task,
      _continueLateExternalSubtitle(
        task: task,
        plan: plan,
        selection: selection,
        streamIndex: streamIndex,
        token: token,
        boundEngine: boundEngine,
        externalLoad: externalLoad,
      ),
    );
  }

  _LateSubtitleTask _beginLateSubtitleTask({
    required PlaybackPlan plan,
    required SubtitleSelection selection,
    required int resolvedStreamIndex,
    required int token,
    required PlaybackEngine boundEngine,
  }) {
    _cancelLateSubtitleTask();
    final task = _LateSubtitleTask(
      identity: _LateSubtitleTaskIdentity(
        itemId: item.id,
        playbackItemSessionId: session.id,
        playbackSessionId: plan.playSessionId,
        controllerGeneration: token,
        engineIdentity: boundEngine,
        selection: selection,
        resolvedStreamIndex: resolvedStreamIndex,
      ),
    );
    _lateSubtitleTask = task;
    return task;
  }

  void _observeLateSubtitleTask(
    _LateSubtitleTask task,
    Future<void> operation,
  ) {
    unawaited(
      operation.whenComplete(() {
        if (identical(_lateSubtitleTask, task)) _lateSubtitleTask = null;
      }),
    );
  }

  Future<void> _continueLateEmbeddedSubtitle({
    required _LateSubtitleTask task,
    required PlaybackPlan plan,
    required SubtitleSelection selection,
    required int token,
    required PlaybackEngine boundEngine,
  }) async {
    try {
      await _waitForTracks(
        audio: false,
        token: token,
        boundEngine: boundEngine,
        timeout: lateSubtitleTrackWaitTimeout,
        cancellationSignal: task.cancellation,
      );
      if (!_isCurrentLateSubtitleTask(task)) return;
      await Future<void>.delayed(Duration.zero);
      if (!_isCurrentLateSubtitleTask(task)) return;
      await _applySubtitleSelection(plan, token, boundEngine);
    } on _PlaybackCancelled {
      return;
    } on TimeoutException catch (error) {
      _markLateSubtitleFailed(task, error);
    } catch (error) {
      _markLateSubtitleFailed(task, error);
    }
  }

  Future<void> _continueLateExternalSubtitle({
    required _LateSubtitleTask task,
    required PlaybackPlan plan,
    required SubtitleSelection selection,
    required int streamIndex,
    required int token,
    required PlaybackEngine boundEngine,
    required Future<void> externalLoad,
  }) async {
    try {
      await Future.any<void>([
        externalLoad,
        task.cancellation.future.then<void>((_) {
          throw const _PlaybackCancelled();
        }),
      ]).timeout(
        lateSubtitleTrackWaitTimeout,
        onTimeout: () {
          _diagnostics.operationTimeout(
            PlaybackOperationTimeoutKind.subtitleTrackWait,
          );
          throw TimeoutException(
            'External subtitle did not arrive within the remaining '
            '$lateSubtitleTrackWaitTimeout',
          );
        },
      );
      if (!_isCurrentLateSubtitleTask(task)) return;
      _markExternalSubtitleApplied(
        plan: plan,
        selection: selection,
        streamIndex: streamIndex,
        token: token,
        boundEngine: boundEngine,
      );
    } on _PlaybackCancelled {
      return;
    } on TimeoutException catch (error) {
      _markLateSubtitleFailed(task, error);
    } catch (error) {
      _markLateSubtitleFailed(task, error);
    }
  }

  void _markLateSubtitleFailed(_LateSubtitleTask task, Object error) {
    if (!_isCurrentLateSubtitleTask(task)) return;
    final identity = task.identity;
    _markSubtitleFailed(
      selection: identity.selection,
      token: identity.controllerGeneration,
      boundEngine: identity.engineIdentity,
      streamIndex: identity.resolvedStreamIndex,
      error: error,
    );
  }

  bool _isCurrentLateSubtitleTask(_LateSubtitleTask task) {
    final identity = task.identity;
    return identical(_lateSubtitleTask, task) &&
        item.id == identity.itemId &&
        identical(session.id, identity.playbackItemSessionId) &&
        _state.plan?.playSessionId == identity.playbackSessionId &&
        _generation == identity.controllerGeneration &&
        identical(engine, identity.engineIdentity) &&
        _desiredSubtitleSelection == identity.selection &&
        _isCurrent(identity.controllerGeneration);
  }

  void _cancelLateSubtitleTask() {
    final task = _lateSubtitleTask;
    _lateSubtitleTask = null;
    task?.cancel();
  }

  Future<List<EngineTrack>> _waitForTracks({
    required bool audio,
    required int token,
    required PlaybackEngine boundEngine,
    Duration? timeout,
    Completer<void>? cancellationSignal,
  }) async {
    final existing = audio ? _state.audioTracks : _state.subtitleTracks;
    if (existing.isNotEmpty) return existing;
    _throwIfCurrentEngine(token, boundEngine);

    final completer = Completer<List<EngineTrack>>();
    final cancellation = cancellationSignal ?? Completer<void>();
    _subtitleTrackWaitCancellations.add(cancellation);
    final stream = audio
        ? boundEngine.audioTracksStream
        : boundEngine.subtitleTracksStream;
    late final StreamSubscription<List<EngineTrack>> subscription;
    subscription = stream.listen(
      (tracks) {
        if (!_isCurrentEngine(token, boundEngine)) {
          if (!completer.isCompleted) {
            completer.completeError(const _PlaybackCancelled());
          }
          return;
        }
        if (tracks.isNotEmpty && !completer.isCompleted) {
          completer.complete(List<EngineTrack>.unmodifiable(tracks));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    try {
      return await Future.any<List<EngineTrack>>([
        completer.future,
        cancellation.future.then<List<EngineTrack>>((_) {
          throw const _PlaybackCancelled();
        }),
      ]).timeout(
        timeout ?? trackWaitTimeout,
        onTimeout: () {
          _diagnostics.operationTimeout(
            PlaybackOperationTimeoutKind.subtitleTrackWait,
          );
          throw TimeoutException(
            'Subtitle track list did not arrive within '
            '${timeout ?? trackWaitTimeout}',
          );
        },
      );
    } finally {
      _subtitleTrackWaitCancellations.remove(cancellation);
      await subscription.cancel();
    }
  }

  void _cancelSubtitleTrackWaits() {
    final waits = List<Completer<void>>.of(_subtitleTrackWaitCancellations);
    for (final wait in waits) {
      if (!wait.isCompleted) wait.complete();
    }
  }

  Future<void> _awaitSubtitleApplication(Future<void> operation) async {
    try {
      await operation.timeout(disposeTimeout);
    } on TimeoutException {
      _diagnostics.operationTimeout(
        PlaybackOperationTimeoutKind.subtitleApplication,
      );
      unawaited(
        operation.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {},
        ),
      );
    } catch (_) {
      // Stale and already-recorded subtitle failures must not block teardown.
    }
  }

  void _prepareReadyWait() {
    _sawBuffering = false;
    _startupFailureSignaled = false;
    final completer = Completer<void>();
    _readyCompleter = completer;
    unawaited(
      completer.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _discardReadyWaitAfterStartupError() {
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _readyCompleter = null;
  }

  void _markReady() {
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _waitUntilReady(int token) async {
    _throwIfStale(token);
    final completer = _readyCompleter;
    if (completer == null) {
      throw StateError('Playback ready wait was not initialized');
    }
    await completer.future.timeout(
      readyTimeout,
      onTimeout: () => throw TimeoutException(
        'Media did not become ready within ${readyTimeout.inSeconds}s',
      ),
    );
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(
      progressInterval,
      (_) => unawaited(_reportProgress()),
    );
  }

  Future<void> _reportProgress({bool? isPaused}) async {
    try {
      await reporter.reportProgress(
        position: _state.position,
        isPaused: isPaused ?? !_state.isPlaying,
      );
    } catch (error) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_progress_report_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Duration _resumePositionForPlan(PlaybackPlan plan, Duration? requested) {
    final candidate =
        requested ??
        (item.resumePosition > const Duration(seconds: 10)
            ? item.resumePosition
            : Duration.zero);
    final nonnegative = candidate < Duration.zero ? Duration.zero : candidate;
    final duration = plan.duration;
    if (duration != null &&
        duration > Duration.zero &&
        nonnegative > duration) {
      return duration;
    }
    return nonnegative;
  }

  Duration _clampToDuration(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    final duration = _state.duration;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  bool _isCurrent(int token) =>
      !_disposed && !_shuttingDown && !_retiring && token == _generation;

  bool _canResumeLifecycle(int revision) =>
      !_retiring &&
      !_shuttingDown &&
      !_disposed &&
      !_engineDisposed &&
      _lifecycleSuspended &&
      revision == _lifecycleQuiescenceRevision;

  int _advanceGeneration() {
    _generation++;
    _cancelLateSubtitleTask();
    _cancelSubtitleTrackWaits();
    return _generation;
  }

  void _throwIfStale(int token) {
    if (!_isCurrent(token)) throw const _PlaybackCancelled();
  }

  void _setState(PlaybackState next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  Future<void> _cancelSubscriptions() async {
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }

  Future<bool> _disposeEngine({Duration? timeout}) async {
    if (_engineDisposed) {
      return _retirementState == PlaybackRetirementState.closed;
    }
    _engineDisposed = true;
    try {
      await _withDeadline(
        engine.dispose(),
        _minimumDuration(disposeTimeout, timeout),
        PlaybackOperationTimeoutKind.engineDispose,
      );
      return true;
    } catch (error) {
      _markEngineDisposalUnconfirmed();
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_engine_dispose_failed '
            'errorType=${error.runtimeType}',
      );
      return false;
    }
  }

  Future<void> _stopEngine({Duration? timeout}) async {
    if (_engineDisposed) return;
    try {
      await _withDeadline(
        engine.stop(),
        _minimumDuration(stopTimeout, timeout),
        PlaybackOperationTimeoutKind.engineStop,
      );
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_engine_stop_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  void _markEngineDisposalUnconfirmed() {
    _retirementState = PlaybackRetirementState.quarantined;
    if (_engineDisposalUnconfirmedReported) return;
    _engineDisposalUnconfirmedReported = true;
    onEngineDisposalUnconfirmed?.call();
  }

  static Duration _minimumDuration(Duration configured, Duration? remaining) {
    if (remaining == null || configured <= remaining) return configured;
    return remaining;
  }

  Future<void> _stopReporterSafely() async {
    try {
      await _withDeadline(
        reporter.stop(_state.position),
        reporterTimeout,
        PlaybackOperationTimeoutKind.reporterStop,
      );
    } catch (error) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_reporter_stop_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Future<void> _cleanupCacheSessionSafely() async {
    final cacheSession = _cacheSession;
    _cacheSession = null;
    if (cacheSession == null) {
      if (!_cacheEvidence.isFinalized) {
        _cacheEvidence.recordCleanup(PlaybackCacheCleanupResult.notApplicable);
      }
      return;
    }
    try {
      await _withDeadline(
        cacheStorage.cleanupSession(cacheSession),
        cacheCleanupTimeout,
        PlaybackOperationTimeoutKind.cacheCleanup,
      );
      if (!_cacheEvidence.isFinalized) {
        _cacheEvidence.recordCleanup(PlaybackCacheCleanupResult.succeeded);
      }
      _diagnostics.cacheSessionCleaned();
    } catch (error) {
      if (!_cacheEvidence.isFinalized) {
        _cacheEvidence.recordCleanup(
          error is _PlaybackOperationTimedOut
              ? PlaybackCacheCleanupResult.timedOut
              : PlaybackCacheCleanupResult.failed,
        );
      }
      DiagnosticLog.instance.warning(
        'playback-cache',
        'Cache session cleanup failed',
      );
    }
  }

  Future<void> _recreateEngine(int token) async {
    final recreate = engineRecreator;
    if (recreate == null) throw const _PlaybackEngineRecreationRequired();
    final retiringEngine = engine;
    final quiescence = _operationCoordinator.beginQuiescence(
      kind: PlaybackNativeOperationKind.retirementQuiesce,
      operation: retiringEngine.quiesce,
      barrierTimeout: retirementQuiesceTimeout,
    );
    await _awaitQuiescenceSafely(quiescence);
    await _operationCoordinator.waitForNativeOperations();
    await _cancelSubscriptions();
    await _disposeEngine();
    _throwIfStale(token);
    final replacement = await recreate(session);
    if (!_isCurrent(token)) {
      await _disposeReplacementEngine(replacement);
      throw const _PlaybackCancelled();
    }
    _engine = replacement;
    _engineDisposed = false;
    _operationCoordinator.replaceSeekEngine(replacement.seek);
    if (_lifecycleSuspended) {
      _lifecycleQuiescenceOperation = null;
      await quiesceForLifecycle();
    }
    await _bindEngine(token);
  }

  Future<void> _disposeReplacementEngine(PlaybackEngine replacement) async {
    try {
      await replacement.quiesce();
    } catch (_) {
      // Disposal is still required when a replacement becomes stale.
    }
    try {
      await replacement.dispose();
    } catch (_) {
      // The original cancellation remains the caller-visible result.
    }
  }

  Future<void> _awaitQuiescenceSafely(Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      // Native teardown must continue even when an urgent pause fails.
    }
  }

  bool _tryReserveAutomaticOpen(AutomaticPlaybackOpenReason reason) {
    final reserved = session.tryReserveAutomaticOpen(reason);
    if (!reserved &&
        session.automaticOpenCount >=
            PlaybackItemSession.maximumAutomaticOpenCount) {
      _diagnostics.automaticOpenBudgetExhausted(
        reason: reason,
        automaticOpenCount: session.automaticOpenCount,
      );
    }
    return reserved;
  }

  void _recordCacheSafetyDiagnostic(PlaybackCacheSafetyReason reason) {
    if (_cacheSafetyDiagnosticsWritten.add(reason)) {
      _diagnostics.cacheSafetyTriggered(reason);
    }
  }

  PlaybackCacheEvidenceObservation _cacheEvidenceObservation(
    PlaybackCacheObservation observation,
  ) {
    final snapshot = observation.engineSnapshot;
    final runtimeMode = _state.cacheRuntimeMode;
    final evidence =
        playbackCacheHasObservedDiskData(
          telemetryStatus: snapshot?.telemetryStatus,
          fileCacheBytes: snapshot?.fileCacheBytes,
          cacheOnDisk: snapshot?.cacheOnDisk,
        )
        ? PlaybackCacheEvidence.diskDataObserved
        : snapshot?.cacheOnDisk == true &&
              runtimeMode == PlaybackCacheRuntimeMode.disk
        ? PlaybackCacheEvidence.diskConfiguredOnly
        : snapshot?.cacheOnDisk == false &&
              snapshot?.telemetryStatus !=
                  PlaybackCacheTelemetryStatus.readFailed &&
              (runtimeMode == PlaybackCacheRuntimeMode.memory ||
                  runtimeMode == PlaybackCacheRuntimeMode.memoryFallback)
        ? PlaybackCacheEvidence.memoryProfileConfirmed
        : _lastNativeCacheEvidence == PlaybackCacheEvidence.disabled
        ? PlaybackCacheEvidence.disabled
        : PlaybackCacheEvidence.unconfirmed;
    final confirmedMode = switch (evidence) {
      PlaybackCacheEvidence.diskDataObserved ||
      PlaybackCacheEvidence.diskConfiguredOnly => _lastNativeConfirmedMode,
      PlaybackCacheEvidence.memoryProfileConfirmed =>
        _lastNativeConfirmedMode == PlaybackCacheRuntimeMode.memoryFallback
            ? PlaybackCacheRuntimeMode.memoryFallback
            : PlaybackCacheRuntimeMode.memory,
      PlaybackCacheEvidence.disabled => PlaybackCacheRuntimeMode.disabled,
      PlaybackCacheEvidence.unconfirmed => null,
    };
    return PlaybackCacheEvidenceObservation(
      cacheEvidence: evidence,
      telemetryStatus: snapshot?.telemetryStatus,
      fileCacheBytes: snapshot?.fileCacheBytes,
      actualForward: observation.actualForward,
      actualBackward: observation.actualBackward,
      cacheSnapshotResult: snapshot == null
          ? PlaybackCacheSnapshotResult.unavailable
          : PlaybackCacheSnapshotResult.available,
      snapshotUnavailableAlreadyRecorded: snapshot == null,
      requestedMode: _state.cacheProfile?.runtimeMode,
      confirmedMode: confirmedMode,
      fallbackReason: _state.cacheFallbackReason,
      readAheadStrategy: _state.cacheProfile?.readAheadStrategy,
      budgetPolicy: _state.cacheProfile?.budgetPolicy,
      sizeConfidence: _state.cacheProfile?.sizeConfidence,
      fullReadAheadEligible: observation.fullReadAheadEligible,
      fullReadAheadReachedEnd: observation.fullReadAheadEligible
          ? observation.fullReadAheadReachedEnd
          : false,
      settingsMode: cacheSettings.mode,
      cacheEnabled: runtimeMode != PlaybackCacheRuntimeMode.disabled,
      cacheOnDisk: snapshot?.cacheOnDisk,
      testOverrideActive: testOverrides?.isActive ?? false,
    );
  }

  static PlaybackCacheCreateResult? _cacheCreateResult(
    PlaybackCacheApplyResult result,
  ) {
    if (result.requestedMode != PlaybackCacheRuntimeMode.disk) return null;
    if (result.fallbackReason ==
        PlaybackCacheFallbackReason.mpvCacheCreateFailed) {
      return PlaybackCacheCreateResult.failed;
    }
    if (result.actualMode == PlaybackCacheRuntimeMode.disk) {
      return PlaybackCacheCreateResult.succeeded;
    }
    return PlaybackCacheCreateResult.unavailable;
  }

  void _flushCacheEvidenceObservation() {
    _cacheEvidence.flush();
  }

  void _onCacheObservationApplied(
    PlaybackCacheEvidenceObservation observation,
  ) {
    _diagnostics.cacheObservation(observation);
  }

  Future<SeekResult> _trackSeekOperation(
    Future<SeekResult> operation,
    Completer<void> bookkeeping,
  ) {
    final bookkeepingFuture = bookkeeping.future;
    _activeSeekBookkeeping.add(bookkeepingFuture);
    unawaited(
      operation.then<void>(
        (_) => _completeSeekBookkeeping(bookkeeping),
        onError: (Object _, StackTrace _) =>
            _completeSeekBookkeeping(bookkeeping),
      ),
    );
    unawaited(
      bookkeepingFuture.then<void>(
        (_) => _activeSeekBookkeeping.remove(bookkeepingFuture),
        onError: (Object _, StackTrace _) {
          _activeSeekBookkeeping.remove(bookkeepingFuture);
        },
      ),
    );
    return operation;
  }

  Future<void> _waitForSeekBookkeeping() async {
    while (_activeSeekBookkeeping.isNotEmpty) {
      final operations = List<Future<void>>.of(_activeSeekBookkeeping);
      await Future.wait<void>(
        operations.map(
          (bookkeeping) => bookkeeping.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        ),
      );
    }
  }

  static void _completeSeekBookkeeping(Completer<void> bookkeeping) {
    if (!bookkeeping.isCompleted) bookkeeping.complete();
  }

  void _writeTerminalSummaries() {
    final seekStatistics = _frozenSeekStatistics;
    if (seekStatistics == null || _cacheEvidence.summaryWritten) return;
    final summary = _cacheEvidence.claimSummaryForWrite(
      seekStatistics: seekStatistics,
    );
    if (summary == null) return;
    _diagnostics.cacheSessionSummary(summary);
    _diagnostics.flushSeekSummary(snapshot: seekStatistics);
  }

  SeekResult _cancelledSeekResult(Duration target) => SeekResult(
    disposition: SeekDisposition.cancelled,
    requestedTarget: _clampToDuration(target),
    settled: false,
    committedPosition: _state.position,
    failureKind: SeekFailureKind.staleSession,
  );

  static PlaybackCacheReopenReason _reopenReason(
    PlaybackCacheSafetyReason reason,
  ) => switch (reason) {
    PlaybackCacheSafetyReason.budget => PlaybackCacheReopenReason.budget,
    PlaybackCacheSafetyReason.lowSpace => PlaybackCacheReopenReason.lowSpace,
    PlaybackCacheSafetyReason.memoryPressure =>
      PlaybackCacheReopenReason.memoryPressure,
  };

  bool _shouldWriteEngineFingerprint(String fingerprint) {
    final now = _clock();
    final lastWritten = _engineLogLastWritten[fingerprint];
    if (lastWritten != null &&
        now.difference(lastWritten) < const Duration(seconds: 2)) {
      return false;
    }
    if (_engineLogLastWritten.length >= 64) {
      _engineLogLastWritten.clear();
    }
    _engineLogLastWritten[fingerprint] = now;
    return true;
  }

  Future<T> _withDeadline<T>(
    Future<T> operation,
    Duration timeout,
    PlaybackOperationTimeoutKind timeoutKind,
  ) async {
    return operation.timeout(
      timeout,
      onTimeout: () {
        _diagnostics.operationTimeout(timeoutKind);
        throw _PlaybackOperationTimedOut(timeoutKind);
      },
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  static String friendlyPlaybackError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('failed to resolve hostname') ||
        message.contains('no address associated with hostname') ||
        message.contains('unknown host')) {
      return '无法解析媒体地址，请检查 .strm 链接或 DNS';
    }
    if (message.contains('inflate return value') ||
        message.contains('incorrect header check')) {
      return '服务器返回的转码流格式异常';
    }
    if (message.contains('timeout') ||
        message.contains('did not become ready')) {
      return '媒体连接超时';
    }
    if (message.contains('failed to open') ||
        message.contains('http') ||
        message.contains('network')) {
      return '无法连接媒体流';
    }
    if (message.contains('codec') || message.contains('decoder')) {
      return '设备无法解码这个媒体';
    }
    return '播放失败，请返回后重试';
  }
}

class _PlaybackCancelled implements Exception {
  const _PlaybackCancelled();
}

class _LateSubtitleTaskIdentity {
  const _LateSubtitleTaskIdentity({
    required this.itemId,
    required this.playbackItemSessionId,
    required this.playbackSessionId,
    required this.controllerGeneration,
    required this.engineIdentity,
    required this.selection,
    required this.resolvedStreamIndex,
  });

  final String itemId;
  final PlaybackItemSessionId playbackItemSessionId;
  final String? playbackSessionId;
  final int controllerGeneration;
  final PlaybackEngine engineIdentity;
  final SubtitleSelection selection;
  final int resolvedStreamIndex;
}

class _LateSubtitleTask {
  _LateSubtitleTask({required this.identity});

  final _LateSubtitleTaskIdentity identity;
  final Completer<void> cancellation = Completer<void>();

  void cancel() {
    if (!cancellation.isCompleted) cancellation.complete();
  }
}

class _InitialSubtitleWaitTimedOut implements Exception {
  const _InitialSubtitleWaitTimedOut();
}

class _ShutdownNativeBarrierBudget {
  _ShutdownNativeBarrierBudget(this.timeout)
    : _stopwatch = Stopwatch()..start();

  final Duration timeout;
  final Stopwatch _stopwatch;

  Duration get remaining {
    final value = timeout - _stopwatch.elapsed;
    return value > Duration.zero ? value : Duration.zero;
  }

  Future<bool> wait(Future<void> operation) async {
    final allowance = remaining;
    if (allowance <= Duration.zero) return false;
    try {
      await operation.timeout(allowance);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

class _PlaybackOperationTimedOut implements Exception {
  const _PlaybackOperationTimedOut(this.kind);

  final PlaybackOperationTimeoutKind kind;

  @override
  String toString() => 'Playback operation timeout: ${kind.code}';
}

class _PlaybackEngineRecreationRequired implements Exception {
  const _PlaybackEngineRecreationRequired();
}

class _SubtitleStyle {
  const _SubtitleStyle({
    required this.fontSize,
    required this.color,
    required this.outlineColor,
    required this.position,
  });

  final double fontSize;
  final int color;
  final int outlineColor;
  final int position;
}
