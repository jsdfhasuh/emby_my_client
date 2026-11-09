import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/emby_api.dart';
import '../../downloads/download_service.dart';
import '../offline_playback_entry.dart';
import '../widgets/media_widgets.dart';
import '../../images/emby_image_cache.dart';
import '../../images/emby_image_request.dart';
import '../../images/photo_prefetcher.dart';
import '../../models/emby_models.dart';
import '../../playback/cache/playback_cache_storage_scope.dart';
import '../../playback/inline_playback_coordinator.dart';
import '../../playback/inline_playback_session.dart';
import '../../playback/media_kit_inline_playback_session.dart';
import '../../playback/playback_diagnostics_test_overrides_scope.dart';
import '../../playback/playback_settings_scope.dart';
import '../../photos/photo_viewer_controller.dart';
import '../../photos/photo_viewed_controller.dart';
import '../../photos/photo_sequence_source.dart';
import 'inline_video_page.dart';
import 'zoomable_photo_page.dart';

class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.api,
    required this.source,
    this.downloads,
    this.inlineSessionFactory,
  });

  final EmbyApi api;
  final PhotoSequenceSource source;
  final DownloadService? downloads;
  final InlinePlaybackSessionFactory? inlineSessionFactory;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

@visibleForTesting
abstract interface class PhotoViewerDebugState {
  InlinePlaybackCoordinator? get debugInlineCoordinator;
  int get debugBuildCount;
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen>
    with WidgetsBindingObserver
    implements PhotoViewerDebugState {
  static const _inlineShutdownTimeout = Duration(seconds: 3);
  static const _systemUiRestoreTimeout = Duration(seconds: 1);

  late PhotoViewerController _controller;
  late PhotoViewedController _photoViewed;
  late Listenable _viewerChanges;
  late PageController _pageController;
  bool _initialized = false;
  bool _openingLocalVideo = false;
  late bool _serverPlaybackBlocked;
  bool _currentPageZoomed = false;
  bool _seekInteractionActive = false;
  bool _pageScrolling = false;
  bool _closing = false;
  bool _didPop = false;
  int _buildCount = 0;
  int _viewerDimension = 1920;
  InlinePlaybackCoordinator? _inlineCoordinator;
  Future<void>? _closeOperation;
  Future<void>? _restoreSystemUiOperation;
  late AppLifecycleState _lifecycleState;

  @override
  InlinePlaybackCoordinator? get debugInlineCoordinator => _inlineCoordinator;

  @override
  int get debugBuildCount => _buildCount;

  @override
  void initState() {
    super.initState();
    _serverPlaybackBlocked = _isServerPlaybackBlocked;
    widget.api.browseState.addListener(_browseStateChanged);
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final physicalLongestEdge =
        math.max(media.size.width, media.size.height) * media.devicePixelRatio;
    final viewerDimension = EmbyImageRequest.bucketWidth(
      physicalLongestEdge.round().clamp(1280, 2560),
    );
    if (_initialized) {
      if (_viewerDimension != viewerDimension) {
        _viewerDimension = viewerDimension;
        _controller.refreshPrefetch();
      }
      _syncPhotoVisibility();
      return;
    }
    _viewerDimension = viewerDimension;
    final prefetcher = PhotoPrefetcher(
      load: (request) async {
        if (!mounted) return;
        Object? failure;
        StackTrace? failureStack;
        await precacheImage(
          ResizeImage.resizeIfNeeded(
            request.decodeWidth,
            request.decodeHeight,
            CachedNetworkImageProvider(
              request.uri.toString(),
              headers: request.headers,
              cacheKey: request.cacheKey,
              cacheManager: embyImageCacheManager,
              errorListener: request.errorListener,
            ),
          ),
          context,
          onError: (error, stackTrace) {
            failure = error;
            failureStack = stackTrace;
          },
        );
        final error = failure;
        if (error != null) {
          Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
        }
      },
    );
    _controller = PhotoViewerController(
      source: widget.source,
      imageRequestFor: _viewerRequest,
      prefetcher: prefetcher,
    );
    _photoViewed = PhotoViewedController(
      writeViewed: _writePhotoViewed,
      onSaved: _controller.recordPhotoViewed,
    );
    _viewerChanges = Listenable.merge([_controller, _photoViewed]);
    _controller.addListener(_viewerControllerChanged);
    _pageController = PageController(initialPage: _controller.currentIndex);
    _initialized = true;
    _viewerControllerChanged();
    _syncPhotoVisibility();
    if (_controller.mediaItems.isNotEmpty &&
        _controller.mediaItems[_controller.currentIndex].isPlayable) {
      unawaited(Future<void>.microtask(_syncCurrentPlayback));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (_closing) return;
    _syncPhotoVisibility();
    unawaited(_inlineCoordinator?.handleAppLifecycleState(state));
  }

  @override
  void didHaveMemoryPressure() {
    if (_closing) return;
    unawaited(_inlineCoordinator?.handleMemoryPressure());
  }

  @override
  void dispose() {
    widget.api.browseState.removeListener(_browseStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    final inlineCoordinator = _inlineCoordinator;
    if (inlineCoordinator != null) {
      inlineCoordinator.removeListener(_recordInlinePlayback);
      unawaited(_shutdownInlineCoordinator(inlineCoordinator));
      inlineCoordinator.dispose();
    }
    if (_initialized) {
      _pageController.dispose();
      _controller.removeListener(_viewerControllerChanged);
      _photoViewed.dispose();
      _controller.dispose();
    }
    unawaited(_restoreSystemUiSafely());
    super.dispose();
  }

  EmbyImageRequest? _viewerRequest(EmbyItem item) => widget.api.imageRequest(
    item,
    maxWidth: _viewerDimension,
    maxHeight: _viewerDimension,
  );

  EmbyImageRequest? _thumbnailRequest(EmbyItem item) =>
      widget.api.imageRequest(item, maxWidth: 512, maxHeight: 512);

  void _onPageChanged(int index) {
    if (_closing) return;
    if (_currentPageZoomed || _seekInteractionActive) {
      setState(() {
        _currentPageZoomed = false;
        _seekInteractionActive = false;
      });
    }
    _controller.setCurrentIndex(index);
    unawaited(_syncCurrentPlayback());
  }

  void _viewerControllerChanged() {
    if (!_initialized || _closing) return;
    final items = _controller.mediaItems;
    _photoViewed.activate(
      items.isEmpty ? null : items[_controller.currentIndex],
    );
  }

  void _syncPhotoVisibility() {
    if (!_initialized) return;
    _photoViewed.setForeground(
      !_closing &&
          !_pageScrolling &&
          _lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent != false &&
          !_isServerPlaybackBlocked,
    );
  }

  bool _onPageScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _pageScrolling = true;
      _syncPhotoVisibility();
    } else if (notification is ScrollEndNotification) {
      _pageScrolling = false;
      _syncPhotoVisibility();
    }
    return false;
  }

  void _recordInlinePlayback() {
    final state = _inlineCoordinator?.state;
    if (state != null && state.isPlaying && state.itemId != null) {
      _controller.requireUserDataRefresh(state.itemId!);
    }
  }

  Future<void> _writePhotoViewed(String itemId, bool viewed) async {
    await widget.api.userData.setPlayed(itemId, played: viewed);
    _controller.requireUserDataRefresh(itemId);
    final userData = await widget.api.getUserDataForItems([itemId]);
    if (userData[itemId]?.isPlayed != viewed) {
      throw const EmbyApiException('服务器未确认照片查看状态，请重试');
    }
  }

  Future<void> _finishPhotoWrites() async {
    final unresolvedIds = await _photoViewed.finish();
    for (final itemId in unresolvedIds) {
      _controller.requireUserDataRefresh(itemId);
    }
  }

  void _togglePhotoViewed() {
    if (_closing || _isServerPlaybackBlocked) return;
    _controller.showControlsTemporarily();
    unawaited(_photoViewed.markCurrent(viewed: !_photoViewed.isViewed));
  }

  void _setZoomed(int index, bool zoomed) {
    if (_closing ||
        index != _controller.currentIndex ||
        _currentPageZoomed == zoomed ||
        !mounted) {
      return;
    }
    setState(() => _currentPageZoomed = zoomed);
  }

  void _setSeekInteractionActive(bool active) {
    if (_closing || !mounted || _seekInteractionActive == active) return;
    setState(() => _seekInteractionActive = active);
    if (active) _controller.showControlsTemporarily();
  }

  InlinePlaybackCoordinator _ensureInlineCoordinator() {
    final existing = _inlineCoordinator;
    if (existing != null) return existing;
    final injectedFactory = widget.inlineSessionFactory;
    final InlinePlaybackSessionFactory factory;
    if (injectedFactory != null) {
      factory = (item) {
        if (_isServerPlaybackBlocked || _openingLocalVideo) {
          throw StateError('Server playback unavailable');
        }
        return injectedFactory(item);
      };
    } else {
      final settingsRepository = PlaybackSettingsRepositoryScope.of(context);
      final cacheStorage = PlaybackCacheStorageScope.of(context);
      final diagnosticsController =
          PlaybackDiagnosticsTestOverridesScope.maybeOf(context);
      final settings = settingsRepository.load(widget.api.session);
      factory = (item) async {
        final loadedSettings = (await settings).settings;
        if (_isServerPlaybackBlocked || _openingLocalVideo) {
          throw StateError('Server playback unavailable');
        }
        return MediaKitInlinePlaybackSession.create(
          api: widget.api,
          item: item,
          settings: loadedSettings,
          cacheStorage: cacheStorage,
          testOverrides: diagnosticsController?.consumeForPlayback(),
        );
      };
    }
    final coordinator = InlinePlaybackCoordinator(
      factory: factory,
      initialLifecycleState: _lifecycleState,
    );
    _inlineCoordinator = coordinator;
    coordinator.addListener(_recordInlinePlayback);
    if (mounted && !_closing) setState(() {});
    return coordinator;
  }

  Future<void> _syncCurrentPlayback() {
    if (_closing ||
        !_initialized ||
        widget.source.mode != MediaViewerMode.homeMedia) {
      return Future<void>.value();
    }
    if (_controller.mediaItems.isEmpty) return Future<void>.value();
    final item = _controller.mediaItems[_controller.currentIndex];
    if (item.isPlayable && !_isServerPlaybackBlocked && !_openingLocalVideo) {
      return _ensureInlineCoordinator().activate(item);
    }
    return _inlineCoordinator?.deactivate() ?? Future<void>.value();
  }

  bool get _isServerPlaybackBlocked =>
      !widget.api.isSessionActive ||
      widget.api.browseState.offline ||
      widget.api.browseState.authenticationRequired;

  void _browseStateChanged() {
    if (!mounted || _closing) return;
    final blocked = _isServerPlaybackBlocked;
    if (blocked == _serverPlaybackBlocked) return;
    setState(() => _serverPlaybackBlocked = blocked);
    _syncPhotoVisibility();
    unawaited(_syncCurrentPlayback());
  }

  Widget _offlineVideoPage(EmbyItem item) => Stack(
    key: ValueKey('offline-video-page-${item.id}'),
    fit: StackFit.expand,
    children: [
      EmbyImage(request: _viewerRequest(item), fit: BoxFit.contain),
      Center(
        child: Container(
          color: const Color(0xCC000000),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                color: Colors.white,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                widget.api.browseState.authenticationRequired
                    ? '登录已失效，请重新登录'
                    : '服务器离线，仅可播放本地下载',
                style: const TextStyle(color: Colors.white),
              ),
              if (!widget.api.browseState.authenticationRequired &&
                  widget.downloads != null) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: ValueKey('offline-video-play-${item.id}'),
                  onPressed: _openingLocalVideo
                      ? null
                      : () => unawaited(_playLocalVideo(item)),
                  icon: const Icon(Icons.download_done),
                  label: const Text('播放本地下载'),
                ),
              ] else if (!widget.api.browseState.authenticationRequired)
                const Text(
                  '视频尚无可用的本地下载，联网后可播放',
                  style: TextStyle(color: Colors.white70),
                ),
            ],
          ),
        ),
      ),
    ],
  );

  Future<void> _playLocalVideo(EmbyItem item) async {
    if (_openingLocalVideo || _closing) return;
    setState(() => _openingLocalVideo = true);
    try {
      await _inlineCoordinator?.deactivate();
      if (!mounted || _closing) return;
      await openCachedPlayback(
        context,
        api: widget.api,
        downloads: widget.downloads,
        item: item,
        requireLocal: true,
      );
      _controller.requireUserDataRefresh(item.id);
    } finally {
      if (mounted && !_closing) {
        setState(() => _openingLocalVideo = false);
        unawaited(_syncCurrentPlayback());
      }
    }
  }

  Future<void> _closeViewer() {
    final existing = _closeOperation;
    if (existing != null) return existing;
    _closing = true;
    _currentPageZoomed = false;
    _seekInteractionActive = false;
    _syncPhotoVisibility();
    if (mounted) setState(() {});
    return _closeOperation = _closeViewerOnce();
  }

  Future<void> _closeViewerOnce() async {
    try {
      final inlineCoordinator = _inlineCoordinator;
      await Future.wait([
        _finishPhotoWrites(),
        if (inlineCoordinator != null)
          _shutdownInlineCoordinator(inlineCoordinator),
      ]);
    } finally {
      try {
        await _restoreSystemUiSafely().timeout(_systemUiRestoreTimeout);
      } catch (_) {
        // Route exit remains bounded even if the platform UI call never ends.
      } finally {
        if (mounted && !_didPop) {
          _didPop = true;
          Navigator.of(context).pop(_controller.result);
        }
      }
    }
  }

  Future<void> _shutdownInlineCoordinator(
    InlinePlaybackCoordinator coordinator,
  ) async {
    try {
      await coordinator.shutdown().timeout(_inlineShutdownTimeout);
    } catch (_) {
      coordinator.detachAndQuarantine();
    }
  }

  Future<void> _restoreSystemUi() => _restoreSystemUiOperation ??=
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  Future<void> _restoreSystemUiSafely() async {
    try {
      await _restoreSystemUi();
    } catch (_) {
      // Platform UI restoration failure must not strand the viewer route.
    }
  }

  Future<void> _goTo(int index) async {
    if (_closing || index < 0 || index >= _controller.mediaItems.length) {
      return;
    }
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    if (!_initialized) return const SizedBox.shrink();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_closeViewer());
      },
      child: Scaffold(
        key: const Key('photo-viewer'),
        backgroundColor: Colors.black,
        body: IgnorePointer(
          ignoring: _closing,
          child: ListenableBuilder(
            listenable: _viewerChanges,
            builder: (context, _) {
              final mediaItems = _controller.mediaItems;
              if (mediaItems.isEmpty) {
                return const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 64,
                    color: Colors.white54,
                  ),
                );
              }
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _controller.toggleControls,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: _onPageScroll,
                      child: PageView.builder(
                        controller: _pageController,
                        physics: _currentPageZoomed || _seekInteractionActive
                            ? const NeverScrollableScrollPhysics()
                            : const PageScrollPhysics(),
                        itemCount: mediaItems.length,
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, index) {
                          final item = mediaItems[index];
                          if (item.isPlayable) {
                            if (_isServerPlaybackBlocked) {
                              return _offlineVideoPage(item);
                            }
                            return InlineVideoPage(
                              key: ValueKey('video-page-${item.id}'),
                              itemId: item.id,
                              coverRequest: _viewerRequest(item),
                              isActive: index == _controller.currentIndex,
                              state: InlinePlaybackState(itemId: item.id),
                              coordinator: index == _controller.currentIndex
                                  ? _inlineCoordinator
                                  : null,
                              onPlay: _playInline,
                              onPause: _pauseInline,
                              onSeek: _seekInline,
                              onRetry: _retryInline,
                              onSeekInteractionChanged:
                                  _setSeekInteractionActive,
                            );
                          }
                          return ZoomablePhotoPage(
                            key: ValueKey('photo-page-${item.id}'),
                            request: _viewerRequest(item),
                            thumbnailRequest: _thumbnailRequest(item),
                            isActive: index == _controller.currentIndex,
                            onZoomChanged: (zoomed) =>
                                _setZoomed(index, zoomed),
                            onDisplayReadyChanged: (ready) =>
                                _photoViewed.imageDisplayed(item.id, ready),
                          );
                        },
                      ),
                    ),
                    _ViewerControls(
                      visible: _controller.controlsVisible,
                      title: mediaItems[_controller.currentIndex].name,
                      positionLabel: _controller.positionLabel,
                      canGoPrevious: _controller.canGoPrevious,
                      canGoNext: _controller.canGoNext,
                      loadingMore: _controller.isLoadingMore,
                      loadMoreError: _controller.loadMoreError,
                      onBack: () => unawaited(_closeViewer()),
                      onPrevious: () => _goTo(_controller.currentIndex - 1),
                      onNext: () => _goTo(_controller.currentIndex + 1),
                      onRetryLoadMore: _retryLoadMore,
                      photoViewed: mediaItems[_controller.currentIndex].isPhoto
                          ? _photoViewed.isViewed
                          : null,
                      photoMarking: _photoViewed.isSaving,
                      photoSaveFailed: _photoViewed.error != null,
                      onMarkPhotoViewed: _isServerPlaybackBlocked
                          ? null
                          : _togglePhotoViewed,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _playInline() {
    if (_closing || _isServerPlaybackBlocked || _openingLocalVideo) return;
    unawaited(_inlineCoordinator?.play() ?? Future<void>.value());
  }

  void _pauseInline() {
    if (_closing) return;
    unawaited(_inlineCoordinator?.pause() ?? Future<void>.value());
  }

  void _seekInline(Duration position) {
    if (_closing) return;
    unawaited(_inlineCoordinator?.seek(position) ?? Future<void>.value());
  }

  void _retryInline() {
    if (_closing || _isServerPlaybackBlocked || _openingLocalVideo) return;
    unawaited(_inlineCoordinator?.retry() ?? Future<void>.value());
  }

  void _retryLoadMore() {
    if (_closing) return;
    unawaited(_controller.loadMoreIfNeeded(force: true));
  }
}

