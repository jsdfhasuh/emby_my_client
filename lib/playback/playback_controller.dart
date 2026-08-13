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
    this.stopTimeout = const Duration(seconds: 5),
    this.disposeTimeout = const Duration(seconds: 5),
    this.reporterTimeout = const Duration(seconds: 3),
    this.cacheCleanupTimeout = const Duration(seconds: 3),
    this.progressInterval = const Duration(seconds: 10),
    this.cacheStatePollInterval = const Duration(seconds: 1),
    this.cacheSpacePollInterval = const Duration(seconds: 10),
    this.recoveryPolicy = const PlaybackRecoveryPolicy(),
    PlaybackClock? clock,
  }) : _engine = engine,
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
  final Duration stopTimeout;
  final Duration disposeTimeout;
  final Duration reporterTimeout;
  final Duration cacheCleanupTimeout;
  final Duration progressInterval;
  final Duration cacheStatePollInterval;
  final Duration cacheSpacePollInterval;
  final PlaybackRecoveryPolicy recoveryPolicy;
  final PlaybackClock _clock;
  final TrackMapper _trackMapper = const TrackMapper();

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late PlaybackOperationCoordinator _operationCoordinator;
  PlaybackState _state = const PlaybackState();
  Completer<void>? _readyCompleter;
  Timer? _progressTimer;
  Future<void>? _shutdownOperation;
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex;
  int? _selectedSubtitleStreamIndex;
  int _maxStreamingBitrate;
  int _generation = 0;
  bool _sawBuffering = false;
  bool _startupFailureSignaled = false;
  bool _disposed = false;
  bool _shuttingDown = false;
  bool _engineDisposed = false;
  PlaybackCacheSession? _cacheSession;
  PlaybackCacheCoordinator? _cacheCoordinator;
  PlaybackCacheFallbackReason? _forcedCacheFallbackReason;
  bool _runtimeRecoveryScheduled = false;
  DateTime? _lastExecutedSeekAt;
  DateTime? _stablePlaybackSince;
  Duration? _lastStabilityPosition;
  bool _seekBecameStable = false;
  bool _lifecycleSuspended = false;
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

  Future<void> start({
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) {
    _selectedMediaSourceId = mediaSourceId;
    _selectedAudioStreamIndex = audioStreamIndex;
    _selectedSubtitleStreamIndex = subtitleStreamIndex;
    if (!_tryReserveAutomaticOpen(AutomaticPlaybackOpenReason.initial)) {
      return Future.error(StateError('Initial playback open is unavailable'));
    }
    return _startPlayback();
  }

  Future<void> _startPlayback({
    Duration? resumePosition,
    bool playAfterReady = true,
    bool forceTranscodeInitially = false,
    AutomaticPlaybackOpenReason transcodeFallbackReason =
        AutomaticPlaybackOpenReason.startupTranscodeFallback,
    String? openingStatusMessage,
  }) async {
    final token = ++_generation;
    await _bindEngine(token);
    _throwIfStale(token);
    _desiredPlaying = playAfterReady;
    var currentOpeningStatusMessage = openingStatusMessage;
    _setState(
      PlaybackState(
        phase: PlaybackPhase.resolving,
        isBuffering: true,
        playbackRate: _desiredPlaybackRate,
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
          subtitleStreamIndex: _selectedSubtitleStreamIndex,
          maxStreamingBitrate: _maxStreamingBitrate,
          forceTranscode: forceTranscode,
        );
        if (!_isCurrent(token)) {
          await reporter.cleanup(plan);
          return;
        }

        reporter.activate(plan);
        await _prepareCacheForPlan(plan, token);
        _throwIfStale(token);
        _setState(
          _state.copyWith(
            phase: PlaybackPhase.opening,
            plan: plan,
            clearError: true,
            isBuffering: true,
            statusMessage: currentOpeningStatusMessage,
          ),
        );
        _prepareReadyWait();
        final resume =
            resumePosition ??
            (item.resumePosition > const Duration(seconds: 10)
                ? item.resumePosition
                : Duration.zero);
        try {
          await _withDeadline(
            engine.open(
              plan.uri,
              headers: plan.usesServerAuthentication
                  ? playbackHeaders
                  : const <String, String>{},
              play: resume == Duration.zero && playAfterReady,
            ),
            openTimeout,
            PlaybackOperationTimeoutKind.engineOpen,
          );
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
        }
        await _restoreEnginePresentation(token);

        if (resume > Duration.zero) {
          final target = _clampToDuration(resume);
          _setState(_state.copyWith(phase: PlaybackPhase.seekingResume));
          final result = await seekAbsolute(target, source: SeekSource.resume);
          if (result.disposition != SeekDisposition.executed) {
            throw TimeoutException('Resume seek did not settle');
          }
          _throwIfStale(token);
          if (playAfterReady) await engine.play();
        }

        _setState(
          _state.copyWith(
            phase: PlaybackPhase.ready,
            isBuffering: false,
            clearError: true,
            clearStatus: true,
          ),
        );
        try {
          await reporter.reportStart(_state.position);
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
          _generation++;
        }
        _shuttingDown = true;
        _operationCoordinator.shutdown();
        await _waitForSeekBookkeeping();
        _frozenSeekStatistics ??= _diagnostics.snapshotSeekStatistics();
        await _cancelSubscriptions();
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

  Future<void> _prepareCacheForPlan(PlaybackPlan plan, int token) async {
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
        pollInterval: cacheSpacePollInterval,
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
    );
    final forcedReason = _forcedCacheFallbackReason;
    if (forcedReason != null &&
        profile.runtimeMode != PlaybackCacheRuntimeMode.disabled) {
      profile = profile.memoryFallback(forcedReason);
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
        pollInterval: cacheSpacePollInterval,
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
      return _prepareCacheForPlan(plan, token);
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
    if (!_state.isPlaying) await engine.play();
    _desiredPlaying = true;
    await _reportProgress();
  }

  Future<void> pause() async {
    if (_state.isPlaying) await engine.pause();
    _desiredPlaying = false;
    await _reportProgress();
  }

  Future<void> pauseForLifecycle() async {
    _lifecycleSuspended = true;
    _cacheCoordinator?.pause();
    if (_state.isPlaying) await engine.pause();
    await _reportProgress();
  }

  Future<void> resumeForLifecycle() async {
    _lifecycleSuspended = false;
    await _cacheCoordinator?.resume();
    if (_pendingRecoveryFingerprint != null) _scheduleRuntimeRecovery();
  }

  Future<void> handleMemoryPressure() async {
    await _cacheCoordinator?.handleMemoryPressure();
  }

  Future<SeekResult> seekAbsolute(
    Duration position, {
    required SeekSource source,
  }) {
    if (_shuttingDown || _disposed) {
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
      _injectApprovedSeekFailureIfPending();
      await _reportProgress();
      await _cacheCoordinator?.afterExecutedSeek();
    }
    return result;
  }

  Future<SeekResult> seekRelative(
    Duration offset, {
    required SeekSource source,
  }) {
    if (_shuttingDown || _disposed) {
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
      _injectApprovedSeekFailureIfPending();
      await _reportProgress();
      await _cacheCoordinator?.afterExecutedSeek();
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
    if (plan == null || plan.audioStreamIndex == streamIndex) return;
    final serverTrack = _trackMapper.findByIndex(plan, 'audio', streamIndex);
    if (plan.method == PlayMethod.directPlay) {
      await _waitForTracks(audio: true);
    }
    final engineTrackId = serverTrack == null
        ? null
        : _trackMapper.engineTrackId(serverTrack, _state.audioTracks);
    if (plan.method == PlayMethod.directPlay && engineTrackId != null) {
      await engine.selectAudioTrack(engineTrackId);
      _selectedAudioStreamIndex = streamIndex;
      final updated = plan.copyWith(audioStreamIndex: streamIndex);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }
    await reconfigure(
      audioStreamIndex: streamIndex,
      forceTranscode: plan.method == PlayMethod.directPlay,
    );
  }

  Future<void> selectSubtitleStream(int? streamIndex) async {
    final plan = _state.plan;
    if (plan == null || plan.subtitleStreamIndex == streamIndex) return;
    if (streamIndex == null) {
      await engine.selectSubtitleTrack(null);
      _selectedSubtitleStreamIndex = null;
      final updated = plan.copyWith(clearSubtitleStreamIndex: true);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }

    final serverTrack = _trackMapper.findByIndex(plan, 'subtitle', streamIndex);
    if (serverTrack?.isExternal == true && serverTrack?.deliveryUrl != null) {
      final url = resolver.resolveExternalUrl(serverTrack!.deliveryUrl!);
      await engine.loadExternalSubtitle(
        url,
        title: serverTrack.title,
        language: serverTrack.language,
      );
      _selectedSubtitleStreamIndex = streamIndex;
      final updated = plan.copyWith(subtitleStreamIndex: streamIndex);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }

    if (plan.method == PlayMethod.directPlay) {
      await _waitForTracks(audio: false);
    }
    final engineTrackId = serverTrack == null
        ? null
        : _trackMapper.engineTrackId(serverTrack, _state.subtitleTracks);
    if (plan.method == PlayMethod.directPlay && engineTrackId != null) {
      await engine.selectSubtitleTrack(engineTrackId);
      _selectedSubtitleStreamIndex = streamIndex;
      final updated = plan.copyWith(subtitleStreamIndex: streamIndex);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }
    await reconfigure(
      subtitleStreamIndex: streamIndex,
      forceTranscode: plan.method == PlayMethod.directPlay,
    );
  }

  Future<void> setPlaybackRate(double rate) async {
    final safeRate = rate.clamp(0.25, 3.0).toDouble();
    await engine.setRate(safeRate);
    _desiredPlaybackRate = safeRate;
    _setState(_state.copyWith(playbackRate: safeRate));
  }

  Future<void> setAudioDelay(Duration delay) async {
    await engine.setAudioDelay(delay);
    _desiredAudioDelay = delay;
  }

  Future<void> setSubtitleDelay(Duration delay) async {
    await engine.setSubtitleDelay(delay);
    _desiredSubtitleDelay = delay;
  }

  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {
    await engine.configureSubtitleStyle(
      fontSize: fontSize,
      color: color,
      outlineColor: outlineColor,
      position: position,
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
    return _operationCoordinator.runControlOperation(
      priority: PlaybackControlOperationPriority.userReconfigure,
      operation: (lease) async {
        if (_disposed || _shuttingDown || _engineDisposed || !lease.isCurrent) {
          return;
        }
        final position = _state.position;
        final wasPlaying = _desiredPlaying;
        _generation++;
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
          _selectedSubtitleStreamIndex = null;
        } else if (subtitleStreamIndex != null) {
          _selectedSubtitleStreamIndex = subtitleStreamIndex;
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
    _shuttingDown = true;
    _operationCoordinator.shutdown();
    final operation = _shutdown();
    _shutdownOperation = operation;
    return operation;
  }

  Future<void> _shutdown() async {
    _generation++;
    _pendingRecoveryFingerprint = null;
    await _waitForSeekBookkeeping();
    _frozenSeekStatistics ??= _diagnostics.snapshotSeekStatistics();
    _progressTimer?.cancel();
    await _stopCacheCoordinator(flushEvidence: false);
    _setState(_state.copyWith(phase: PlaybackPhase.stopping));
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _PlaybackCancelled());
    }
    await _cancelSubscriptions();

    DiagnosticLog.instance.info('player', 'event=playback_closing');
    await _stopEngine();
    await _stopReporterSafely();
    await _disposeEngine();
    await _cleanupCacheSessionSafely();
    _writeTerminalSummaries();
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.idle,
        isPlaying: false,
        isBuffering: false,
      ),
    );
  }

  Future<void> _bindEngine(int token) async {
    await _cancelSubscriptions();
    _throwIfStale(token);
    final boundEngine = engine;
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
        _setState(_state.copyWith(isPlaying: playing));
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
        if (_disposed || !identical(_cacheCoordinator, coordinator)) return;
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
      spacePollInterval: cacheSpacePollInterval,
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
    _generation++;
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
        engine.stop(),
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

  Future<void> _restoreEnginePresentation(int token) async {
    await engine.setRate(_desiredPlaybackRate);
    _throwIfStale(token);
    await engine.setAudioDelay(_desiredAudioDelay);
    _throwIfStale(token);
    await engine.setSubtitleDelay(_desiredSubtitleDelay);
    _throwIfStale(token);
    final style = _desiredSubtitleStyle;
    if (style == null) return;
    await engine.configureSubtitleStyle(
      fontSize: style.fontSize,
      color: style.color,
      outlineColor: style.outlineColor,
      position: style.position,
    );
    _throwIfStale(token);
  }

  void _recordExecutedSeek() {
    _lastExecutedSeekAt = _clock();
    _stablePlaybackSince = null;
    _lastStabilityPosition = _state.position;
    _seekBecameStable = false;
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
    _generation++;
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
    );
  }

  void _invalidateCurrentControllerOperation() {
    _generation++;
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

  Future<void> _applySelectedDirectPlayTracks(
    PlaybackPlan plan,
    int token,
  ) async {
    final audioIndex = _selectedAudioStreamIndex;
    if (audioIndex != null) {
      await _waitForTracks(audio: true);
      _throwIfStale(token);
      final track = _trackMapper.findByIndex(plan, 'audio', audioIndex);
      final engineId = track == null
          ? null
          : _trackMapper.engineTrackId(track, _state.audioTracks);
      if (engineId == null) {
        throw StateError('Unable to map Emby audio track $audioIndex');
      }
      await engine.selectAudioTrack(engineId);
    }

    final subtitleIndex = _selectedSubtitleStreamIndex;
    if (subtitleIndex == null) return;
    final track = _trackMapper.findByIndex(plan, 'subtitle', subtitleIndex);
    if (track?.isExternal == true && track?.deliveryUrl != null) {
      await engine.loadExternalSubtitle(
        resolver.resolveExternalUrl(track!.deliveryUrl!),
        title: track.title,
        language: track.language,
      );
      return;
    }
    await _waitForTracks(audio: false);
    _throwIfStale(token);
    final engineId = track == null
        ? null
        : _trackMapper.engineTrackId(track, _state.subtitleTracks);
    if (engineId == null) {
      throw StateError('Unable to map Emby subtitle track $subtitleIndex');
    }
    await engine.selectSubtitleTrack(engineId);
  }

  Future<void> _waitForTracks({required bool audio}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      final tracks = audio ? _state.audioTracks : _state.subtitleTracks;
      if (tracks.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 40));
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

  Future<void> _reportProgress() async {
    try {
      await reporter.reportProgress(
        position: _state.position,
        isPaused: !_state.isPlaying,
      );
    } catch (error) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_progress_report_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Duration _clampToDuration(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    final duration = _state.duration;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  bool _isCurrent(int token) =>
      !_disposed && !_shuttingDown && token == _generation;

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

  Future<void> _disposeEngine() async {
    if (_engineDisposed) return;
    _engineDisposed = true;
    try {
      await _withDeadline(
        engine.dispose(),
        disposeTimeout,
        PlaybackOperationTimeoutKind.engineDispose,
      );
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_engine_dispose_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Future<void> _stopEngine() async {
    if (_engineDisposed) return;
    try {
      await _withDeadline(
        engine.stop(),
        stopTimeout,
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
    _operationCoordinator.invalidateForHigherPriorityOperation();
    await _cancelSubscriptions();
    await _disposeEngine();
    _throwIfStale(token);
    final replacement = await recreate(session);
    _throwIfStale(token);
    _engine = replacement;
    _engineDisposed = false;
    _operationCoordinator.replaceSeekEngine(replacement.seek);
    await _bindEngine(token);
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
