import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness_seek_barrier.dart';

void main() {
  test(
    'a cached older position cannot release the next seek or pause playback',
    () async {
      var mode = 0, landingReads = 0, advancingReads = 0, pauses = 0;
      final calls = <String>[];
      await advanceHarnessAfterSeek(
        target: const Duration(seconds: 3),
        pause: () async {
          calls.add('pause');
          pauses++;
          if (pauses == 2) mode = 2;
        },
        seek: (target) async {
          calls.add('seek');
          expect(target.inSeconds, 3);
        },
        play: () async {
          expect(landingReads, 3);
          calls.add('play');
          mode = 1;
        },
        readNative: () async {
          if (mode == 0) {
            landingReads++;
            return switch (landingReads) {
              1 => const HarnessSeekSample(
                positionSeconds: 3.5,
                seeking: false,
                paused: true,
              ),
              2 => const HarnessSeekSample(
                positionSeconds: 2.9,
                seeking: true,
                paused: true,
              ),
              _ => const HarnessSeekSample(
                positionSeconds: 3,
                seeking: false,
                paused: true,
              ),
            };
          }
          if (mode == 1) {
            advancingReads++;
            expect(pauses, 1);
            return HarnessSeekSample(
              positionSeconds: advancingReads == 1 ? 3 : 3.5,
              seeking: false,
              paused: false,
            );
          }
          return const HarnessSeekSample(
            positionSeconds: 3.5,
            seeking: false,
            paused: true,
          );
        },
        delay: (_) async {},
      );
      expect(calls, ['pause', 'seek', 'play', 'pause']);
      expect(advancingReads, 2);
    },
  );

  test('a fast seek need not expose a transient seeking=true event', () async {
    var paused = true, position = 3.0;
    await advanceHarnessAfterSeek(
      target: const Duration(seconds: 3),
      pause: () async {
        paused = true;
      },
      seek: (_) async {},
      play: () async {
        paused = false;
        position = 3.5;
      },
      readNative: () async => HarnessSeekSample(
        positionSeconds: position,
        seeking: false,
        paused: paused,
      ),
    );
    expect(paused, isTrue);
  });

  test(
    'a stale native landing point times out without starting playback',
    () async {
      var played = false;
      await expectLater(
        advanceHarnessAfterSeek(
          target: const Duration(seconds: 3),
          pause: () async {},
          seek: (_) async {},
          play: () async {
            played = true;
          },
          readNative: () async => const HarnessSeekSample(
            positionSeconds: 3.5,
            seeking: false,
            paused: true,
          ),
          timeout: const Duration(milliseconds: 30),
          delay: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(played, isFalse);
    },
  );
}
