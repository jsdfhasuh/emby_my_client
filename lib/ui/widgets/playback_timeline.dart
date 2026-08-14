import 'package:flutter/material.dart';

import '../../playback/cache/playback_cache_engine.dart';
import '../../playback/cache/playback_cache_policy.dart';
import '../../playback/cache/playback_cache_telemetry.dart';

const playbackTimelineCacheColor = Color(0xFFFFB74D);

class PlaybackTimeline extends StatelessWidget {
  const PlaybackTimeline({
    super.key,
    required this.duration,
    required this.max,
    required this.value,
    required this.secondaryTrackValue,
    required this.cacheRuntimeMode,
    required this.cacheSnapshot,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Duration duration;
  final double max;
  final double value;
  final double secondaryTrackValue;
  final PlaybackCacheRuntimeMode? cacheRuntimeMode;
  final PlaybackCacheEngineSnapshot? cacheSnapshot;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final ranges = confirmedPlaybackTimelineCacheRanges(
      runtimeMode: cacheRuntimeMode,
      snapshot: cacheSnapshot,
    );
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackShape: PlaybackTimelineTrackShape(
          duration: duration,
          seekableRanges: ranges,
        ),
      ),
      child: Slider(
        min: 0,
        max: max,
        value: value,
        secondaryTrackValue: secondaryTrackValue,
        onChangeStart: onChangeStart,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

List<PlaybackCacheRange> confirmedPlaybackTimelineCacheRanges({
  required PlaybackCacheRuntimeMode? runtimeMode,
  required PlaybackCacheEngineSnapshot? snapshot,
}) {
  if (runtimeMode != PlaybackCacheRuntimeMode.disk ||
      snapshot?.cacheOnDisk != true ||
      snapshot?.telemetryStatus != PlaybackCacheTelemetryStatus.available) {
    return const [];
  }
  return snapshot!.seekableRanges;
}

List<PlaybackCacheRange> normalizePlaybackTimelineCacheRanges({
  required Iterable<PlaybackCacheRange> ranges,
  required Duration duration,
}) {
  final durationMicroseconds = duration.inMicroseconds;
  if (durationMicroseconds <= 0) return const [];

  final clamped = <PlaybackCacheRange>[];
  for (final range in ranges) {
    final startMicroseconds = range.start.inMicroseconds
        .clamp(0, durationMicroseconds)
        .toInt();
    final endMicroseconds = range.end.inMicroseconds
        .clamp(0, durationMicroseconds)
        .toInt();
    if (endMicroseconds <= startMicroseconds) continue;
    clamped.add(
      PlaybackCacheRange(
        start: Duration(microseconds: startMicroseconds),
        end: Duration(microseconds: endMicroseconds),
      ),
    );
  }
  clamped.sort((left, right) => left.start.compareTo(right.start));
  if (clamped.isEmpty) return const [];

  final merged = <PlaybackCacheRange>[];
  var current = clamped.first;
  for (final next in clamped.skip(1)) {
    if (next.start <= current.end) {
      if (next.end > current.end) {
        current = PlaybackCacheRange(start: current.start, end: next.end);
      }
      continue;
    }
    merged.add(current);
    current = next;
  }
  merged.add(current);
  return List.unmodifiable(merged);
}

List<Rect> playbackTimelineCacheRects({
  required Rect trackRect,
  required Duration duration,
  required Iterable<PlaybackCacheRange> ranges,
  required TextDirection textDirection,
}) {
  if (trackRect.isEmpty) return const [];
  final normalized = normalizePlaybackTimelineCacheRanges(
    ranges: ranges,
    duration: duration,
  );
  if (normalized.isEmpty) return const [];

  final durationMicroseconds = duration.inMicroseconds;
  return List.unmodifiable(
    normalized.map((range) {
      final startFraction = range.start.inMicroseconds / durationMicroseconds;
      final endFraction = range.end.inMicroseconds / durationMicroseconds;
      final left = textDirection == TextDirection.ltr
          ? trackRect.left + trackRect.width * startFraction
          : trackRect.right - trackRect.width * endFraction;
      final right = textDirection == TextDirection.ltr
          ? trackRect.left + trackRect.width * endFraction
          : trackRect.right - trackRect.width * startFraction;
      return Rect.fromLTRB(left, trackRect.top, right, trackRect.bottom);
    }),
  );
}

class PlaybackTimelineTrackShape extends RoundedRectSliderTrackShape {
  const PlaybackTimelineTrackShape({
    required this.duration,
    required this.seekableRanges,
    this.cacheColor = playbackTimelineCacheColor,
  });

  final Duration duration;
  final List<PlaybackCacheRange> seekableRanges;
  final Color cacheColor;

  List<PlaybackCacheRange> get normalizedSeekableRanges =>
      normalizePlaybackTimelineCacheRanges(
        ranges: seekableRanges,
        duration: duration,
      );

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final cacheRects = playbackTimelineCacheRects(
      trackRect: trackRect,
      duration: duration,
      ranges: seekableRanges,
      textDirection: textDirection,
    );
    if (cacheRects.isEmpty) return;

    final cachePaint = Paint()
      ..color = ColorTween(
        begin: cacheColor.withAlpha(96),
        end: cacheColor,
      ).evaluate(enableAnimation)!;
    final trackRadius = Radius.circular(trackRect.height / 2);
    context.canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(trackRect, trackRadius));
    for (final rect in cacheRects) {
      context.canvas.drawRect(rect, cachePaint);
    }
    context.canvas.restore();

    // The played position remains the strongest layer, matching normal media
    // progress semantics while cached ranges remain visible ahead of the thumb.
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme.copyWith(
        inactiveTrackColor: Colors.transparent,
        disabledInactiveTrackColor: Colors.transparent,
        secondaryActiveTrackColor: Colors.transparent,
        disabledSecondaryActiveTrackColor: Colors.transparent,
      ),
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
  }
}
