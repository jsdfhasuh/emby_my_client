import 'dart:async';

import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackOperationCoordinator', () {
    test('native operation budgets match the shutdown contract', () {
      const timeouts = PlaybackNativeOperationTimeouts();

      expect(timeouts.urgentMute, const Duration(milliseconds: 750));
      expect(timeouts.play, const Duration(seconds: 3));
      expect(timeouts.pause, const Duration(seconds: 3));
      expect(timeouts.lifecycleQuiesce, const Duration(seconds: 2));
      expect(timeouts.retirementQuiesce, const Duration(seconds: 3));
      expect(timeouts.seek, const Duration(seconds: 8));
      expect(timeouts.stop, const Duration(seconds: 5));
      expect(timeouts.open, const Duration(seconds: 18));
      expect(timeouts.propertyWrite, const Duration(seconds: 2));
      expect(timeouts.dispose, const Duration(seconds: 5));
      expect(timeouts.shutdownBarrier, const Duration(seconds: 5));
    });

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
        await coordinator.shutdown();
      },
    );

    test(
      'settle timeout fails and shutdown waits for the native seek barrier',
      () async {
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
        var shutdownCompleted = false;
        final shutdown = shutdownCoordinator.shutdown().then(
          (_) => shutdownCompleted = true,
        );

        expect((await inFlight).disposition, SeekDisposition.cancelled);
        expect((await pending).disposition, SeekDisposition.cancelled);
        await Future<void>.delayed(Duration.zero);
        expect(shutdownCompleted, isFalse);
        nativeGate.complete();
        await shutdown;
        expect(shutdownCompleted, isTrue);
      },
    );

    test(
      'higher-priority operations cancel pending and in-flight seeks',
      () async {
        final nativeGate = Completer<void>();
        final coordinator = PlaybackOperationCoordinator(
          sessionId: const PlaybackItemSessionId('priority-seek'),
          clampTarget: _clamp,
          seekEngine: (_) => nativeGate.future,
        );

        final inFlight = coordinator.seekAbsolute(
          const Duration(minutes: 1),
          source: SeekSource.progressBar,
        );
        await Future<void>.delayed(Duration.zero);
        final pending = coordinator.seekAbsolute(
          const Duration(minutes: 2),
          source: SeekSource.progressBar,
        );

        coordinator.invalidateForHigherPriorityOperation();

        final results = await Future.wait([inFlight, pending]);
        expect(
          results.map((result) => result.disposition),
          everyElement(SeekDisposition.cancelled),
        );
        expect(
          results.map((result) => result.failureKind),
          everyElement(SeekFailureKind.higherPriorityOperation),
        );
        nativeGate.complete();
        await coordinator.shutdown();
      },
    );

    test(
      'quiescence cancels logical seek before the native seek completes',
      () async {
        final seekStarted = Completer<void>();
        final nativeSeekGate = Completer<void>();
        final quiescenceStarted = Completer<void>();
        final coordinator = PlaybackOperationCoordinator(
          sessionId: const PlaybackItemSessionId('quiesce-seek'),
          clampTarget: _clamp,
          seekEngine: (_) async {
            seekStarted.complete();
            await nativeSeekGate.future;
          },
        );

        final seek = coordinator.seekAbsolute(
          const Duration(minutes: 1),
          source: SeekSource.progressBar,
        );
        await seekStarted.future;
        final quiescence = coordinator.beginQuiescence(
          kind: PlaybackNativeOperationKind.retirementQuiesce,
          operation: () async {
            quiescenceStarted.complete();
          },
        );

        await quiescenceStarted.future;
        final result = await seek;
        expect(result.disposition, SeekDisposition.cancelled);
        expect(result.failureKind, SeekFailureKind.higherPriorityOperation);

        var shutdownCompleted = false;
        final shutdown = coordinator.shutdown().then(
          (_) => shutdownCompleted = true,
        );
        await quiescence;
        await Future<void>.delayed(Duration.zero);
        expect(shutdownCompleted, isFalse);

        nativeSeekGate.complete();
        await shutdown;
        expect(shutdownCompleted, isTrue);
      },
    );

    test('quiescence starts while a tracked native play is blocked', () async {
      final playStarted = Completer<void>();
      final playGate = Completer<void>();
      final quiescenceStarted = Completer<void>();
      final quiescenceGate = Completer<void>();
      final coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('quiesce-play'),
        clampTarget: _clamp,
        seekEngine: (_) async {},
      );

      final play = coordinator.runTrackedNativeOperation(
        kind: PlaybackNativeOperationKind.play,
        operation: () async {
          playStarted.complete();
          await playGate.future;
        },
      );
      await playStarted.future;
      final quiescence = coordinator.beginQuiescence(
        kind: PlaybackNativeOperationKind.retirementQuiesce,
        operation: () async {
          quiescenceStarted.complete();
          await quiescenceGate.future;
        },
      );

      await quiescenceStarted.future;
      var shutdownCompleted = false;
      final shutdown = coordinator.shutdown().then(
        (_) => shutdownCompleted = true,
      );
      quiescenceGate.complete();
      await quiescence;
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);

      playGate.complete();
      await play;
      await shutdown;
      expect(shutdownCompleted, isTrue);
    });

    test('bounded native barriers release shutdown after timeout', () async {
      final nativeGate = Completer<void>();
      final coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('bounded-native-barrier'),
        clampTarget: _clamp,
        seekEngine: (_) async {},
      );

      final nativeOperation = coordinator.startTrackedNativeOperation(
        kind: PlaybackNativeOperationKind.play,
        operation: () => nativeGate.future,
        barrierTimeout: const Duration(milliseconds: 10),
      );

      await coordinator.shutdown().timeout(const Duration(milliseconds: 200));
      expect(
        (await nativeOperation.barrierFuture).disposition,
        PlaybackNativeBarrierDisposition.timedOut,
      );
      await expectLater(
        nativeOperation.logicalFuture,
        throwsA(isA<PlaybackNativeOperationTimedOut>()),
      );
      var nativeCompleted = false;
      nativeOperation.nativeFuture.then<void>((_) => nativeCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCompleted, isFalse);

      nativeGate.complete();
      await nativeOperation.nativeFuture;
    });

    test('shutdown has one overall barrier for a never-ending open', () async {
      final nativeGate = Completer<void>();
      final coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('shutdown-total-barrier'),
        clampTarget: _clamp,
        seekEngine: (_) async {},
        nativeOperationTimeouts: const PlaybackNativeOperationTimeouts(
          open: Duration(hours: 1),
          shutdownBarrier: Duration(milliseconds: 10),
        ),
      );
      final nativeOperation = coordinator.startTrackedNativeOperation(
        kind: PlaybackNativeOperationKind.open,
        operation: () => nativeGate.future,
      );

      await coordinator.shutdown().timeout(const Duration(milliseconds: 200));
      expect(coordinator.isShutdown, isTrue);

      nativeGate.complete();
      await nativeOperation.nativeFuture;
    });

    test('control operations use the frozen priority order', () async {
      final events = <String>[];
      final userStarted = Completer<void>();
      var invalidations = 0;
      final coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('priority'),
        clampTarget: _clamp,
        seekEngine: (_) async {},
        onControlOperationInvalidated: () => invalidations++,
      );

      final user = coordinator.runControlOperation(
        priority: PlaybackControlOperationPriority.userReconfigure,
        operation: (lease) async {
          events.add('user-started');
          userStarted.complete();
          await lease.cancelled;
          events.add('user-cancelled');
        },
      );
      await userStarted.future;
      final cache = coordinator.runControlOperation(
        priority: PlaybackControlOperationPriority.cacheSafety,
        operation: (_) async => events.add('cache'),
      );
      final recovery = coordinator.runControlOperation(
        priority: PlaybackControlOperationPriority.runtimeRecovery,
        operation: (_) async => events.add('recovery'),
      );

      await Future.wait([user, cache, recovery]);

      expect(events, ['user-started', 'user-cancelled', 'recovery']);
      expect(invalidations, 2);
    });

    test('shutdown releases active and pending control operations', () async {
      final activeStarted = Completer<void>();
      final coordinator = PlaybackOperationCoordinator(
        sessionId: const PlaybackItemSessionId('control-shutdown'),
        clampTarget: _clamp,
        seekEngine: (_) async {},
      );
      final active = coordinator.runControlOperation(
        priority: PlaybackControlOperationPriority.userReconfigure,
        operation: (lease) async {
          activeStarted.complete();
          await lease.cancelled;
        },
      );
      await activeStarted.future;
      var pendingRan = false;
      final pending = coordinator.runControlOperation(
        priority: PlaybackControlOperationPriority.userReconfigure,
        operation: (_) async => pendingRan = true,
      );

      final shutdown = coordinator.shutdown();

      await Future.wait([active, pending]);
      await shutdown;
      expect(pendingRan, isFalse);
    });

    test(
      'late seek result is rejected when the session identity is stale',
      () async {
        final nativeGate = Completer<void>();
        var sessionCurrent = true;
        final coordinator = PlaybackOperationCoordinator(
          sessionId: const PlaybackItemSessionId('identity'),
          isSessionCurrent: (_) => sessionCurrent,
          clampTarget: _clamp,
          seekEngine: (_) => nativeGate.future,
        );

        final result = coordinator.seekAbsolute(
          const Duration(minutes: 1),
          source: SeekSource.remote,
        );
        await Future<void>.delayed(Duration.zero);
        sessionCurrent = false;
        nativeGate.complete();

        final settled = await result;
        expect(settled.disposition, SeekDisposition.cancelled);
        expect(settled.failureKind, SeekFailureKind.staleSession);
      },
    );
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
