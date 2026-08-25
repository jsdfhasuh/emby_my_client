import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/emby_api.dart';
import '../../models/emby_models.dart';
import '../../playback/cache/playback_cache_engine.dart';
import '../../playback/cache/playback_cache_policy.dart';
import '../../playback/trickplay/trickplay_frame_resolver.dart';
import '../../playback/trickplay/trickplay_preview_controller.dart';
import 'playback_timeline.dart';
import 'trickplay_preview.dart';

typedef _TrickplayResourceIdentity = ({
  String playerItemGeneration,
  String itemId,
  String mediaSourceId,
  int? resolutionWidth,
  int? resolutionHeight,
  int? tileColumns,
  int? tileRows,
  int? intervalMilliseconds,
  int? thumbnailCount,
});

class TrickplaySeekPreviewOverlay extends StatefulWidget {
  const TrickplaySeekPreviewOverlay({
    super.key,
    required this.api,
    required this.item,
    required this.plan,
    required this.playerItemGeneration,
    required this.startPosition,
    required this.targetPosition,
    required this.duration,
    required this.buffer,
    required this.cacheRuntimeMode,
    required this.cacheSnapshot,
    required this.previewDisabled,
  });

  final EmbyApi api;
  final EmbyItem item;
  final PlaybackPlan? plan;
  final String playerItemGeneration;
  final Duration startPosition;
  final Duration targetPosition;
  final Duration duration;
  final Duration buffer;
  final PlaybackCacheRuntimeMode? cacheRuntimeMode;
  final PlaybackCacheEngineSnapshot? cacheSnapshot;
  final bool previewDisabled;

  @override
  State<TrickplaySeekPreviewOverlay> createState() =>
      _TrickplaySeekPreviewOverlayState();
}

