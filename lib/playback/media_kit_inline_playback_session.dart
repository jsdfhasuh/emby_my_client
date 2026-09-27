import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'cache/playback_cache_storage.dart';
import 'inline_playback_session.dart';
import 'inline_playback_resource_lease.dart';
import 'playback_controller.dart';
import 'playback_diagnostics_test_overrides.dart';
import 'playback_engine.dart';
import 'playback_operation_coordinator.dart';
import 'playback_session_bootstrap.dart';
import 'playback_settings.dart';

typedef InlinePlayerFactory = Player Function();

class MediaKitInlinePlaybackSession extends ChangeNotifier
    implements InlinePlaybackSession {
  MediaKitInlinePlaybackSession._({
    required this.itemId,
    required PlaybackItemSession itemSession,
    required VideoController? videoController,
    required PlaybackController controller,
    required PlaybackSettings settings,
    required InlinePlaybackResourceLease? resourceLease,
    required InlinePlaybackResourceLeaseHandle? resourceLeaseHandle,
    required InlinePlayerFactory playerFactory,
    required PlaybackNativeOperationTimeouts nativeOperationTimeouts,
  }) : _itemSession = itemSession,
       _videoController = videoController,
       _controller = controller,
       _settings = settings,
       _resourceLease = resourceLease,
       _resourceLeaseHandle = resourceLeaseHandle,
       _playerFactory = playerFactory,
       _nativeOperationTimeouts = nativeOperationTimeouts,
       _state = InlinePlaybackState(
         itemId: itemId,
         videoController: videoController,
       ) {
    _controller.addListener(_syncControllerState);
  }

  @visibleForTesting
  MediaKitInlinePlaybackSession.forTesting({
    required String itemId,
    required PlaybackController controller,
  }) : this._(
         itemId: itemId,
         itemSession: controller.session,
         videoController: null,
         controller: controller,
         settings: const PlaybackSettings(),
         resourceLease: null,
         resourceLeaseHandle: null,
         playerFactory: _createPlayer,
         nativeOperationTimeouts: const PlaybackNativeOperationTimeouts(),
       );

  static Future<MediaKitInlinePlaybackSession> create({
    required EmbyApi api,
    required EmbyItem item,
    required PlaybackSettings settings,
    PlaybackCacheStorage? cacheStorage,
    PlaybackDiagnosticsTestOverrides? testOverrides,
    InlinePlaybackResourceLease? resourceLease,
    InlinePlayerFactory? playerFactory,
    PlaybackNativeOperationTimeouts nativeOperationTimeouts =
        const PlaybackNativeOperationTimeouts(),
  }) async {
    final lease = resourceLease ?? InlinePlaybackResourceLease.application;
    final leaseHandle = lease.acquire();
    leaseHandle.ensureCanCreatePlayer();
    final createPlayer = playerFactory ?? _createPlayer;
    final itemSession = PlaybackItemSession.create();
    late final Player player;
    try {
      player = createPlayer();
    } catch (_) {
      lease.release(leaseHandle);
      rethrow;
    }
    try {
      final videoController = VideoController(player);
      late final MediaKitInlinePlaybackSession result;
      final controller = PlaybackSessionBootstrap.createOnlineController(
        entry: 'inline',
        api: api,
        item: item,
        engine: MediaKitPlaybackEngine(
          player,
          nativeOperationTimeouts: nativeOperationTimeouts,
        ),
        engineRecreator: (_) => result._recreateEngine(),
        onEngineDisposalUnconfirmed: () => lease.poison(leaseHandle),
        session: itemSession,
        settings: settings,
        nativeOperationTimeouts: nativeOperationTimeouts,
        cacheStorage: cacheStorage,
        testOverrides: testOverrides,
      );
      result = MediaKitInlinePlaybackSession._(
        itemId: item.id,
        itemSession: itemSession,
        videoController: videoController,
        controller: controller,
        settings: settings,
        resourceLease: lease,
        resourceLeaseHandle: leaseHandle,
        playerFactory: createPlayer,
        nativeOperationTimeouts: nativeOperationTimeouts,
      );
      return result;
    } catch (_) {
      await _disposeUncommittedPlayer(
        player: player,
        lease: lease,
        leaseHandle: leaseHandle,
        nativeOperationTimeouts: nativeOperationTimeouts,
        releaseOnSuccess: true,
      );
      rethrow;
    }
  }

  @override
  final String itemId;
  final PlaybackItemSession _itemSession;
  final PlaybackSettings _settings;
  final PlaybackController _controller;
  final InlinePlaybackResourceLease? _resourceLease;
  final InlinePlaybackResourceLeaseHandle? _resourceLeaseHandle;
  final InlinePlayerFactory _playerFactory;
  final PlaybackNativeOperationTimeouts _nativeOperationTimeouts;
  VideoController? _videoController;
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
  Future<void> quiesce() => _controller.quiesce();

  @override
  Future<void> quiesceForLifecycle() => _controller.quiesceForLifecycle();

  @override
  Future<void> pauseForLifecycle() => _controller.pauseForLifecycle();

  @override
  Future<void> resumeForLifecycle() => _controller.resumeForLifecycle();

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
      final lease = _resourceLease;
      final leaseHandle = _resourceLeaseHandle;
      if (lease != null && leaseHandle != null) {
        if (_controller.retirementState == PlaybackRetirementState.closed &&
            !leaseHandle.isPoisoned) {
          lease.release(leaseHandle);
        } else {
          lease.poison(leaseHandle);
        }
      }
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
    final leaseHandle = _resourceLeaseHandle;
    leaseHandle?.ensureCanCreatePlayer();
    final player = _playerFactory();
    try {
      final videoController = VideoController(player);
      _videoController = videoController;
      _setState(_state.copyWith(videoController: videoController));
      return MediaKitPlaybackEngine(
        player,
        nativeOperationTimeouts: _nativeOperationTimeouts,
      );
    } catch (_) {
      final lease = _resourceLease;
      if (lease != null && leaseHandle != null) {
        await _disposeUncommittedPlayer(
          player: player,
          lease: lease,
          leaseHandle: leaseHandle,
          nativeOperationTimeouts: _nativeOperationTimeouts,
          releaseOnSuccess: false,
        );
      } else {
        await player.dispose();
      }
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

  static Future<void> _disposeUncommittedPlayer({
    required Player player,
    required InlinePlaybackResourceLease lease,
    required InlinePlaybackResourceLeaseHandle leaseHandle,
    required PlaybackNativeOperationTimeouts nativeOperationTimeouts,
    required bool releaseOnSuccess,
  }) async {
    final disposal = PlaybackNativeOperation.start(
      kind: PlaybackNativeOperationKind.dispose,
      timeout: nativeOperationTimeouts.dispose,
      operation: player.dispose,
    );
    try {
      await disposal.logicalFuture;
      if (releaseOnSuccess) lease.release(leaseHandle);
    } catch (_) {
      lease.poison(leaseHandle);
    }
  }
}
