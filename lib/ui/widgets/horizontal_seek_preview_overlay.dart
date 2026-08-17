import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback/cache/playback_cache_engine.dart';
import '../../playback/cache/playback_cache_policy.dart';
import 'playback_timeline.dart';

class HorizontalSeekPreviewOverlay extends StatelessWidget {
  const HorizontalSeekPreviewOverlay({
    super.key,
    required this.startPosition,
    required this.targetPosition,
    required this.duration,
    required this.buffer,
    required this.cacheRuntimeMode,
    required this.cacheSnapshot,
    this.preview,
    this.isLoading = false,
  });

  final Duration startPosition;
  final Duration targetPosition;
  final Duration duration;
  final Duration buffer;
  final PlaybackCacheRuntimeMode? cacheRuntimeMode;
  final PlaybackCacheEngineSnapshot? cacheSnapshot;
  final Widget? preview;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 276,
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
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: cardLeft,
                    top: 0,
                    width: cardWidth,
                    child: _buildPreviewCard(cardWidth),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 204,
                    child: PlaybackTimeline(
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
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    top: 248,
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

    return Container(
      key: const ValueKey('horizontal-seek-preview-overlay'),
      constraints: const BoxConstraints(minHeight: 190),
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
          if (preview != null)
            SizedBox(
              key: const ValueKey('horizontal-seek-preview-image'),
              width: previewWidth,
              height: previewHeight,
              child: preview,
            )
          else
            const SizedBox(
              height: 124,
              child: Center(
                child: Text(
                  '暂无可用画面',
                  style: TextStyle(color: Color(0xFFD0D5D6)),
                ),
              ),
            ),
          if (isLoading)
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
