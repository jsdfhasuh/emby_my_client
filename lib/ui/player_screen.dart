import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../core/diagnostic_log.dart';
import '../core/player_diagnostics.dart';
import '../data/emby_api.dart';
import '../downloads/download_models.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../offline/offline_playback_reporter.dart';
import '../offline/offline_playback_resolver.dart';
import '../platform/platform_capabilities.dart';
import '../playback/emby_stream_resolver.dart';
import '../playback/cache/playback_cache_storage.dart';
import '../playback/cache/playback_cache_storage_scope.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_diagnostics.dart';
import '../playback/playback_diagnostics_test_overrides.dart';
import '../playback/playback_diagnostics_test_overrides_scope.dart';
import '../playback/playback_engine.dart';
import '../playback/playback_operation_coordinator.dart';
import '../playback/picture_in_picture.dart';
import '../playback/playback_queue.dart';
import '../playback/playback_session_reporter.dart';
import '../playback/playback_settings.dart';
import '../playback/playback_settings_repository.dart';
import '../playback/playback_settings_scope.dart';
import '../playback/playback_state.dart';
import '../playback/player_session_coordinator.dart';
import 'widgets/playback_cache_status_section.dart';
import '../playback/track_mapper.dart';
import '../realtime/emby_event.dart';
import 'widgets/trickplay_preview.dart';
import 'player_system_ui.dart';

abstract interface class PlayerSystemControls {
  Future<double> readBrightness();

  Future<void> setBrightness(double value);

  Future<void> resetBrightness();

  Future<double> readVolume();

  Future<void> setVolume(double value);
}

class PluginPlayerSystemControls implements PlayerSystemControls {
  const PluginPlayerSystemControls();

  @override
  Future<double> readBrightness() => ScreenBrightness.instance.application;

  @override
  Future<void> setBrightness(double value) =>
      ScreenBrightness.instance.setApplicationScreenBrightness(value);

  @override
  Future<void> resetBrightness() =>
      ScreenBrightness.instance.resetApplicationScreenBrightness();

  @override
  Future<double> readVolume() => VolumeController.instance.getVolume();

  @override
  Future<void> setVolume(double value) =>
      VolumeController.instance.setVolume(value);
}

class SafePlayerSystemControls {
  SafePlayerSystemControls(
    this.delegate, {
    void Function({required bool brightness, required Object error})? onFailure,
  }) : _onFailure = onFailure;

  final PlayerSystemControls delegate;
  final void Function({required bool brightness, required Object error})?
  _onFailure;
  bool brightnessAvailable = true;
  bool volumeAvailable = true;
  bool brightnessModified = false;

  Future<double?> readBrightness() async {
    if (!brightnessAvailable) return null;
    try {
      return await delegate.readBrightness();
    } catch (error) {
      _disable(brightness: true, error: error);
      return null;
    }
  }

  Future<void> setBrightness(double value) async {
    if (!brightnessAvailable) return;
    try {
      await delegate.setBrightness(value);
      brightnessModified = true;
    } catch (error) {
      _disable(brightness: true, error: error);
    }
  }

  Future<void> resetBrightness() async {
    if (!brightnessModified) return;
    try {
      await delegate.resetBrightness();
    } catch (error) {
      try {
        DiagnosticLog.instance.warning(
          'player',
          'Brightness reset failed errorType=${error.runtimeType}',
        );
      } catch (_) {
        // A diagnostic failure must not affect player shutdown.
      }
    } finally {
      brightnessModified = false;
    }
  }

  Future<double?> readVolume() async {
    if (!volumeAvailable) return null;
    try {
      return await delegate.readVolume();
    } catch (error) {
      _disable(brightness: false, error: error);
      return null;
    }
  }

  Future<void> setVolume(double value) async {
    if (!volumeAvailable) return;
    try {
      await delegate.setVolume(value);
    } catch (error) {
      _disable(brightness: false, error: error);
    }
  }