class _TrickplaySeekPreviewOverlayState
    extends State<TrickplaySeekPreviewOverlay> {
  late final TrickplayPreviewController<ImageProvider> _previewController;
  late _TrickplayResourceIdentity _resourceIdentity;

  @override
  void initState() {
    super.initState();
    _previewController = TrickplayPreviewController<ImageProvider>();
    _previewController.beginScrubSession();
    _resourceIdentity = _identityFor(widget);
    if (!widget.previewDisabled) _requestFrame();
    _previewController.addListener(_onPreviewChanged);
  }

  @override
  void didUpdateWidget(covariant TrickplaySeekPreviewOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextResourceIdentity = _identityFor(widget);
    final resourceChanged = nextResourceIdentity != _resourceIdentity;
    if (resourceChanged) {
      _resourceIdentity = nextResourceIdentity;
      _previewController.resetResource();
    }

    if (widget.previewDisabled) {
      if (!oldWidget.previewDisabled && !resourceChanged) {
        _previewController.invalidate();
      }
      return;
    }
    if (resourceChanged ||
        oldWidget.previewDisabled ||
        oldWidget.targetPosition != widget.targetPosition ||
        oldWidget.duration != widget.duration) {
      _requestFrame();
    }
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  void _onPreviewChanged(TrickplayPreviewState<ImageProvider> _) {
    if (mounted) setState(() {});
  }

  _TrickplayResourceIdentity _identityFor(TrickplaySeekPreviewOverlay value) {
    final selection = value.item.trickplay?.selectionFor(
      value.plan?.mediaSourceId,
    );
    final resolution = selection?.resolution;
    return (
      playerItemGeneration: value.playerItemGeneration,
      itemId: value.item.id,
      mediaSourceId:
          selection?.mediaSourceId ?? value.plan?.mediaSourceId ?? '',
      resolutionWidth: resolution?.width,
      resolutionHeight: resolution?.height,
      tileColumns: resolution?.tileColumns,
      tileRows: resolution?.tileRows,
      intervalMilliseconds: resolution?.intervalMilliseconds,
      thumbnailCount: resolution?.thumbnailCount,
    );
  }

  void _requestFrame() {
    final plan = widget.plan;
    final selection = widget.item.trickplay?.selectionFor(plan?.mediaSourceId);
    if (plan == null || selection == null) {
      _previewController.showUnavailable();
      return;
    }

    final resolution = selection.resolution;
    final frame = TrickplayFrameResolver.resolve(
      position: widget.targetPosition,
      duration: widget.duration,
      resolution: resolution,
    );
    if (frame == null) {
      _previewController.showUnavailable();
      return;
    }

    final identity = TrickplaySheetIdentity(
      playerItemGeneration: widget.playerItemGeneration,
      itemId: widget.item.id,
      mediaSourceId: selection.mediaSourceId,
      resolutionWidth: resolution.width,
      resolutionHeight: resolution.height,
      tileColumns: resolution.tileColumns,
      tileRows: resolution.tileRows,
      intervalMilliseconds: resolution.intervalMilliseconds,
      thumbnailCount: resolution.thumbnailCount,
      sheetIndex: frame.sheetIndex,
    );
    final image = NetworkImage(
      widget.api
          .trickplayTileUrl(
            itemId: widget.item.id,
            width: resolution.width,
            imageIndex: frame.sheetIndex,
            mediaSourceId: selection.mediaSourceId,
          )
          .toString(),
      headers: widget.api.imageHeaders,
    );
    unawaited(
      _previewController.request(
        request: TrickplayPreviewRequest(identity: identity, frame: frame),
        load: (_) => _loadImage(image),
      ),
    );
  }

  Future<ImageProvider> _loadImage(ImageProvider image) async {
    await _resolveImage(image);
    return image;
  }

  Future<void> _resolveImage(ImageProvider image) {
    final completer = Completer<void>();
    final stream = image.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;

    void completeSuccess() {
      if (completer.isCompleted) return;
      stream.removeListener(listener);
      completer.complete();
    }

    void completeFailure(Object error, StackTrace stackTrace) {
      if (completer.isCompleted) return;
      stream.removeListener(listener);
      completer.completeError(error, stackTrace);
    }

    listener = ImageStreamListener(
      (_, _) => completeSuccess(),
      onError: (error, stackTrace) {
        completeFailure(error, stackTrace ?? StackTrace.empty);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final state = _previewController.state;
    final selection = widget.item.trickplay?.selectionFor(
      widget.plan?.mediaSourceId,
    );
    final frame = state.frame;
    final image = state.sheet;
    final showImage =
        !widget.previewDisabled &&
        state.status == TrickplayPreviewStatus.ready &&
        selection != null &&
        frame != null &&
        image != null;
    final preview = showImage
        ? TrickplayPreview(
            key: ValueKey(state.sheetIdentity),
            image: image,
            thumbnailWidth: selection.resolution.width,
            thumbnailHeight: selection.resolution.height,
            columns: selection.resolution.tileColumns,
            rows: selection.resolution.tileRows,
            column: frame.column,
            row: frame.row,
          )
        : null;

    return HorizontalSeekPreviewOverlay(
      startPosition: widget.startPosition,
      targetPosition: widget.targetPosition,
      duration: widget.duration,
      buffer: widget.buffer,
      cacheRuntimeMode: widget.cacheRuntimeMode,
      cacheSnapshot: widget.cacheSnapshot,
      previewDisabled: widget.previewDisabled,
      previewUnavailable:
          !widget.previewDisabled &&
          state.status == TrickplayPreviewStatus.unavailable,
      preview: preview,
      isLoading:
          !widget.previewDisabled &&
          state.status == TrickplayPreviewStatus.loading,
    );
  }
}

class HorizontalSeekPreviewOverlay extends StatelessWidget {
  const HorizontalSeekPreviewOverlay({
    super.key,
    required this.startPosition,
    required this.targetPosition,
    required this.duration,
    required this.buffer,
    required this.cacheRuntimeMode,
    required this.cacheSnapshot,
    required this.previewDisabled,
    required this.previewUnavailable,
    this.preview,
    this.isLoading = false,
  }) : assert(!(previewDisabled && previewUnavailable));

  final Duration startPosition;
  final Duration targetPosition;
  final Duration duration;
  final Duration buffer;
  final PlaybackCacheRuntimeMode? cacheRuntimeMode;
  final PlaybackCacheEngineSnapshot? cacheSnapshot;
  final bool previewDisabled;
  final bool previewUnavailable;
  final Widget? preview;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final cardWidth = math.min(270.0, math.max(0.0, width - 8));
            final maxLeft = math.max(0.0, width - cardWidth);
            final safeLeft = math.min(4.0, maxLeft);
            final fraction = duration <= Duration.zero
                ? 0.0
                : (targetPosition.inMicroseconds / duration.inMicroseconds)
                      .clamp(0.0, 1.0)
                      .toDouble();
            final desiredCenter = width * fraction;
            final cardLeft = (desiredCenter - cardWidth / 2)
                .clamp(safeLeft, math.max(safeLeft, maxLeft - safeLeft))
                .toDouble();
            final maxMilliseconds = duration.inMilliseconds
                .toDouble()
                .clamp(1.0, double.infinity)
                .toDouble();
            final targetMilliseconds = targetPosition.inMilliseconds
                .toDouble()
                .clamp(0.0, maxMilliseconds)
                .toDouble();
            final bufferMilliseconds = buffer.inMilliseconds
                .toDouble()
                .clamp(targetMilliseconds, maxMilliseconds)
                .toDouble();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: cardLeft),
                  child: SizedBox(
                    width: cardWidth,
                    child: _buildPreviewCard(cardWidth),
                  ),
                ),
                const SizedBox(height: 8),
                PlaybackTimeline(
                  key: const ValueKey('horizontal-seek-preview-timeline'),
                  duration: duration,
                  max: maxMilliseconds,
                  value: targetMilliseconds,
                  secondaryTrackValue: bufferMilliseconds,
                  cacheRuntimeMode: cacheRuntimeMode,
                  cacheSnapshot: cacheSnapshot,
                  onChangeStart: null,
                  onChanged: null,
                  onChangeEnd: null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Text(_formatDuration(targetPosition)),
                      const Spacer(),
                      Text(_formatDuration(duration)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPreviewCard(double cardWidth) {
    final deltaSeconds = targetPosition.inSeconds - startPosition.inSeconds;
    final offsetLabel = deltaSeconds > 0
        ? '前进 $deltaSeconds 秒'
        : deltaSeconds < 0
        ? '后退 ${-deltaSeconds} 秒'
        : '当前位置';
    final previewWidth = math.min(220.0, math.max(0.0, cardWidth - 24));
    final previewHeight = previewWidth * 9 / 16;
    final showPreviewImage = !previewDisabled && preview != null;
    final showUnavailablePlaceholder =
        !previewDisabled && preview == null && previewUnavailable;

    return Container(
      key: const ValueKey('horizontal-seek-preview-overlay'),
      constraints: previewDisabled
          ? null
          : const BoxConstraints(minHeight: 190),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xF2171A1C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3A4447)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showPreviewImage)
            SizedBox(
              key: const ValueKey('horizontal-seek-preview-image'),
              width: previewWidth,
              height: previewHeight,
              child: preview,
            )
          else if (showUnavailablePlaceholder)
            const SizedBox(
              key: ValueKey('horizontal-seek-preview-unavailable'),
              height: 124,
              child: Center(
                child: Text(
                  '暂无可用画面',
                  style: TextStyle(color: Color(0xFFD0D5D6)),
                ),
              ),
            ),
          if (!previewDisabled && isLoading)
            const Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                key: ValueKey('horizontal-seek-preview-loading'),
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            key: const ValueKey('horizontal-seek-offset-label'),
            offsetLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            key: const ValueKey('horizontal-seek-target-time'),
            '${_formatDuration(targetPosition)} / ${_formatDuration(duration)}',
            style: const TextStyle(color: Color(0xFFD0D5D6), fontSize: 13),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
