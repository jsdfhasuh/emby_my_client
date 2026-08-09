import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/emby_api.dart';
import '../../images/emby_image_cache.dart';
import '../../images/emby_image_request.dart';
import '../../images/photo_prefetcher.dart';
import '../../models/emby_models.dart';
import '../../photos/photo_viewer_controller.dart';
import '../../photos/photo_sequence_source.dart';
import 'zoomable_photo_page.dart';

class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.api, required this.source});

  final EmbyApi api;
  final PhotoSequenceSource source;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late PhotoViewerController _controller;
  late PageController _pageController;
  bool _initialized = false;
  bool _currentPageZoomed = false;
  int _viewerDimension = 1920;

  @override
  void initState() {
    super.initState();
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
    _pageController = PageController(initialPage: _controller.currentIndex);
    _initialized = true;
  }

  @override
  void dispose() {
    if (_initialized) {
      _pageController.dispose();
      _controller.dispose();
    }
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
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
    if (_currentPageZoomed) {
      setState(() => _currentPageZoomed = false);
    }
    _controller.setCurrentIndex(index);
  }

  void _setZoomed(int index, bool zoomed) {
    if (index != _controller.currentIndex ||
        _currentPageZoomed == zoomed ||
        !mounted) {
      return;
    }
    setState(() => _currentPageZoomed = zoomed);
  }

  Future<void> _goTo(int index) async {
    if (index < 0 || index >= _controller.photos.length) return;
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) return const SizedBox.shrink();
    return Scaffold(
      key: const Key('photo-viewer'),
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final photos = _controller.photos;
          if (photos.isEmpty) {
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
                PageView.builder(
                  controller: _pageController,
                  physics: _currentPageZoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: photos.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final item = photos[index];
                    return ZoomablePhotoPage(
                      key: ValueKey('photo-page-${item.id}'),
                      request: _viewerRequest(item),
                      thumbnailRequest: _thumbnailRequest(item),
                      isActive: index == _controller.currentIndex,
                      onZoomChanged: (zoomed) => _setZoomed(index, zoomed),
                    );
                  },
                ),
                _ViewerControls(
                  visible: _controller.controlsVisible,
                  title: photos[_controller.currentIndex].name,
                  positionLabel: _controller.positionLabel,
                  canGoPrevious: _controller.canGoPrevious,
                  canGoNext: _controller.canGoNext,
                  loadingMore: _controller.isLoadingMore,
                  loadMoreError: _controller.loadMoreError,
                  onBack: () =>
                      Navigator.of(context).maybePop(_controller.currentItemId),
                  onPrevious: () => _goTo(_controller.currentIndex - 1),
                  onNext: () => _goTo(_controller.currentIndex + 1),
                  onRetryLoadMore: () =>
                      _controller.loadMoreIfNeeded(force: true),
                ),
              ],
            ),
          );
        },
      ),
    );
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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一张',
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
                      tooltip: '下一张',
                      onPressed: canGoNext ? onNext : null,
                      icon: const Icon(Icons.chevron_right, size: 34),
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