class _ViewerControls extends StatelessWidget {
  const _ViewerControls({
    required this.visible,
    required this.title,
    required this.positionLabel,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.loadingMore,
    required this.loadMoreError,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.onRetryLoadMore,
    required this.photoViewed,
    required this.photoMarking,
    required this.photoSaveFailed,
    required this.onMarkPhotoViewed,
  });

  final bool visible;
  final String title;
  final String positionLabel;
  final bool canGoPrevious;
  final bool canGoNext;
  final bool loadingMore;
  final Object? loadMoreError;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onRetryLoadMore;
  final bool? photoViewed;
  final bool photoMarking;
  final bool photoSaveFailed;
  final VoidCallback? onMarkPhotoViewed;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top + 4,
                  left: 4,
                  right: 12,
                  bottom: 16,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xCC000000), Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      positionLabel,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: EdgeInsets.only(
                  top: 18,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xCC000000), Colors.transparent],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (photoViewed != null)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        children: [
                          Text(
                            photoViewed! ? '已查看' : '未查看',
                            style: const TextStyle(color: Colors.white),
                          ),
                          TextButton.icon(
                            key: const Key('photo-viewed-action'),
                            onPressed: photoMarking ? null : onMarkPhotoViewed,
                            icon: Icon(
                              photoViewed!
                                  ? Icons.visibility_off_outlined
                                  : Icons.check_circle_outline,
                            ),
                            label: Text(
                              photoMarking
                                  ? '正在保存…'
                                  : '${photoSaveFailed ? '重试：' : ''}'
                                        '${photoViewed! ? '标记为未查看' : '标记为已查看'}',
                            ),
                          ),
                        ],
                      ),
                    if (photoSaveFailed && photoViewed != null)
                      const Text(
                        '查看状态保存失败，请重试',
                        style: TextStyle(color: Colors.orangeAccent),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '上一个',
                          onPressed: canGoPrevious ? onPrevious : null,
                          icon: const Icon(Icons.chevron_left, size: 34),
                        ),
                        const SizedBox(width: 32),
                        if (loadingMore)
                          const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else if (loadMoreError != null)
                          IconButton(
                            tooltip: '重试加载',
                            onPressed: onRetryLoadMore,
                            icon: const Icon(Icons.refresh),
                          )
                        else
                          const SizedBox.square(dimension: 24),
                        const SizedBox(width: 32),
                        IconButton(
                          tooltip: '下一个',
                          onPressed: canGoNext ? onNext : null,
                          icon: const Icon(Icons.chevron_right, size: 34),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
