import 'package:emby_my_client/playback/source_read_ahead_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void stableWindow(SourceReadAheadPolicy policy) {
  final generation = policy.generation;
  final size = policy.rangeBytes;
  for (var i = 0; i < 4; i++) {
    policy.completed(
      bytes: size,
      elapsed: const Duration(milliseconds: 400),
      sampleGeneration: generation,
    );
  }
  policy.consumed(4 * size);
}

void main() {
  const mib = SourceReadAheadPolicy.mib;
  test(
    'a slower promoted tier rolls back and avoids repeated failed trials until reset',
    () {
      final policy = SourceReadAheadPolicy();
      stableWindow(policy);
      expect(policy.rangeBytes, 4 * mib);
      final promoted = policy.generation;
      for (var i = 0; i < 4; i++) {
        policy.completed(
          bytes: 4 * mib,
          elapsed: const Duration(milliseconds: 1500),
          sampleGeneration: promoted,
        );
      }
      expect(policy.rangeBytes, 2 * mib);
      for (var i = 0; i < 4; i++) {
        stableWindow(policy);
      }
      expect(policy.rangeBytes, 2 * mib);
      policy.reset();
      stableWindow(policy);
      expect(policy.rangeBytes, 4 * mib);
    },
  );
  test(
    'slow startup and failed requests can fall below the 2 MiB starting tier',
    () {
      final policy = SourceReadAheadPolicy();
      policy.completed(
        bytes: 2 * mib,
        elapsed: const Duration(seconds: 5),
        sampleGeneration: policy.generation,
      );
      expect(policy.rangeBytes, mib);
      stableWindow(policy);
      expect(policy.rangeBytes, 2 * mib);
      policy.failed();
      expect(policy.rangeBytes, mib);
      policy.reset();
      expect(policy.rangeBytes, 2 * mib);
    },
  );
  test(
    'stable sequential use grows through all tiers with bounded windows',
    () {
      final policy = SourceReadAheadPolicy();
      for (final tier in [2, 4, 6]) {
        expect(policy.rangeBytes, tier * mib);
        expect(
          policy.concurrency(8) * policy.rangeBytes,
          lessThanOrEqualTo(SourceReadAheadPolicy.windowBudget),
        );
        stableWindow(policy);
      }
      expect(policy.rangeBytes, 6 * mib);
      expect(policy.concurrency(8), 4);
    },
  );
  test('speculative bursts alone and tiny EOF tails cannot promote', () {
    final policy = SourceReadAheadPolicy();
    for (var i = 0; i < 20; i++) {
      policy.completed(
        bytes: 2 * mib,
        elapsed: const Duration(milliseconds: 50),
        sampleGeneration: policy.generation,
      );
    }
    expect(policy.rangeBytes, 2 * mib);
    policy.reset();
    policy.consumed(30 * mib);
    for (var i = 0; i < 20; i++) {
      policy.completed(
        bytes: 137,
        elapsed: const Duration(milliseconds: 1),
        sampleGeneration: policy.generation,
      );
    }
    policy.consumed(65536);
    expect(policy.rangeBytes, 2 * mib);
  });
  test('slow responses shrink once; old completions cannot shrink again', () {
    final policy = SourceReadAheadPolicy();
    for (var i = 0; i < 3; i++) {
      stableWindow(policy);
    }
    final old = policy.generation;
    for (var i = 0; i < 8; i++) {
      policy.completed(
        bytes: 6 * mib,
        elapsed: const Duration(seconds: 5),
        sampleGeneration: old,
      );
    }
    expect(policy.rangeBytes, 4 * mib);
    stableWindow(policy);
    expect(policy.rangeBytes, 6 * mib);
  });
  test('seek reset discards old evidence and fixed mode stays fixed', () {
    final policy = SourceReadAheadPolicy();
    stableWindow(policy);
    final old = policy.generation;
    policy.reset();
    for (var i = 0; i < 8; i++) {
      policy.completed(
        bytes: 2 * mib,
        elapsed: const Duration(milliseconds: 1),
        sampleGeneration: old,
      );
    }
    policy.consumed(30 * mib);
    expect(policy.rangeBytes, 2 * mib);
    final fixed = SourceReadAheadPolicy(fixedRangeBytes: 2 * mib);
    for (var i = 0; i < 4; i++) {
      stableWindow(fixed);
    }
    expect(fixed.rangeBytes, 2 * mib);
  });
}
