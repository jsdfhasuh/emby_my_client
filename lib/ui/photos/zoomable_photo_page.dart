import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../images/emby_image_cache.dart';
import '../../images/emby_image_request.dart';
import '../widgets/media_widgets.dart';

class ZoomablePhotoPage extends StatefulWidget {
  const ZoomablePhotoPage({
    super.key,
    required this.request,
    required this.thumbnailRequest,
    required this.isActive,
    required this.onZoomChanged,
    this.onDisplayReadyChanged,
  });

  final EmbyImageRequest? request;
  final EmbyImageRequest? thumbnailRequest;
  final bool isActive;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<bool>? onDisplayReadyChanged;

  @override
  State<ZoomablePhotoPage> createState() => _ZoomablePhotoPageState();
}

class _ZoomablePhotoPageState extends State<ZoomablePhotoPage> {
  static const _doubleTapScale = 2.5;
  final TransformationController _transformationController =
      TransformationController();

  TapDownDetails? _doubleTapDetails;
  bool _zoomed = false;
  int _loadGeneration = 0;
  bool _displayReady = false;
  bool? _reportedDisplayReady;

  @override
  void didUpdateWidget(covariant ZoomablePhotoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request?.cacheKey != widget.request?.cacheKey ||
        (oldWidget.isActive && !widget.isActive)) {
      _resetTransform(notify: oldWidget.isActive);
    }
    if (oldWidget.request?.cacheKey != widget.request?.cacheKey) {
      _loadGeneration++;
      _displayReady = false;
    }
    if (oldWidget.request?.cacheKey != widget.request?.cacheKey ||
        oldWidget.isActive != widget.isActive) {
      _reportedDisplayReady = null;
      _scheduleDisplayReport();
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (_zoomed) {
      _resetTransform();
      return;
    }
    final position = _doubleTapDetails?.localPosition ?? Offset.zero;
    final matrix = Matrix4.diagonal3Values(_doubleTapScale, _doubleTapScale, 1)
      ..setTranslationRaw(
        -position.dx * (_doubleTapScale - 1),
        -position.dy * (_doubleTapScale - 1),
        0,
      );
    _transformationController.value = matrix;
    _reportZoom(true);
  }

  void _handleInteraction() {
    _reportZoom(_transformationController.value.getMaxScaleOnAxis() > 1.01);
  }

  void _resetTransform({bool notify = true}) {
    _transformationController.value = Matrix4.identity();
    if (_zoomed) {
      _zoomed = false;
      if (notify) widget.onZoomChanged(false);
    }
  }

  void _reportZoom(bool zoomed) {
    if (_zoomed == zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  void _imageFrameDisplayed(int generation, bool ready) {
    if (!mounted || generation != _loadGeneration || _displayReady == ready) {
      return;
    }
    _displayReady = ready;
    _scheduleDisplayReport();
  }

  void _scheduleDisplayReport() {
    final generation = _loadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration) return;
      final ready = widget.isActive && _displayReady;
      if (_reportedDisplayReady == ready) return;
      _reportedDisplayReady = ready;
      widget.onDisplayReadyChanged?.call(ready);
    });
  }

  Future<void> _retry() async {
    final request = widget.request;
    if (request == null) return;
    _displayReady = false;
    _scheduleDisplayReport();
    await CachedNetworkImage.evictFromCache(
      request.uri.toString(),
      cacheKey: request.cacheKey,
      cacheManager: embyImageCacheManager,
    );
    if (mounted) setState(() => _loadGeneration++);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformationController,
        minScale: 1,
        maxScale: 5,
        clipBehavior: Clip.none,
        onInteractionUpdate: (_) => _handleInteraction(),
        onInteractionEnd: (_) => _handleInteraction(),
        child: SizedBox.expand(child: _buildImage()),
      ),
    );
  }

  Widget _buildImage() {
    final request = widget.request;
    if (request == null) {
      return const Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 64,
          color: Colors.white54,
        ),
      );
    }
    final preview = EmbyImage(
      request: widget.thumbnailRequest,
      fit: BoxFit.contain,
      icon: Icons.photo_outlined,
      fadeInDuration: Duration.zero,
    );
    final generation = _loadGeneration;
    return CachedNetworkImage(
      key: ValueKey('${request.cacheKey}:$_loadGeneration'),
      imageUrl: request.uri.toString(),
      httpHeaders: request.headers,
      cacheKey: request.cacheKey,
      cacheManager: embyImageCacheManager,
      errorListener: request.errorListener,
      memCacheWidth: request.decodeWidth,
      memCacheHeight: request.decodeHeight,
      fit: BoxFit.contain,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, _) => preview,
      imageBuilder: (context, provider) => Image(
        image: provider,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame != null || wasSynchronouslyLoaded) {
            _imageFrameDisplayed(generation, true);
          }
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          _imageFrameDisplayed(generation, false);
          return preview;
        },
      ),
      errorWidget: (_, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          preview,
          ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
          Center(
            child: IconButton.filledTonal(
              tooltip: '重新加载',
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
    );
  }
}
