const horizontalSwipeSeekSpanOptions = <int>[30, 60, 120, 300, 600];
const defaultHorizontalSwipeSeekSpanSeconds = 120;

int normalizeHorizontalSwipeSeekSpanSeconds(int? value) {
  return horizontalSwipeSeekSpanOptions.contains(value)
      ? value!
      : defaultHorizontalSwipeSeekSpanSeconds;
}

Duration calculateHorizontalScrubTarget({
  required Duration startPosition,
  required Duration duration,
  required double dragDistance,
  required double viewportWidth,
  required int spanSeconds,
}) {
  if (duration <= Duration.zero ||
      !dragDistance.isFinite ||
      !viewportWidth.isFinite ||
      viewportWidth <= 0) {
    return _clampDuration(startPosition, duration);
  }

  final normalizedSpan = normalizeHorizontalSwipeSeekSpanSeconds(spanSeconds);
  final durationMicros = duration.inMicroseconds;
  final startMicros = _clampDuration(startPosition, duration).inMicroseconds;
  final candidateMicros =
      startMicros +
      dragDistance /
          viewportWidth *
          normalizedSpan *
          Duration.microsecondsPerSecond;
  if (!candidateMicros.isFinite) {
    return dragDistance < 0 ? Duration.zero : duration;
  }

  return Duration(
    microseconds: candidateMicros.clamp(0, durationMicros).toDouble().round(),
  );
}

Duration previewSamplePosition({
  required Duration target,
  required Duration duration,
}) {
  if (duration <= Duration.zero) return Duration.zero;
  final clampedTarget = _clampDuration(target, duration);
  if (clampedTarget < duration) return clampedTarget;
  return duration > const Duration(milliseconds: 1)
      ? duration - const Duration(milliseconds: 1)
      : Duration.zero;
}

Duration _clampDuration(Duration value, Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  if (value < Duration.zero) return Duration.zero;
  if (value > duration) return duration;
  return value;
}
