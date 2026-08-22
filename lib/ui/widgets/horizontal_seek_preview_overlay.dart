import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/emby_api.dart';
import '../../models/emby_models.dart';
import '../../playback/trickplay/trickplay_frame_resolver.dart';
import '../../playback/trickplay/trickplay_preview_controller.dart';
import 'trickplay_preview.dart';

class HorizontalSeekPreviewOverlay extends StatefulWidget {
  const HorizontalSeekPreviewOverlay({
    super.key,
    required this.api,
    required this.item,
    required this.plan,
    required this.playerItemGeneration,
    required this.startPosition,
    required this.targetPosition,
    required this.duration,
    required this.horizontalDragDx,
  });

  final EmbyApi api;
  final EmbyItem item;
  final PlaybackPlan? plan;
  final String playerItemGeneration;
  final Duration startPosition;
  final Duration targetPosition;
  final Duration duration;
  final double horizontalDragDx;

  @override
  State<HorizontalSeekPreviewOverlay> createState() =>
      _HorizontalSeekPreviewOverlayState();
}

class _HorizontalSeekPreviewOverlayState
    extends State<HorizontalSeekPreviewOverlay> {
  late final TrickplayPreviewController<ImageProvider> _previewController;
  String? _resourceKey;

  @override
  void initState() {
    super.initState();
    _previewController = TrickplayPreviewController<ImageProvider>(
      onChanged: (_) {
        if (mounted) setState(() {});
      },
    );
    _previewController.beginScrubSession();
    _resourceKey = _resourceIdentity(widget);
    _requestFrame();
  }

  @override
  void didUpdateWidget(covariant HorizontalSeekPreviewOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextResourceKey = _resourceIdentity(widget);
    var resourceChanged = false;
    if (nextResourceKey != _resourceKey) {
      resourceChanged = true;
      _resourceKey = nextResourceKey;
      _previewController.resetResource();
    }
    if (resourceChanged || _targetChanged(oldWidget)) _requestFrame();
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  bool _targetChanged(HorizontalSeekPreviewOverlay oldWidget) =>
      oldWidget.targetPosition != widget.targetPosition ||
      oldWidget.duration != widget.duration ||
      oldWidget.item.trickplay != widget.item.trickplay ||
      oldWidget.plan?.mediaSourceId != widget.plan?.mediaSourceId;

  String _resourceIdentity(HorizontalSeekPreviewOverlay value) => [
    value.playerItemGeneration,
    value.item.id,
    value.plan?.mediaSourceId ?? '',
  ].join('\u0000');

  void _requestFrame() {
    final plan = widget.plan;
    final selection = widget.item.trickplay?.selectionFor(plan?.mediaSourceId);
    if (plan == null || selection == null) {
      _previewController.showUnavailable();
      return;
    }

    final frame = TrickplayFrameResolver.resolve(
      position: widget.targetPosition,
      duration: widget.duration,
      resolution: selection.resolution,
    );
    if (frame == null) {
      _previewController.showUnavailable();
      return;
    }

    final identity = TrickplaySheetIdentity(
      playerItemGeneration: widget.playerItemGeneration,
      itemId: widget.item.id,
      mediaSourceId: selection.mediaSourceId,
      resolutionWidth: selection.resolution.width,
      sheetIndex: frame.sheetIndex,
    );
    final image = NetworkImage(
      widget.api
          .trickplayTileUrl(
            itemId: widget.item.id,
            width: selection.resolution.width,
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
    final plan = widget.plan;
    final selection = widget.item.trickplay?.selectionFor(plan?.mediaSourceId);
    final frame = state.frame;
    final image = state.sheet;
    final showImage =
        state.status == TrickplayPreviewStatus.ready &&
        selection != null &&
        frame != null &&
        image != null;
    final deltaSeconds =
        widget.targetPosition.inSeconds - widget.startPosition.inSeconds;
    final deltaLabel = deltaSeconds > 0
        ? '+$deltaSeconds 秒'
        : '$deltaSeconds 秒';

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
              if (showImage) ...[
                SizedBox(
                  width: 240,
                  child: TrickplayPreview(
                    key: ValueKey(state.sheetIdentity),
                    image: image,
                    thumbnailWidth: selection.resolution.width,
                    thumbnailHeight: selection.resolution.height,
                    columns: selection.resolution.tileColumns,
                    rows: selection.resolution.tileRows,
                    column: frame.column,
                    row: frame.row,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Icon(
                widget.horizontalDragDx >= 0
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
                '${_formatDuration(widget.targetPosition)} / '
                '${_formatDuration(widget.duration)}',
                style: const TextStyle(color: Color(0xFFD0D5D6), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '${duration.inMinutes}:$seconds';
  }
}
