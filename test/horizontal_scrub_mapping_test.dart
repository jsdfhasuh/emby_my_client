import 'package:emby_my_client/playback/horizontal_scrub_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const duration = Duration(minutes: 30);
  const start = Duration(minutes: 10);
  const viewportWidth = 400.0;

  test('maps each supported span linearly across the viewport', () {
    for (final span in horizontalSwipeSeekSpanOptions) {
      expect(
        calculateHorizontalScrubTarget(
          startPosition: start,
          duration: duration,
          dragDistance: viewportWidth,
          viewportWidth: viewportWidth,
          spanSeconds: span,
        ),
        start + Duration(seconds: span),
      );
      expect(
        calculateHorizontalScrubTarget(
          startPosition: start,
          duration: duration,
          dragDistance: -viewportWidth / 2,
          viewportWidth: viewportWidth,
          spanSeconds: span,
        ),
        start - Duration(seconds: span ~/ 2),
      );
    }
  });

  test('supports fractional screen distances and reverse drag to origin', () {
    final target = calculateHorizontalScrubTarget(
      startPosition: start,
      duration: duration,
      dragDistance: viewportWidth / 4,
      viewportWidth: viewportWidth,
      spanSeconds: 120,
    );
    expect(target, start + const Duration(seconds: 30));
    expect(
      calculateHorizontalScrubTarget(
        startPosition: start,
        duration: duration,
        dragDistance: 0,
        viewportWidth: viewportWidth,
        spanSeconds: 120,
      ),
      start,
    );
  });

  test('clamps the target at both duration boundaries', () {
    expect(
      calculateHorizontalScrubTarget(
        startPosition: const Duration(seconds: 2),
        duration: duration,
        dragDistance: -viewportWidth * 2,
        viewportWidth: viewportWidth,
        spanSeconds: 600,
      ),
      Duration.zero,
    );
    expect(
      calculateHorizontalScrubTarget(
        startPosition: const Duration(minutes: 9, seconds: 59),
        duration: duration,
        dragDistance: viewportWidth * 2,
        viewportWidth: viewportWidth,
        spanSeconds: 600,
      ),
      const Duration(minutes: 29, seconds: 59),
    );
  });

  test('invalid inputs do not throw and preserve a clamped start', () {
    expect(
      calculateHorizontalScrubTarget(
        startPosition: const Duration(seconds: -2),
        duration: duration,
        dragDistance: 100,
        viewportWidth: 0,
        spanSeconds: 120,
      ),
      Duration.zero,
    );
    expect(
      calculateHorizontalScrubTarget(
        startPosition: const Duration(minutes: 3),
        duration: Duration.zero,
        dragDistance: double.nan,
        viewportWidth: -1,
        spanSeconds: 120,
      ),
      Duration.zero,
    );
    expect(
      calculateHorizontalScrubTarget(
        startPosition: const Duration(minutes: 3),
        duration: duration,
        dragDistance: double.infinity,
        viewportWidth: viewportWidth,
        spanSeconds: 999,
      ),
      const Duration(minutes: 3),
    );
  });

  test('invalid span falls back to 120 seconds', () {
    expect(
      normalizeHorizontalSwipeSeekSpanSeconds(999),
      defaultHorizontalSwipeSeekSpanSeconds,
    );
    expect(
      calculateHorizontalScrubTarget(
        startPosition: start,
        duration: duration,
        dragDistance: viewportWidth,
        viewportWidth: viewportWidth,
        spanSeconds: 999,
      ),
      start + const Duration(seconds: 120),
    );
  });

  test('sample position never requests a frame at the exact end', () {
    expect(
      previewSamplePosition(target: duration, duration: duration),
      duration - const Duration(milliseconds: 1),
    );
    expect(
      previewSamplePosition(
        target: const Duration(seconds: 20),
        duration: duration,
      ),
      const Duration(seconds: 20),
    );
    expect(
      previewSamplePosition(
        target: const Duration(seconds: 3),
        duration: const Duration(milliseconds: 1),
      ),
      Duration.zero,
    );
    expect(
      previewSamplePosition(target: start, duration: Duration.zero),
      Duration.zero,
    );
  });
}
