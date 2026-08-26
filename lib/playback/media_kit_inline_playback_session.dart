import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'cache/playback_cache_storage.dart';
import 'inline_playback_session.dart';
import 'playback_controller.dart';
import 'playback_diagnostics_test_overrides.dart';
import 'playback_engine.dart';
import 'playback_operation_coordinator.dart';
import 'playback_session_bootstrap.dart';
import 'playback_settings.dart';

class MediaKitInlinePlaybackSession extends ChangeNotifier
    implements InlinePlaybackSession {
  MediaKitInlinePlaybackSession._({
    required this.itemId,
    required PlaybackItemSession itemSession,
    required VideoController videoController,
    required PlaybackController controller,
    required PlaybackSettings settings,
  }) : _itemSession = itemSession,
       _videoController = videoController,
       _controller = controller,
       _settings = settings,
       _state = InlinePlaybackState(
         itemId: itemId,
         videoController: videoController,
       ) {
    _controller.addListener(_syncControllerState);
  }

  static Future<MediaKitInlinePlaybackSession> create({
    required EmbyApi api,
    required EmbyItem item,
    required PlaybackSettings settings,
    PlaybackCacheStorage? cacheStorage,
    PlaybackDiagnosticsTestOverrides? testOverrides,
  }) async {
    final itemSession = PlaybackItemSession.create();
    final player = _createPlayer();
    try {
      final videoController = VideoController(player);
      late final MediaKitInlinePlaybackSession result;
      final controller = PlaybackSessionBootstrap.createOnlineController(
        api: api,
        item: item,
        engine: MediaKitPlaybackEngine(player),
        engineRecreator: (_) => result._recreateEngine(),
        session: itemSession,
        settings: settings,
        cacheStorage: cacheStorage,
        testOverrides: testOverrides,
      );
      result = MediaKitInlinePlaybackSession._(
        itemId: item.id,
        itemSession: itemSession,
        videoController: videoController,
        controller: controller,
        settings: settings,
      );
      return result;
    } catch (_) {
      await player.dispose();
      rethrow;
    }
  }

  @override
  final String itemId;
  final PlaybackItemSession _itemSession;
  final PlaybackSettings _settings;
  final PlaybackController _controller;
  VideoController _videoController;
  InlinePlaybackState _state;
  Future<void>? _shutdownOperation;
  bool _shuttingDown = false;
  bool _disposed = false;

  @override
  InlinePlaybackState get state => _state;

  @override
  Future<void> start({Duration? resumePosition}) async {
    _setState(
      _state.copyWith(
        phase: InlinePlaybackPhase.loading,
        isBuffering: true,
        clearError: true,
      ),
    );
    await PlaybackSessionBootstrap.configureAndStart(
      controller: _controller,
      settings: _settings,
      resumePosition: resumePosition,
      playAfterReady: false,
    );
    _syncControllerState();
  }

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seek(Duration position) async {
    await _controller.seekAbsolute(position, source: SeekSource.progressBar);
  }

  @override
  Future<void> handleMemoryPressure() => _controller.handleMemoryPressure();

  @override
  Future<void> shutdown() =>
      _shutdownOperation ??= _shutdownPlaybackController();

  Future<void> _shutdownPlaybackController() async {
    _shuttingDown = true;
    _controller.removeListener(_syncControllerState);
    try {
      await _controller.shutdown();
    } finally {
      _controller.dispose();
      if (!_disposed) {
        _disposed = true;
        super.dispose();
      }
    }
  }

  Future<PlaybackEngine> _recreateEngine() async {
    if (_shuttingDown || _disposed) {
      throw StateError('Inline playback session is closing');
    }
    if (_controller.sessionId != _itemSession.id) {
      throw StateError('Inline playback item session is stale');
    }
    final player = _createPlayer();
    try {
      final videoController = VideoController(player);
      _videoController = videoController;
      _setState(_state.copyWith(videoController: videoController));
      return MediaKitPlaybackEngine(player);
    } catch (_) {
      await player.dispose();
      rethrow;
    }
  }

  void _syncControllerState() {
    if (_shuttingDown || _disposed) return;
    final playback = _controller.state;
    final phase = playback.hasError
        ? InlinePlaybackPhase.failed
        : playback.isReady
        ? InlinePlaybackPhase.ready
        : InlinePlaybackPhase.loading;
    _setState(
      InlinePlaybackState(
        itemId: itemId,
        phase: phase,
        position: playback.displayPosition,
        duration: playback.duration,
        isPlaying: playback.isPlaying,
        isBuffering: playback.isBuffering,
        isCompleted: playback.isCompleted,
        errorMessage: playback.errorMessage,
        videoController: _videoController,
      ),
    );
  }

  void _setState(InlinePlaybackState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(shutdown());
    _disposed = true;
    super.dispose();
  }

  static Player _createPlayer() => Player(
    configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
  );
}
