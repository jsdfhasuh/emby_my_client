import 'dart:async';

import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackOperationCoordinator', () {
    test('100 requests execute first and latest with no concurrency', () async {
      final firstGate = Completer<void>();
      final calls = <Duration>[];
      var concurrent = 0;
      var maximumConcurrent = 0;
      late PlaybackOperationCoordinator coordinator;
      coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('session'),
        clampTarget: _clamp,
        seekEngine: (target) async {
          calls.add(target);
          concurrent++;
          maximumConcurrent = concurrent > maximumConcurrent
              ? concurrent
              : maximumConcurrent;
          if (calls.length == 1) await firstGate.future;
          coordinator.updateCommittedPosition(target);
          concurrent--;
        },
      );

      final futures = <Future<SeekResult>>[];
      for (var index = 1; index <= 100; index++) {
        futures.add(
          coordinator.seekAbsolute(
            Duration(seconds: index),
            source: SeekSource.progressBar,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      firstGate.complete();
      final results = await Future.wait(futures);

      expect(calls, [const Duration(seconds: 1), const Duration(seconds: 100)]);
      expect(maximumConcurrent, 1);
      expect(
        results.where(
          (result) => result.disposition == SeekDisposition.executed,
        ),
        hasLength(2),
      );
      expect(
        results.where(
          (result) => result.disposition == SeekDisposition.superseded,
        ),
        hasLength(98),
      );
      expect(results.last.committedPosition, const Duration(seconds: 100));
    });

    test('relative targets accumulate and absolute replaces pending', () async {
      final firstGate = Completer<void>();
      final calls = <Duration>[];
      late PlaybackOperationCoordinator coordinator;
      coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('session'),
        clampTarget: _clamp,
        seekEngine: (target) async {
          calls.add(target);
          if (calls.length == 1) await firstGate.future;
          coordinator.updateCommittedPosition(target);
        },
      )..updateCommittedPosition(const Duration(minutes: 5));

      final first = coordinator.seekRelative(
        const Duration(seconds: 10),
        source: SeekSource.doubleTap,
      );
      final intermediate = <Future<SeekResult>>[];
      for (var index = 0; index < 8; index++) {
        intermediate.add(
          coordinator.seekRelative(
            const Duration(seconds: 10),
            source: SeekSource.doubleTap,
          ),
        );
      }
      final lastRelative = coordinator.seekRelative(
        const Duration(seconds: 10),
        source: SeekSource.doubleTap,
      );
      final absolute = coordinator.seekAbsolute(
        const Duration(minutes: 9),
        source: SeekSource.chapter,
      );
      firstGate.complete();

      expect((await first).disposition, SeekDisposition.executed);
      expect((await lastRelative).disposition, SeekDisposition.superseded);
      expect((await absolute).disposition, SeekDisposition.executed);
      expect(
        (await Future.wait(
          intermediate,
        )).every((result) => result.disposition == SeekDisposition.superseded),
        isTrue,
      );
      expect(calls, [
        const Duration(minutes: 5, seconds: 10),
        const Duration(minutes: 9),
      ]);
    });

    test(
      'relative requests accumulate to the final requested target',
      () async {
        final firstGate = Completer<void>();
        final calls = <Duration>[];
        late PlaybackOperationCoordinator coordinator;
        coordinator = PlaybackOperationCoordinator(
          sessionId: const PlaybackItemSessionId('session'),
          clampTarget: _clamp,
          seekEngine: (target) async {
            calls.add(target);
            if (calls.length == 1) await firstGate.future;
            coordinator.updateCommittedPosition(target);
          },
        )..updateCommittedPosition(const Duration(minutes: 5));

        final futures = List<Future<SeekResult>>.generate(
          10,
          (_) => coordinator.seekRelative(
            const Duration(seconds: 10),
            source: SeekSource.doubleTap,
          ),
        );
        expect(
          coordinator.requestedPosition,
          const Duration(minutes: 6, seconds: 40),
        );
        firstGate.complete();
        await Future.wait(futures);

        expect(calls.last, const Duration(minutes: 6, seconds: 40));
      },
    );

    test(
      'call timeout fails requests without starting a concurrent seek',
      () async {
        final nativeGate = Completer<void>();
        var calls = 0;
        final coordinator = PlaybackOperationCoordinator(
          sessionId: const PlaybackItemSessionId('session'),
          clampTarget: _clamp,
          seekCallTimeout: const Duration(milliseconds: 10),
          seekEngine: (_) async {
            calls++;
            await nativeGate.future;
          },
        );

        final first = coordinator.seekAbsolute(
          const Duration(minutes: 1),
          source: SeekSource.progressBar,
        );
        final pending = coordinator.seekAbsolute(
          const Duration(minutes: 2),
          source: SeekSource.progressBar,
        );

        expect((await first).failureKind, SeekFailureKind.callTimeout);
        expect(
          (await pending).failureKind,
          SeekFailureKind.higherPriorityOperation,
        );
        expect(calls, 1);
        final blocked = await coordinator.seekAbsolute(
          const Duration(minutes: 3),
          source: SeekSource.progressBar,
        );
        expect(blocked.failureKind, SeekFailureKind.higherPriorityOperation);
        nativeGate.complete();
      },
    );

    test('settle timeout is failed and shutdown cancels immediately', () async {
      final coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('session'),
        clampTarget: _clamp,
        seekSettleTimeout: const Duration(milliseconds: 10),
        seekEngine: (_) async {},
      );

      final timeout = await coordinator.seekAbsolute(
        const Duration(minutes: 1),
        source: SeekSource.progressBar,
      );
      expect(timeout.disposition, SeekDisposition.failed);
      expect(timeout.failureKind, SeekFailureKind.settleTimeout);

      final nativeGate = Completer<void>();
      final shutdownCoordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('shutdown'),
        clampTarget: _clamp,
        seekEngine: (_) => nativeGate.future,
      );
      final inFlight = shutdownCoordinator.seekAbsolute(
        const Duration(minutes: 2),
        source: SeekSource.remote,
      );
      final pending = shutdownCoordinator.seekAbsolute(
        const Duration(minutes: 3),
        source: SeekSource.remote,
      );
      shutdownCoordinator.shutdown();

      expect((await inFlight).disposition, SeekDisposition.cancelled);
      expect((await pending).disposition, SeekDisposition.cancelled);
      nativeGate.complete();
    });
  });

  test('automatic open reasons are one-shot and bounded', () {
    final session = PlaybackItemSession.forTest('session');
    for (final reason in AutomaticPlaybackOpenReason.values) {
      expect(session.tryReserveAutomaticOpen(reason), isTrue);
      expect(session.tryReserveAutomaticOpen(reason), isFalse);
    }
    expect(
      session.automaticOpenCount,
      PlaybackItemSession.maximumAutomaticOpenCount,
    );
  });
}

Duration _clamp(Duration target) {
  if (target < Duration.zero) return Duration.zero;
  const maximum = Duration(hours: 2);
  return target > maximum ? maximum : target;
}