  void _disable({required bool brightness, required Object error}) {
    if (brightness) {
      if (!brightnessAvailable) return;
      brightnessAvailable = false;
    } else {
      if (!volumeAvailable) return;
      volumeAvailable = false;
    }
    try {
      _onFailure?.call(brightness: brightness, error: error);
    } catch (_) {
      // A diagnostic/UI callback must not reintroduce a plugin exception.
    }
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.api,
    required this.item,
    this.queue,
    this.offlineItem,
    this.downloads,
    this.capabilities,
    this.systemControls,
    this.systemUiController,
    this.cacheStorage,
    this.diagnosticsTestOverrides,
  }) : assert(
         (offlineItem == null && downloads == null) ||
             (offlineItem != null && downloads != null),
       );

  final EmbyApi api;
  final EmbyItem item;
  final PlaybackQueue? queue;
  final OfflineMediaItem? offlineItem;
  final DownloadService? downloads;
  final PlatformCapabilities? capabilities;
  final PlayerSystemControls? systemControls;
  final PlayerSystemUiController? systemUiController;
  final PlaybackCacheStorage? cacheStorage;
  final PlaybackDiagnosticsTestOverridesController? diagnosticsTestOverrides;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late Player _player;
  late VideoController _videoController;
  late final PictureInPictureController _pipController;
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  late final PlayerSystemControls _systemControls =
      widget.systemControls ?? const PluginPlayerSystemControls();
  late final PlayerSystemUiController _systemUiController =
      widget.systemUiController ??
      DefaultPlayerSystemUiController(capabilities: _capabilities);
  late final SafePlayerSystemControls _safeSystemControls =
      SafePlayerSystemControls(
        _systemControls,
        onFailure: _handleSystemControlFailure,
      );
  late final PlaybackQueue _queue;
  late EmbyItem _currentItem;
  late final PlaybackSettingsRepository _settingsRepository;
  late final PlaybackCacheStorage _cacheStorage;
  PlaybackDiagnosticsTestOverridesController? _diagnosticsTestOverrides;
  final PlayerSessionCoordinator _playerSessionCoordinator =
      PlayerSessionCoordinator();
  late PlaybackItemSession _itemSession;
  final TrackMapper _trackMapper = const TrackMapper();
  PlaybackController? _playbackController;
  PlaybackSettings _settings = const PlaybackSettings();
  PlaybackPlan? _plan;
  Timer? _controlsTimer;
  Timer? _nextCountdownTimer;
  StreamSubscription<EmbyEvent>? _realtimeSubscription;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  Duration? _horizontalDragStartPosition;
  Duration? _horizontalDragPreviewPosition;
  Duration? _progressSeekStartPosition;
  double _horizontalDragDx = 0;
  bool _playing = false;
  bool _buffering = true;
  bool _controlsVisible = true;
  bool _seeking = false;
  int _seekGestureGeneration = 0;
  bool _controlsLocked = false;
  BoxFit _videoFit = BoxFit.contain;
  Offset? _doubleTapPosition;
  double? _verticalDragStartValue;
  double? _verticalDragValue;
  double? _verticalDragStartY;
  bool _verticalDragIsBrightness = false;
  bool _showSkipIntro = false;
  bool _autoNextCancelled = false;
  bool _switchingItem = false;
  bool _completed = false;
  int? _nextCountdown;
  int _autoPlayedCount = 0;
  String? _error;
  String? _playbackStatus;
  bool _brightnessFailureReported = false;
  bool _volumeFailureReported = false;
  late final PlayerCloseCoordinator _closeCoordinator;
  bool _playbackResourcesReleased = false;
  bool _playbackInitializationStarted = false;
  double? _lastMetricsWidth;
  double? _lastMetricsHeight;
  AppLifecycleState? _lastLifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentItem = widget.item;
    _itemSession = _playerSessionCoordinator.beginInitialItem();
    _queue = widget.queue ?? PlaybackQueue.single(widget.api, widget.item);
    if (widget.offlineItem == null) {
      _realtimeSubscription = widget.api.realtime.events.listen((event) {
        if (event is EmbyPlaystateCommand) {
          unawaited(_handleRemotePlaystate(event));
        }
      });
      unawaited(widget.api.realtime.setBackgroundConnectionRequired(true));
    }
    _createPlayer();
    _pipController = PictureInPictureController(
      capabilities: _capabilities,
      onToggle: _togglePlay,
      onClose: () {
        unawaited(_closePlayer(PlayerExitReason.systemBack));
      },
      onModeChanged: (active) {
        if (mounted && active) {
          setState(() => _controlsVisible = false);
        }
      },
    );
    _closeCoordinator = PlayerCloseCoordinator(
      stopPlayback: _stopPlaybackForClose,
      resetBrightness: _resetBrightnessSafely,
      restoreSystemUi: _restoreAfterPlayback,
      popRoute: () async {
        if (mounted) Navigator.of(context).pop();
      },
      onExitRequested: (reason) {
        _logPlayerEvent(
          PlayerDiagnosticEvent.playerExitRequested,
          exitReason: reason,
        );
      },
      onFailure: logPlayerFailure,
    );
    _logPlayerEvent(
      PlayerDiagnosticEvent.playerRouteEnter,
      orientationPolicy: PlayerOrientationPolicy.landscapePlayback,
    );
    unawaited(_pipController.initialize());
    try {
      VolumeController.instance.showSystemUI = false;
    } catch (error) {
      _handleSystemControlFailure(brightness: false, error: error);
    }
    unawaited(_enterFullscreen());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_playbackInitializationStarted) return;
    _playbackInitializationStarted = true;
    _settingsRepository = PlaybackSettingsRepositoryScope.of(context);
    _cacheStorage =
        widget.cacheStorage ?? PlaybackCacheStorageScope.of(context);
    _diagnosticsTestOverrides =
        widget.diagnosticsTestOverrides ??
        PlaybackDiagnosticsTestOverridesScope.maybeOf(context);
    unawaited(_initializePlaybackSafely());
  }

  void _createPlayer() {
    _player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    _videoController = VideoController(_player);
  }

  Future<void> _initializePlayback() async {
    final snapshot = await _settingsRepository.load(widget.api.session);
    if (!mounted) return;
    PlaybackDiagnostics().cacheSettingsLoaded(snapshot.settings.cache.mode);
    _settings = snapshot.settings;
    _videoFit = _boxFit(snapshot.settings.videoFit);
    await _startCurrentItem();
  }

  Future<void> _initializePlaybackSafely() async {
    try {
      await _initializePlayback();
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_initialization_failed '
            'errorType=${error.runtimeType}',
      );
      if (!mounted) return;
      setState(() {
        _error = '播放器初始化失败，请返回后重试';
        _buffering = false;
        _playing = false;
        _playbackStatus = null;
      });
    }
  }

  Future<void> _startCurrentItem() async {
    final offlineItem = widget.offlineItem;
    final downloads = widget.downloads;
    final PlaybackStreamResolver resolver;
    final PlaybackReporter reporter;
    final Map<String, String> playbackHeaders;
    if (offlineItem != null && downloads != null) {
      if (_currentItem.id != offlineItem.itemId) {
        throw StateError('Offline playback cannot switch media items');
      }
      resolver = OfflinePlaybackResolver(offlineItem);
      reporter = OfflinePlaybackReporter(
        item: offlineItem,
        writeProgress: (position, played) => downloads.recordOfflineProgress(
          offlineItem,
          position,
          played: played,
        ),
      );
      playbackHeaders = const {};
    } else {
      resolver = EmbyStreamResolver(widget.api);
      reporter = PlaybackSessionReporter(api: widget.api, item: _currentItem);
      playbackHeaders = widget.api.playbackHeaders;
    }
    final controller = PlaybackController(
      item: _currentItem,
      engine: MediaKitPlaybackEngine(_player),
      resolver: resolver,
      reporter: reporter,
      playbackHeaders: playbackHeaders,
      engineRecreator: _recreatePlaybackEngine,
      session: _itemSession,
      cacheSettings: _settings.cache,
      cacheStorage: _cacheStorage,
      testOverrides: _diagnosticsTestOverrides?.consumeForPlayback(),
      maxStreamingBitrate: _settings.maxStreamingBitrate,
    )..addListener(_syncPlaybackState);
    _playbackController = controller;
    await controller.setPlaybackRate(_settings.playbackRate);
    await controller.setAudioDelay(
      Duration(milliseconds: _settings.audioDelayMilliseconds),
    );
    await controller.setSubtitleDelay(
      Duration(milliseconds: _settings.subtitleDelayMilliseconds),
    );
    await controller.configureSubtitleStyle(
      fontSize: _settings.subtitleFontSize,
      color: _settings.subtitleColor,
      outlineColor: _settings.subtitleOutlineColor,
      position: _settings.subtitlePosition,
    );
    await controller.start();
  }

  Future<PlaybackEngine> _recreatePlaybackEngine(PlaybackItemSession session) =>
      _playerSessionCoordinator.recreateCurrentResource(
        sessionId: session.id,
        recreate: () async {
          if (!mounted) throw StateError('Player route is unavailable');
          _createPlayer();
          setState(() {});
          return MediaKitPlaybackEngine(_player);
        },
      );

  void _syncPlaybackState() {
    if (!mounted) return;
    final playback = _playbackController?.state;
    if (playback == null) return;
    final startedPlaying = !_playing && playback.isPlaying;
    final playingChanged = _playing != playback.isPlaying;
    final justCompleted = !_completed && playback.isCompleted;
    setState(() {
      if (!_seeking) _position = playback.displayPosition;
      _duration = playback.duration;
      _buffer = playback.buffer;
      _playing = playback.isPlaying;
      _buffering = playback.isBuffering;
      _plan = playback.plan;
      _error = playback.errorMessage;
      _playbackStatus = playback.statusMessage;
      _completed = playback.isCompleted;
    });
    if (playingChanged) {
      unawaited(_pipController.updatePlaying(playback.isPlaying));
    }
    if (startedPlaying) _restartControlsTimer();
    if (startedPlaying) {
      _logPlayerEvent(PlayerDiagnosticEvent.playerPlaybackStarted);
    }
    if (justCompleted) {
      _logPlayerEvent(
        PlayerDiagnosticEvent.playerCompleted,
        exitReason: PlayerExitReason.completed,
      );
    }
    _updateTimelineOverlays();
    if (justCompleted) unawaited(_handleCompleted());
  }

  Future<void> _enterFullscreen() async {
    _logPlayerEvent(
      PlayerDiagnosticEvent.fullscreenOrientationRequested,
      orientationPolicy: PlayerOrientationPolicy.landscapePlayback,
    );
    try {
      await _systemUiController.enterPlayback();
      _logPlayerEvent(
        PlayerDiagnosticEvent.fullscreenOrientationApplied,
        orientationPolicy: PlayerOrientationPolicy.landscapePlayback,
      );
    } catch (error) {
      _logPlayerEvent(
        PlayerDiagnosticEvent.fullscreenOrientationFailed,
        orientationPolicy: PlayerOrientationPolicy.landscapePlayback,
        errorType: PlayerDiagnosticErrorType.orientation,
      );
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_fullscreen_request_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Future<void> _restoreAfterPlayback() async {
    _logPlayerEvent(
      PlayerDiagnosticEvent.systemUiRestoreRequested,
      orientationPolicy: _restoreOrientationPolicy,
    );
    _logPlayerEvent(
      PlayerDiagnosticEvent.orientationRestoreRequested,
      orientationPolicy: _restoreOrientationPolicy,
    );
    try {
      await _systemUiController.restoreAfterPlayback();
      _logPlayerEvent(
        PlayerDiagnosticEvent.systemUiRestoreApplied,
        orientationPolicy: _restoreOrientationPolicy,
      );
      _logPlayerEvent(
        PlayerDiagnosticEvent.orientationRestoreApplied,
        orientationPolicy: _restoreOrientationPolicy,
      );
    } catch (error) {
      _logPlayerEvent(
        PlayerDiagnosticEvent.systemUiRestoreFailed,
        orientationPolicy: _restoreOrientationPolicy,
        errorType: PlayerDiagnosticErrorType.systemUi,
      );
      _logPlayerEvent(
        PlayerDiagnosticEvent.orientationRestoreFailed,
        orientationPolicy: _restoreOrientationPolicy,
        errorType: PlayerDiagnosticErrorType.orientation,
      );
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_system_ui_restore_failed '
            'errorType=${error.runtimeType}',
      );
      rethrow;
    }
  }

  PlayerOrientationPolicy get _restoreOrientationPolicy =>
      _capabilities.platformName == 'ios'
      ? PlayerOrientationPolicy.systemDefault
      : PlayerOrientationPolicy.androidPortraitDefault;

  Future<void> _closePlayer(PlayerExitReason reason) =>
      _closeCoordinator.close(reason);

  Future<void> _stopPlaybackForClose() =>
      _playerSessionCoordinator.shutdown(_releasePlaybackResources);

  Future<void> _releasePlaybackResources() async {
    if (_playbackResourcesReleased) return;
    _playbackResourcesReleased = true;
    _controlsTimer?.cancel();
    _nextCountdownTimer?.cancel();
    _pipController.dispose();
    try {
      await _realtimeSubscription?.cancel();
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_realtime_subscription_cleanup_failed '
            'errorType=${error.runtimeType}',
      );
    }
    if (widget.offlineItem == null) {
      try {
        await widget.api.realtime.setBackgroundConnectionRequired(false);
      } catch (error) {
        DiagnosticLog.instance.warning(
          'player',
          'event=playback_realtime_background_cleanup_failed '
              'errorType=${error.runtimeType}',
        );
      }
    }
    final controller = _playbackController;
    if (controller != null) {
      controller.removeListener(_syncPlaybackState);
      try {
        await controller.shutdown();
      } catch (error) {
        DiagnosticLog.instance.warning(
          'player',
          'event=playback_controller_shutdown_failed '
              'errorType=${error.runtimeType}',
        );
      } finally {
        controller.dispose();
      }
    } else {
      try {
        await _player.dispose();
      } catch (error) {
        DiagnosticLog.instance.warning(
          'player',
          'event=playback_player_cleanup_failed '
              'errorType=${error.runtimeType}',
        );
      }
    }
  }

  void _toggleControls() {
    if (_controlsLocked) {
      if (!_controlsVisible) setState(() => _controlsVisible = true);
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartControlsTimer();
  }

  void _restartControlsTimer() {
    _controlsTimer?.cancel();
    if (!_playing) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _togglePlay() async {
    final controller = _playbackController;
    if (controller == null) return;
    await controller.playOrPause();
    setState(() => _controlsVisible = true);
    _restartControlsTimer();
  }

  Future<void> _seekRelative(
    Duration offset, {
    SeekSource source = SeekSource.controls,
  }) async {
    final controller = _playbackController;
    if (controller == null) return;
    await controller.seekRelative(offset, source: source);
    _restartControlsTimer();
  }

  Future<void> _seekAbsolute(
    Duration target, {
    required SeekSource source,
  }) async {
    final controller = _playbackController;
    if (controller == null) return;
    await controller.seekAbsolute(target, source: source);
    _restartControlsTimer();
  }

  Future<void> _handleRemotePlaystate(EmbyPlaystateCommand message) async {
    final controller = _playbackController;
    if (controller == null || _switchingItem) return;
    if (message.itemId != null && message.itemId != _currentItem.id) {
      DiagnosticLog.instance.warning(
        'realtime',
        'Ignored Playstate command for another item',
      );
      return;
    }
    final currentSessionId = controller.state.plan?.playSessionId;
    if (message.playSessionId != null &&
        message.playSessionId != currentSessionId) {
      DiagnosticLog.instance.warning(
        'realtime',
        'Ignored Playstate command for another play session',
      );
      return;
    }

    switch (message.command.toLowerCase()) {
      case 'pause':
        await controller.pause();
      case 'unpause':
      case 'play':
        await controller.play();
      case 'stop':
        await _closePlayer(PlayerExitReason.remoteStop);
      case 'seek':
        final ticks = message.seekPositionTicks;
        if (ticks != null) {
          await controller.seekAbsolute(
            Duration(microseconds: ticks ~/ 10),
            source: SeekSource.remote,
          );
        }
      case 'nexttrack':
        await _playNext();
      case 'previoustrack':
        await _playPrevious();
      case 'rewind':
        await controller.seekRelative(
          Duration(seconds: -_settings.seekBackwardSeconds),
          source: SeekSource.remote,
        );
      case 'fastforward':
        await controller.seekRelative(
          Duration(seconds: _settings.seekForwardSeconds),
          source: SeekSource.remote,
        );
      default:
        DiagnosticLog.instance.info(
          'realtime',
          'event=remote_playstate_unsupported',
        );
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_error != null || _duration == Duration.zero) return;

    _controlsTimer?.cancel();
    _seekGestureGeneration++;
    setState(() {
      _horizontalDragStartPosition = _position;
      _horizontalDragPreviewPosition = _position;
      _horizontalDragDx = 0;
      _seeking = true;
      _controlsVisible = false;
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final startPosition = _horizontalDragStartPosition;
    if (startPosition == null) return;

    final screenWidth = MediaQuery.sizeOf(context).width;
    if (screenWidth <= 0) return;

    _horizontalDragDx += details.delta.dx;
    final offsetSeconds = (_horizontalDragDx / screenWidth * 120).round();
    final target = _clampPosition(
      startPosition + Duration(seconds: offsetSeconds),
    );
    setState(() {
      _horizontalDragPreviewPosition = target;
      _position = target;
    });
  }

  Future<void> _onHorizontalDragEnd(DragEndDetails details) async {
    final startPosition = _horizontalDragStartPosition;
    final target = _horizontalDragPreviewPosition;
    if (startPosition == null || target == null) return;
    final gestureGeneration = _seekGestureGeneration;

    setState(() {
      _horizontalDragStartPosition = null;
      _horizontalDragPreviewPosition = null;
      _horizontalDragDx = 0;
      _seeking = false;
      _controlsVisible = true;
    });

    var seekSucceeded = false;
    try {
      final controller = _playbackController;
      if (controller == null) return;
      final result = await controller.seekAbsolute(
        target,
        source: SeekSource.horizontalDrag,
      );
      seekSucceeded = result.disposition == SeekDisposition.executed;
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_seek_ui_failed errorType=${error.runtimeType}',
      );
    }

    if (!mounted || gestureGeneration != _seekGestureGeneration) return;
    setState(() {
      if (!seekSucceeded) _position = startPosition;
    });
    _restartControlsTimer();
  }

  void _onHorizontalDragCancel() {
    final startPosition = _horizontalDragStartPosition;
    if (startPosition == null) return;

    _seekGestureGeneration++;
    setState(() {
      _position = startPosition;
      _horizontalDragStartPosition = null;
      _horizontalDragPreviewPosition = null;
      _horizontalDragDx = 0;
      _seeking = false;
      _controlsVisible = true;
    });
    _restartControlsTimer();
  }

  Duration _clampPosition(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    if (position > _duration) return _duration;
    return position;
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    if (size.width == _lastMetricsWidth && size.height == _lastMetricsHeight) {
      return;
    }
    _lastMetricsWidth = size.width;
    _lastMetricsHeight = size.height;
    _logPlayerEvent(
      PlayerDiagnosticEvent.orientationMetricsChanged,
      logicalWidth: size.width,
      logicalHeight: size.height,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != _lastLifecycleState) {
      _lastLifecycleState = state;
      _logPlayerEvent(
        PlayerDiagnosticEvent.appLifecycleChanged,
        lifecycleState: state.name,
      );
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_pipController.isActive || _pipController.isEntering) return;
      final controller = _playbackController;
      if (controller != null) unawaited(controller.pauseForLifecycle());
    } else if (state == AppLifecycleState.resumed) {
      final controller = _playbackController;
      if (controller != null) unawaited(controller.resumeForLifecycle());
    }
  }

  @override
  void didHaveMemoryPressure() {
    final controller = _playbackController;
    if (controller != null) unawaited(controller.handleMemoryPressure());
  }

  @override
  void dispose() {
    _logPlayerEvent(
      PlayerDiagnosticEvent.playerRouteDispose,
      exitReason: PlayerExitReason.routeDisposed,
    );
    WidgetsBinding.instance.removeObserver(this);
    if (!_playbackResourcesReleased) {
      unawaited(_stopPlaybackForClose());
      unawaited(_restoreAfterPlayback().catchError((_) {}));
    }
    super.dispose();
  }

  void _logPlayerEvent(
    PlayerDiagnosticEvent event, {
    PlayerExitReason? exitReason,
    PlayerOrientationPolicy? orientationPolicy,
    double? logicalWidth,
    double? logicalHeight,
    String? lifecycleState,
    PlayerDiagnosticErrorType? errorType,
  }) {
    try {
      DiagnosticLog.instance.playerEvent(
        event: event,
        exitReason: exitReason,
        orientationPolicy: orientationPolicy,
        logicalWidth: logicalWidth,
        logicalHeight: logicalHeight,
        lifecycleState: lifecycleState,
        errorType: errorType,
      );
    } catch (_) {
      // Diagnostics must not affect playback or route cleanup.
    }
  }

  Future<void> _patchSettings(PlaybackSettingsPatch patch) async {
    final snapshot = await _settingsRepository.patch(widget.api.session, patch);
    if (mounted) {
      setState(() {
        _settings = snapshot.settings;
        _videoFit = _boxFit(snapshot.settings.videoFit);
      });
    }
  }

  Future<void> _changeMaximumBitrate(int bitrate) async {
    final controller = _playbackController;
    if (controller == null || bitrate == _settings.maxStreamingBitrate) return;
    await _patchSettings(PlaybackSettingsPatch(maxStreamingBitrate: bitrate));
    await controller.setMaximumBitrate(bitrate);
  }

  Future<void> _changePlaybackRate(double rate) async {
    final controller = _playbackController;
    if (controller == null) return;
    await controller.setPlaybackRate(rate);
    await _patchSettings(PlaybackSettingsPatch(playbackRate: rate));
  }

  Future<void> _changeVideoFit(String fit) =>
      _patchSettings(PlaybackSettingsPatch(videoFit: fit));

  Future<void> _changeAudioDelay(int milliseconds) async {
    await _playbackController?.setAudioDelay(
      Duration(milliseconds: milliseconds),
    );
    await _patchSettings(
      PlaybackSettingsPatch(audioDelayMilliseconds: milliseconds),
    );
  }

  Future<void> _changeSubtitleDelay(int milliseconds) async {
    await _playbackController?.setSubtitleDelay(
      Duration(milliseconds: milliseconds),
    );
    await _patchSettings(
      PlaybackSettingsPatch(subtitleDelayMilliseconds: milliseconds),
    );
  }

  Future<void> _changeSubtitleStyle(PlaybackSettings settings) async {
    await _playbackController?.configureSubtitleStyle(
      fontSize: settings.subtitleFontSize,
      color: settings.subtitleColor,
      outlineColor: settings.subtitleOutlineColor,
      position: settings.subtitlePosition,
    );
    await _patchSettings(
      PlaybackSettingsPatch(
        subtitleFontSize: settings.subtitleFontSize,
        subtitleColor: settings.subtitleColor,
        subtitleOutlineColor: settings.subtitleOutlineColor,
        subtitlePosition: settings.subtitlePosition,
      ),
    );
  }

  BoxFit _boxFit(String value) => switch (value) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    _ => BoxFit.contain,
  };

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  void _onDoubleTap() {
    if (_controlsLocked) return;
    final position = _doubleTapPosition;
    if (position == null) return;
    final width = MediaQuery.sizeOf(context).width;
    final seconds = position.dx < width / 2
        ? -_settings.seekBackwardSeconds
        : _settings.seekForwardSeconds;
    unawaited(
      _seekRelative(Duration(seconds: seconds), source: SeekSource.doubleTap),
    );
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_controlsLocked || details.localPosition.dy < 32) return;
    _verticalDragIsBrightness =
        details.localPosition.dx < MediaQuery.sizeOf(context).width / 2;
    if (_verticalDragIsBrightness
        ? !_safeSystemControls.brightnessAvailable
        : !_safeSystemControls.volumeAvailable) {
      return;
    }
    _verticalDragStartY = details.localPosition.dy;
    unawaited(_loadVerticalDragValue());
  }

  Future<void> _loadVerticalDragValue() async {
    final isBrightness = _verticalDragIsBrightness;
    if (isBrightness
        ? !_safeSystemControls.brightnessAvailable
        : !_safeSystemControls.volumeAvailable) {
      return;
    }
    final value = isBrightness
        ? await _safeSystemControls.readBrightness()
        : await _safeSystemControls.readVolume();
    if (!mounted || _verticalDragStartY == null || value == null) return;
    setState(() {
      _verticalDragStartValue = value;
      _verticalDragValue = value;
      _controlsVisible = false;
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final startY = _verticalDragStartY;
    final startValue = _verticalDragStartValue;
    if (startY == null || startValue == null) return;
    if (_verticalDragIsBrightness
        ? !_safeSystemControls.brightnessAvailable
        : !_safeSystemControls.volumeAvailable) {
      return;
    }
    final height = MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    final value = (startValue + (startY - details.localPosition.dy) / height)
        .clamp(0.0, 1.0)
        .toDouble();
    setState(() => _verticalDragValue = value);
    if (_verticalDragIsBrightness) {
      unawaited(_setBrightnessSafely(value));
    } else {
      unawaited(_setVolumeSafely(value));
    }
  }

  Future<void> _setBrightnessSafely(double value) async {
    await _safeSystemControls.setBrightness(value);
  }

  Future<void> _setVolumeSafely(double value) async {
    await _safeSystemControls.setVolume(value);
  }

  Future<void> _resetBrightnessSafely() async {
    await _safeSystemControls.resetBrightness();
  }

  void _handleSystemControlFailure({
    required bool brightness,
    required Object error,
  }) {
    var shouldReport = false;
    if (brightness) {
      shouldReport = !_brightnessFailureReported;
      _brightnessFailureReported = true;
    } else {
      shouldReport = !_volumeFailureReported;
      _volumeFailureReported = true;
    }
    if (shouldReport) {
      DiagnosticLog.instance.warning(
        'player',
        '${brightness ? 'Brightness' : 'Volume'} control disabled '
            'after plugin failure errorType=${error.runtimeType}',
      );
    }

    void clearDrag() {
      _verticalDragStartValue = null;
      _verticalDragValue = null;
      _verticalDragStartY = null;
      _controlsVisible = true;
    }

    if (mounted) {
      setState(clearDrag);
    } else {
      clearDrag();
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_verticalDragStartY == null) return;
    setState(() {
      _verticalDragStartValue = null;
      _verticalDragValue = null;
      _verticalDragStartY = null;
      _controlsVisible = true;
    });
    _restartControlsTimer();
  }

  void _onVerticalDragCancel() {
    if (_verticalDragStartY == null) return;
    setState(() {
      _verticalDragStartValue = null;
      _verticalDragValue = null;
      _verticalDragStartY = null;
      _controlsVisible = true;
    });
    _restartControlsTimer();
  }

  void _updateTimelineOverlays() {
    final introStart = _chapterMarker('introstart')?.position;
    final introEnd = _chapterMarker('introend')?.position;
    final showSkipIntro =
        introStart != null &&
        introEnd != null &&
        _position >= introStart &&
        _position < introEnd;
    if (showSkipIntro != _showSkipIntro && mounted) {
      setState(() => _showSkipIntro = showSkipIntro);
    }

    if (_autoNextCancelled ||
        _nextCountdown != null ||
        !_queue.canPotentiallyAdvance(_currentItem)) {
      return;
    }
    final creditsStart = _chapterMarker('creditsstart')?.position;
    final remaining = _duration - _position;
    final isCredits =
        creditsStart != null &&
        _position >= creditsStart &&
        _position < _duration;
    final isNearEnd =
        _duration > Duration.zero &&
        remaining > Duration.zero &&
        remaining <= const Duration(seconds: 20);
    if (isCredits || isNearEnd) _startNextCountdown();
  }

  EmbyChapter? _chapterMarker(String markerType) => _currentItem.chapters
      .where(
        (chapter) =>
            chapter.markerType?.toLowerCase() == markerType.toLowerCase(),
      )
      .firstOrNull;

  void _skipIntro() {
    final end = _chapterMarker('introend')?.position;
    if (end != null) {
      unawaited(_seekAbsolute(end, source: SeekSource.skipIntro));
    }
  }

  void _startNextCountdown() {
    if (_nextCountdown != null || _autoNextCancelled) return;
    setState(() => _nextCountdown = 10);
    _nextCountdownTimer?.cancel();
    _nextCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final value = _nextCountdown;
      if (value == null) {
        timer.cancel();
      } else if (value <= 1) {
        timer.cancel();
        setState(() => _nextCountdown = null);
        unawaited(_playNext(automatic: true));
      } else {
        setState(() => _nextCountdown = value - 1);
      }
    });
  }

  void _cancelAutoNext() {
    _nextCountdownTimer?.cancel();
    setState(() {
      _nextCountdown = null;
      _autoNextCancelled = true;
    });
  }

  Future<void> _handleCompleted() async {
    if (_switchingItem || _autoNextCancelled) return;
    _nextCountdownTimer?.cancel();
    if (mounted) setState(() => _nextCountdown = null);
    await _playNext(automatic: true);
  }

  Future<void> _playNext({bool automatic = false}) async {
    if (_switchingItem) return;
    if (automatic && _autoPlayedCount >= 3) {
      final keepWatching = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('还在观看吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('暂停连播'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('继续播放'),
            ),
          ],
        ),
      );
      if (keepWatching != true) {
        if (mounted) setState(() => _autoNextCancelled = true);
        return;
      }
      _autoPlayedCount = 0;
    }

    late final EmbyItem? next;
    try {
      next = await _queue.next(_currentItem);
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_queue_load_failed errorType=${error.runtimeType}',
      );
      if (mounted) {
        _cancelAutoNext();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放队列加载失败，请稍后重试')));
      }
      return;
    }
    if (!mounted) return;
    if (next == null) {
      _cancelAutoNext();
      if (automatic) await _closePlayer(PlayerExitReason.completed);
      return;
    }
    if (automatic) _autoPlayedCount++;
    await _switchToItem(next);
  }

  Future<void> _playPrevious() async {
    final previous = _queue.previous(_currentItem);
    if (previous != null) await _switchToItem(previous);
  }

  Future<void> _switchToItem(EmbyItem item) async {
    if (_switchingItem || item.id == _currentItem.id) return;
    _switchingItem = true;
    _nextCountdownTimer?.cancel();
    try {
      await _playerSessionCoordinator.switchItem(
        closeCurrent: () async {
          final previousController = _playbackController;
          if (previousController == null) return;
          previousController.removeListener(_syncPlaybackState);
          await previousController.shutdown();
          previousController.dispose();
        },
        openNext: (session) async {
          if (!mounted) return;
          _itemSession = session;
          _createPlayer();
          setState(() {
            _currentItem = item;
            _playbackController = null;
            _plan = null;
            _position = Duration.zero;
            _progressSeekStartPosition = null;
            _duration = Duration.zero;
            _buffer = Duration.zero;
            _playing = false;
            _buffering = true;
            _completed = false;
            _error = null;
            _playbackStatus = null;
            _showSkipIntro = false;
            _autoNextCancelled = false;
            _nextCountdown = null;
            _controlsVisible = true;
            _seekGestureGeneration++;
          });
          await _startCurrentItem();
        },
      );
    } finally {
      _switchingItem = false;
    }
  }

  Future<void> _showPlaybackOptions() async {
    final controller = _playbackController;
    final plan = controller?.state.plan;
    if (controller == null || plan == null) return;
    _controlsTimer?.cancel();
    final audioTracks = _trackMapper.fromPlan(plan, 'audio');
    final subtitleTracks = _trackMapper.fromPlan(plan, 'subtitle');
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171A1C),
      isScrollControlled: true,
      builder: (sheetContext) => DefaultTabController(
        length: 5,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.82,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: '画质'),
                    Tab(text: '音轨'),
                    Tab(text: '字幕'),
                    Tab(text: '章节'),
                    Tab(text: '播放'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildQualityOptions(sheetContext, plan),
                      _buildAudioOptions(sheetContext, plan, audioTracks),
                      _buildSubtitleOptions(sheetContext, plan, subtitleTracks),
                      _buildChapterOptions(sheetContext),
                      _buildPlayerOptions(sheetContext),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _restartControlsTimer();
  }

  Future<void> _enterPictureInPicture() async {
    try {
      final supported = await _pipController.isSupported;
      if (!supported || !mounted) return;
      await _pipController.enter(isPlaying: _playing);
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_pip_enter_failed errorType=${error.runtimeType}',
      );
    }
  }

  Widget _buildQualityOptions(BuildContext sheetContext, PlaybackPlan plan) {
    const bitrates = <(int, String)>[
      (120000000, '原画'),
      (40000000, '40 Mbps'),
      (20000000, '20 Mbps'),
      (10000000, '10 Mbps'),
      (5000000, '5 Mbps'),
      (2000000, '2 Mbps'),
    ];
    return ListView(
      children: [
        for (final source in plan.availableMediaSources)
          ListTile(
            leading: const Icon(Icons.video_file_outlined),
            title: Text(source.name ?? source.id),
            subtitle: Text(
              [
                if (source.container != null) source.container!.toUpperCase(),
                if (source.bitrate != null)
                  '${(source.bitrate! / 1000000).toStringAsFixed(1)} Mbps',
              ].join(' · '),
            ),
            trailing: source.id == plan.mediaSourceId
                ? const Icon(Icons.check, color: Color(0xFF80CBC4))
                : null,
            onTap: source.id == plan.mediaSourceId
                ? null
                : () {
                    Navigator.pop(sheetContext);
                    unawaited(
                      _playbackController?.selectMediaSource(source.id),
                    );
                  },
          ),
        const Divider(),
        for (final option in bitrates)
          ListTile(
            leading: const Icon(Icons.network_check),
            title: Text(option.$2),
            trailing: option.$1 == _settings.maxStreamingBitrate
                ? const Icon(Icons.check, color: Color(0xFF80CBC4))
                : null,
            onTap: option.$1 == _settings.maxStreamingBitrate
                ? null
                : () {
                    Navigator.pop(sheetContext);
                    unawaited(_changeMaximumBitrate(option.$1));
                  },
          ),
      ],
    );
  }

  Widget _buildAudioOptions(
    BuildContext sheetContext,
    PlaybackPlan plan,
    List<PlaybackTrack> tracks,
  ) => ListView(
    children: [
      for (final track in tracks)
        ListTile(
          leading: const Icon(Icons.audiotrack),
          title: Text(track.title ?? track.language ?? '音轨 ${track.index}'),
          subtitle: Text(
            [
              ?track.language,
              ?track.codec?.toUpperCase(),
              if (track.channels != null) '${track.channels} 声道',
              if (track.isDefault) '默认',
            ].join(' · '),
          ),
          trailing: track.index == plan.audioStreamIndex
              ? const Icon(Icons.check, color: Color(0xFF80CBC4))
              : null,
          onTap: track.index == plan.audioStreamIndex
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    _playbackController?.selectAudioStream(track.index),
                  );
                },
        ),
    ],
  );

  Widget _buildSubtitleOptions(
    BuildContext sheetContext,
    PlaybackPlan plan,
    List<PlaybackTrack> tracks,
  ) => ListView(
    children: [
      ListTile(
        leading: const Icon(Icons.subtitles_off_outlined),
        title: const Text('关闭字幕'),
        trailing: plan.subtitleStreamIndex == null
            ? const Icon(Icons.check, color: Color(0xFF80CBC4))
            : null,
        onTap: plan.subtitleStreamIndex == null
            ? null
            : () {
                Navigator.pop(sheetContext);
                unawaited(_playbackController?.selectSubtitleStream(null));
              },
      ),
      for (final track in tracks)
        ListTile(
          leading: Icon(
            track.isExternal
                ? Icons.closed_caption_outlined
                : Icons.subtitles_outlined,
          ),
          title: Text(track.title ?? track.language ?? '字幕 ${track.index}'),
          subtitle: Text(
            [
              ?track.language,
              ?track.codec?.toUpperCase(),
              if (track.isForced) '强制',
              if (track.isDefault) '默认',
              if (track.isExternal) '外挂',
            ].join(' · '),
          ),
          trailing: track.index == plan.subtitleStreamIndex
              ? const Icon(Icons.check, color: Color(0xFF80CBC4))
              : null,
          onTap: track.index == plan.subtitleStreamIndex
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    _playbackController?.selectSubtitleStream(track.index),
                  );
                },
        ),
    ],
  );

  Widget _buildChapterOptions(BuildContext sheetContext) => ListView(
    children: [
      for (var index = 0; index < _currentItem.chapters.length; index++)
        ListTile(
          leading: const Icon(Icons.bookmark_outline),
          title: Text(_currentItem.chapters[index].name),
          subtitle: Text(
            _formatDuration(_currentItem.chapters[index].position),
          ),
          trailing:
              _position >= _currentItem.chapters[index].position &&
                  (index == _currentItem.chapters.length - 1 ||
                      _position < _currentItem.chapters[index + 1].position)
              ? const Icon(Icons.play_arrow, color: Color(0xFF80CBC4))
              : null,
          onTap: () {
            Navigator.pop(sheetContext);
            unawaited(
              _seekAbsolute(
                _currentItem.chapters[index].position,
                source: SeekSource.chapter,
              ),
            );
          },
        ),
    ],
  );

  Widget _buildPlayerOptions(BuildContext sheetContext) {
    final controller = _playbackController;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        children: [
          const Text('播放速度'),
          const SizedBox(height: 8),
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 0.5, label: Text('0.5×')),
              ButtonSegment(value: 1, label: Text('1×')),
              ButtonSegment(value: 1.5, label: Text('1.5×')),
              ButtonSegment(value: 2, label: Text('2×')),
            ],
            selected: {_settings.playbackRate},
            onSelectionChanged: (values) {
              Navigator.pop(sheetContext);
              unawaited(_changePlaybackRate(values.single));
            },
          ),
          const SizedBox(height: 22),
          const Text('画面模式'),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'contain',
                icon: Icon(Icons.fit_screen),
                label: Text('适应'),
              ),
              ButtonSegment(
                value: 'cover',
                icon: Icon(Icons.crop),
                label: Text('裁剪'),
              ),
              ButtonSegment(
                value: 'fill',
                icon: Icon(Icons.aspect_ratio),
                label: Text('填充'),
              ),
            ],
            selected: {_settings.videoFit},
            onSelectionChanged: (values) {
              Navigator.pop(sheetContext);
              unawaited(_changeVideoFit(values.single));
            },
          ),
          const SizedBox(height: 22),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fast_rewind),
            title: const Text('快退时长'),
            trailing: DropdownButton<int>(
              value: _settings.seekBackwardSeconds,
              items: const [
                DropdownMenuItem(value: 5, child: Text('5 秒')),
                DropdownMenuItem(value: 10, child: Text('10 秒')),
                DropdownMenuItem(value: 15, child: Text('15 秒')),
                DropdownMenuItem(value: 30, child: Text('30 秒')),
              ],
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  _patchSettings(
                    PlaybackSettingsPatch(seekBackwardSeconds: value),
                  ),
                );
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fast_forward),
            title: const Text('快进时长'),
            trailing: DropdownButton<int>(
              value: _settings.seekForwardSeconds,
              items: const [
                DropdownMenuItem(value: 5, child: Text('5 秒')),
                DropdownMenuItem(value: 10, child: Text('10 秒')),
                DropdownMenuItem(value: 15, child: Text('15 秒')),
                DropdownMenuItem(value: 30, child: Text('30 秒')),
              ],
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  _patchSettings(
                    PlaybackSettingsPatch(seekForwardSeconds: value),
                  ),
                );
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.graphic_eq),
            title: const Text('音频延迟'),
            trailing: DropdownButton<int>(
              value: _settings.audioDelayMilliseconds,
              items: const [
                DropdownMenuItem(value: -1000, child: Text('-1.0 秒')),
                DropdownMenuItem(value: -500, child: Text('-0.5 秒')),
                DropdownMenuItem(value: 0, child: Text('0 秒')),
                DropdownMenuItem(value: 500, child: Text('+0.5 秒')),
                DropdownMenuItem(value: 1000, child: Text('+1.0 秒')),
              ],
              onChanged: (value) {
                if (value != null) unawaited(_changeAudioDelay(value));
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.subtitles),
            title: const Text('字幕延迟'),
            trailing: DropdownButton<int>(
              value: _settings.subtitleDelayMilliseconds,
              items: const [
                DropdownMenuItem(value: -1000, child: Text('-1.0 秒')),
                DropdownMenuItem(value: -500, child: Text('-0.5 秒')),
                DropdownMenuItem(value: 0, child: Text('0 秒')),
                DropdownMenuItem(value: 500, child: Text('+0.5 秒')),
                DropdownMenuItem(value: 1000, child: Text('+1.0 秒')),
              ],
              onChanged: (value) {
                if (value != null) unawaited(_changeSubtitleDelay(value));
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.format_size),
            title: const Text('字幕字号'),
            trailing: DropdownButton<double>(
              value: _settings.subtitleFontSize,
              items: const [
                DropdownMenuItem(value: 32, child: Text('小')),
                DropdownMenuItem(value: 42, child: Text('中')),
                DropdownMenuItem(value: 52, child: Text('大')),
                DropdownMenuItem(value: 64, child: Text('特大')),
              ],
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  _changeSubtitleStyle(
                    _settings.copyWith(subtitleFontSize: value),
                  ),
                );
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.vertical_align_bottom),
            title: const Text('字幕位置'),
            trailing: DropdownButton<int>(
              value: _settings.subtitlePosition,
              items: const [
                DropdownMenuItem(value: 75, child: Text('偏上')),
                DropdownMenuItem(value: 88, child: Text('居中')),
                DropdownMenuItem(value: 100, child: Text('底部')),
              ],
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  _changeSubtitleStyle(
                    _settings.copyWith(subtitlePosition: value),
                  ),
                );
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.palette_outlined),
            title: const Text('字幕颜色'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final color in const [0xFFFFFFFF, 0xFFFFFF00, 0xFF80CBC4])
                  IconButton(
                    tooltip: switch (color) {
                      0xFFFFFF00 => '黄色',
                      0xFF80CBC4 => '青色',
                      _ => '白色',
                    },
                    onPressed: () => unawaited(
                      _changeSubtitleStyle(
                        _settings.copyWith(subtitleColor: color),
                      ),
                    ),
                    icon: Icon(
                      color == _settings.subtitleColor
                          ? Icons.check_circle
                          : Icons.circle,
                      color: Color(color),
                    ),
                  ),
              ],
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.format_color_text),
            title: const Text('字幕描边'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final color in const [0xFF000000, 0xFF404040, 0xFFFFFFFF])
                  IconButton(
                    tooltip: switch (color) {
                      0xFF404040 => '深灰',
                      0xFFFFFFFF => '白色',
                      _ => '黑色',
                    },
                    onPressed: () => unawaited(
                      _changeSubtitleStyle(
                        _settings.copyWith(subtitleOutlineColor: color),
                      ),
                    ),
                    icon: Icon(
                      color == _settings.subtitleOutlineColor
                          ? Icons.check_circle
                          : Icons.circle,
                      color: Color(color),
                      shadows: const [
                        Shadow(color: Colors.white54, blurRadius: 2),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          PlaybackCacheStatusSection(
            settings: _settings.cache,
            state: controller.state,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final horizontalSeekEnabled =
        !_controlsLocked && _error == null && _duration > Duration.zero;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_closePlayer(PlayerExitReason.systemBack));
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTapDown: _onDoubleTapDown,
          onDoubleTap: _onDoubleTap,
          onHorizontalDragStart: horizontalSeekEnabled
              ? _onHorizontalDragStart
              : null,
          onHorizontalDragUpdate: horizontalSeekEnabled
              ? _onHorizontalDragUpdate
              : null,
          onHorizontalDragEnd: horizontalSeekEnabled
              ? _onHorizontalDragEnd
              : null,
          onHorizontalDragCancel: horizontalSeekEnabled
              ? _onHorizontalDragCancel
              : null,
          onVerticalDragStart: _controlsLocked ? null : _onVerticalDragStart,
          onVerticalDragUpdate: _controlsLocked ? null : _onVerticalDragUpdate,
          onVerticalDragEnd: _controlsLocked ? null : _onVerticalDragEnd,
          onVerticalDragCancel: _controlsLocked ? null : _onVerticalDragCancel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Video(
                  controller: _videoController,
                  fit: _videoFit,
                  controls: NoVideoControls,
                ),
              ),
              if (_buffering && _error == null) _buildBuffering(),
              if (_error != null) _buildError(),
              IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: _buildControls(),
                ),
              ),
              if (_horizontalDragPreviewPosition != null)
                _buildHorizontalSeekOverlay(),
              if (_verticalDragValue != null) _buildVerticalGestureOverlay(),
              if (_showSkipIntro && !_controlsLocked)
                Positioned(
                  right: 22,
                  bottom: 92,
                  child: FilledButton.icon(
                    onPressed: _skipIntro,
                    icon: const Icon(Icons.skip_next),
                    label: const Text('跳过片头'),
                  ),
                ),
              if (_nextCountdown != null && !_controlsLocked)
                _buildNextEpisodeCountdown(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalSeekOverlay() {
    final startPosition = _horizontalDragStartPosition!;
    final target = _horizontalDragPreviewPosition!;
    final deltaSeconds = target.inSeconds - startPosition.inSeconds;
    final isForward = _horizontalDragDx >= 0;
    final deltaLabel = deltaSeconds > 0
        ? '+$deltaSeconds 秒'
        : '$deltaSeconds 秒';
    final preview = _trickplayPreview(target);

    return IgnorePointer(
      child: Center(
        child: Container(
          constraints: const BoxConstraints(minWidth: 180),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xCC111315),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (preview != null) ...[
                SizedBox(
                  width: 240,
                  child: TrickplayPreview(
                    image: NetworkImage(
                      preview.url.toString(),
                      headers: widget.api.playbackHeaders,
                    ),
                    thumbnailWidth: preview.info.width,
                    thumbnailHeight: preview.info.height,
                    columns: preview.info.tileColumns,
                    rows: preview.info.tileRows,
                    column: preview.column,
                    row: preview.row,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Icon(
                isForward
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                size: 36,
                color: Colors.white,
              ),
              const SizedBox(height: 6),
              Text(
                deltaLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_formatDuration(target)} / ${_formatDuration(_duration)}',
                style: const TextStyle(color: Color(0xFFD0D5D6), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({EmbyTrickplayResolution info, Uri url, int column, int row})?
  _trickplayPreview(Duration position) {
    final plan = _plan;
    final info = _currentItem.trickplay?.resolutionFor(plan?.mediaSourceId);
    if (plan == null || info == null) return null;
    final tileIndex = position.inMilliseconds ~/ info.intervalMilliseconds;
    final imageIndex = tileIndex ~/ info.tilesPerImage;
    final tileOffset = tileIndex % info.tilesPerImage;
    return (
      info: info,
      url: widget.api.trickplayTileUrl(
        itemId: _currentItem.id,
        width: info.width,
        imageIndex: imageIndex,
        mediaSourceId: plan.mediaSourceId,
      ),
      column: tileOffset % info.tileColumns,
      row: tileOffset ~/ info.tileColumns,
    );
  }

  Widget _buildVerticalGestureOverlay() {
    final value = _verticalDragValue ?? 0;
    return IgnorePointer(
      child: Align(
        alignment: _verticalDragIsBrightness
            ? Alignment.centerLeft
            : Alignment.centerRight,
        child: Container(
          width: 72,
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xCC111315),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _verticalDragIsBrightness
                    ? Icons.brightness_6
                    : Icons.volume_up,
                color: Colors.white,
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 120,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: LinearProgressIndicator(value: value),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(value * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNextEpisodeCountdown() {
    return Positioned(
      right: 22,
      bottom: 88,
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xE6171A1C),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF3A4447)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$_nextCountdown 秒后播放下一集',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(onPressed: _cancelAutoNext, child: const Text('取消')),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    _nextCountdownTimer?.cancel();
                    setState(() => _nextCountdown = null);
                    unawaited(_playNext());
                  },
                  child: const Text('立即播放'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 42,
                color: Color(0xFFFFA49C),
              ),
              const SizedBox(height: 14),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                '详细信息已写入诊断日志',
                style: TextStyle(color: Color(0xFFADB5B7)),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () =>
                    unawaited(_closePlayer(PlayerExitReason.playbackError)),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBuffering() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (_playbackStatus != null) ...[
            const SizedBox(height: 16),
            Text(
              _playbackStatus!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControls() {
    final maxMs = _duration.inMilliseconds
        .toDouble()
        .clamp(1.0, double.infinity)
        .toDouble();
    final positionMs = _position.inMilliseconds
        .toDouble()
        .clamp(0.0, maxMs)
        .toDouble();
    final bufferMs = _buffer.inMilliseconds
        .toDouble()
        .clamp(positionMs, maxMs)
        .toDouble();
    if (_controlsLocked) {
      return ColoredBox(
        color: const Color(0x22000000),
        child: SafeArea(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: IconButton.filledTonal(
                tooltip: '解锁控制',
                onPressed: () => setState(() => _controlsLocked = false),
                icon: const Icon(Icons.lock),
              ),
            ),
          ),
        ),
      );
    }
    return ColoredBox(
      color: const Color(0x55000000),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 4,
              left: 6,
              right: 12,
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () =>
                        unawaited(_closePlayer(PlayerExitReason.userBack)),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentItem.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_plan != null)
                    Text(
                      switch (_plan!.method) {
                        PlayMethod.directPlay => '直接播放',
                        PlayMethod.directStream => '直接串流',
                        PlayMethod.transcode => '转码',
                      },
                      style: const TextStyle(
                        color: Color(0xFFD0D5D6),
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(width: 8),
                  if (_capabilities.supportsPictureInPicture)
                    IconButton(
                      tooltip: '画中画',
                      onPressed: _enterPictureInPicture,
                      icon: const Icon(Icons.picture_in_picture_alt),
                    ),
                  IconButton(
                    tooltip: '播放设置',
                    onPressed: _showPlaybackOptions,
                    icon: const Icon(Icons.tune),
                  ),
                  IconButton(
                    tooltip: '锁定控制',
                    onPressed: () {
                      setState(() {
                        _controlsLocked = true;
                        _controlsVisible = true;
                      });
                      _controlsTimer?.cancel();
                    },
                    icon: const Icon(Icons.lock_open),
                  ),
                ],
              ),
            ),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '上一集',
                    iconSize: 28,
                    onPressed: _queue.previous(_currentItem) == null
                        ? null
                        : _playPrevious,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '后退 ${_settings.seekBackwardSeconds} 秒',
                    iconSize: 34,
                    onPressed: () => _seekRelative(
                      Duration(seconds: -_settings.seekBackwardSeconds),
                    ),
                    icon: const Icon(Icons.fast_rewind),
                  ),
                  const SizedBox(width: 22),
                  IconButton.filled(
                    tooltip: _playing ? '暂停' : '播放',
                    iconSize: 40,
                    onPressed: _togglePlay,
                    icon: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                  ),
                  const SizedBox(width: 22),
                  IconButton(
                    tooltip: '前进 ${_settings.seekForwardSeconds} 秒',
                    iconSize: 34,
                    onPressed: () => _seekRelative(
                      Duration(seconds: _settings.seekForwardSeconds),
                    ),
                    icon: const Icon(Icons.fast_forward),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '下一集',
                    iconSize: 28,
                    onPressed: _queue.canPotentiallyAdvance(_currentItem)
                        ? _playNext
                        : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 8,
              child: Column(
                children: [
                  Slider(
                    min: 0,
                    max: maxMs,
                    value: positionMs,
                    secondaryTrackValue: bufferMs,
                    onChangeStart: (_) {
                      _seekGestureGeneration++;
                      setState(() {
                        _progressSeekStartPosition = _position;
                        _seeking = true;
                      });
                    },
                    onChanged: (value) {
                      setState(
                        () => _position = Duration(milliseconds: value.round()),
                      );
                    },
                    onChangeEnd: (value) async {
                      final controller = _playbackController;
                      final gestureGeneration = _seekGestureGeneration;
                      final startPosition =
                          _progressSeekStartPosition ?? _position;
                      final target = Duration(milliseconds: value.round());
                      setState(() => _seeking = false);
                      SeekResult? result;
                      try {
                        result = await controller?.seekAbsolute(
                          target,
                          source: SeekSource.progressBar,
                        );
                      } catch (error) {
                        DiagnosticLog.instance.warning(
                          'player',
                          'event=playback_seek_ui_failed '
                              'errorType=${error.runtimeType}',
                        );
                      }
                      if (!mounted ||
                          gestureGeneration != _seekGestureGeneration) {
                        return;
                      }
                      setState(() {
                        _progressSeekStartPosition = null;
                        _position = resolveCompletedSeekDisplayPosition(
                          startPosition: startPosition,
                          requestedTarget: target,
                          result: result,
                        );
                      });
                      _restartControlsTimer();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Text(_formatDuration(_position)),
                        const Spacer(),
                        Text(_formatDuration(_duration)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
