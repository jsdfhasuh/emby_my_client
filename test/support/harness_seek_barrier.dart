import 'dart:async';

class HarnessSeekSample {
  const HarnessSeekSample({
    required this.positionSeconds,
    required this.seeking,
    required this.paused,
  });
  final double positionSeconds;
  final bool seeking;
  final bool paused;
}

/// Command acknowledgements and cached position streams are not seek completion.
/// Validate the paused native landing point before measuring fresh advancement.
Future<void> advanceHarnessAfterSeek({
  required Duration target,
  required Future<void> Function() pause,
  required Future<void> Function(Duration) seek,
  required Future<void> Function() play,
  required Future<HarnessSeekSample> Function() readNative,
  Duration timeout = const Duration(seconds: 10),
  Future<void> Function(Duration)? delay,
}) async {
  final sleep = delay ?? Future<void>.delayed;
  final seconds = target.inMicroseconds / Duration.microsecondsPerSecond;
  Future<void> wait(
    bool Function(HarnessSeekSample) ready,
    String phase,
  ) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final sample = await readNative().timeout(timeout - watch.elapsed);
      if (sample.positionSeconds.isFinite && ready(sample)) return;
      await sleep(const Duration(milliseconds: 20));
    }
    throw TimeoutException('Harness native $phase did not settle');
  }

  await pause().timeout(timeout);
  await seek(target).timeout(timeout);
  await wait(
    (sample) =>
        sample.paused &&
        !sample.seeking &&
        (sample.positionSeconds - seconds).abs() <= 0.1,
    'seek',
  );
  await play().timeout(timeout);
  await wait(
    (sample) =>
        !sample.paused &&
        !sample.seeking &&
        sample.positionSeconds >= seconds + 0.15,
    'advancement',
  );
  await pause().timeout(timeout);
  await wait((sample) => sample.paused && !sample.seeking, 'pause');
}
