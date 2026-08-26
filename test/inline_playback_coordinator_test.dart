import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/inline_playback_coordinator.dart';
import 'package:emby_my_client/playback/inline_playback_session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('activation creates, starts, and autoplays one session', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    await coordinator.activate(_video('a'));

    expect(harness.sessions, hasLength(1));
    expect(harness.sessions.single.startCalls, 1);
    expect(harness.sessions.single.playCalls, 1);
    expect(harness.maxActiveSessions, 1);
    expect(coordinator.state.itemId, 'a');
    expect(coordinator.state.phase, InlinePlaybackPhase.ready);
    expect(coordinator.state.isPlaying, isTrue);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('activating the current video is idempotent', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    await coordinator.activate(_video('a'));
    await coordinator.activate(_video('a'));

    expect(harness.sessions, hasLength(1));
    expect(harness.sessions.single.startCalls, 1);
    expect(harness.sessions.single.playCalls, 1);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'deactivation quiesces before shutdown and restores local position',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      final item = _video('a');
      await coordinator.activate(item);
      harness.sessions.single.setPosition(const Duration(seconds: 37));

      final deactivation = coordinator.deactivate();
      expect(harness.events.last, 'quiesce:a');
      await deactivation;

      expect(harness.events, containsAllInOrder(['quiesce:a', 'shutdown:a']));
      expect(harness.activeSessions, 0);

      await coordinator.activate(item);
      expect(harness.sessions, hasLength(2));
      expect(harness.sessions.last.resumePositions, [
        const Duration(seconds: 37),
      ]);
      expect(harness.maxActiveSessions, 1);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('video switch fully closes A before creating B', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));

    await coordinator.activate(_video('b'));

    expect(
      harness.events,
      containsAllInOrder([
        'create:a',
        'start:a',
        'play:a',
        'quiesce:a',
        'shutdown:a',
        'create:b',
        'start:b',
        'play:b',
      ]),
    );
    expect(harness.maxActiveSessions, 1);
    expect(coordinator.state.itemId, 'b');
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'late initialization after a swipe never plays or publishes state',
    () async {
      final harness = _SessionHarness();
      final startGate = Completer<void>();
      harness.nextStartGate = startGate;
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);

      final activation = coordinator.activate(_video('a'));
      await harness.waitForSessionCount(1);
      final deactivation = coordinator.deactivate();
      startGate.complete();
      await Future.wait([activation, deactivation]);

      final stale = harness.sessions.single;
      expect(stale.playCalls, 0);
      expect(stale.quiesceCalls, 1);
      expect(stale.shutdownCalls, 1);
      expect(coordinator.state.phase, InlinePlaybackPhase.inactive);
      expect(coordinator.state.itemId, isNull);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('rapid A to photo to B cannot revive A', () async {
    final harness = _SessionHarness();
    final startGate = Completer<void>();
    harness.nextStartGate = startGate;
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    final activationA = coordinator.activate(_video('a'));
    await harness.waitForSessionCount(1);
    final photo = coordinator.deactivate();
    final activationB = coordinator.activate(_video('b'));
    startGate.complete();
    await Future.wait([activationA, photo, activationB]);

    expect(harness.sessions, hasLength(2));
    expect(harness.sessions.first.playCalls, 0);
    expect(harness.sessions.first.shutdownCalls, 1);
    expect(harness.sessions.last.playCalls, 1);
    expect(coordinator.state.itemId, 'b');
    expect(harness.maxActiveSessions, 1);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('failed retry creates a fresh session', () async {
    final harness = _SessionHarness();
    harness.nextStartError = StateError('offline');
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));

    expect(coordinator.state.phase, InlinePlaybackPhase.failed);
    expect(coordinator.state.errorMessage, isNotEmpty);
    expect(harness.sessions.single.shutdownCalls, 1);

    await coordinator.retry();

    expect(harness.sessions, hasLength(2));
    expect(harness.sessions.last.startCalls, 1);
    expect(harness.sessions.last.resumePositions, [isNull]);
    expect(harness.sessions.last.playCalls, 1);
    expect(coordinator.state.phase, InlinePlaybackPhase.ready);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('shutdown is single-flight and prevents later activation', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));

    await Future.wait([coordinator.shutdown(), coordinator.shutdown()]);
    await coordinator.activate(_video('b'));

    expect(harness.sessions, hasLength(1));
    expect(harness.sessions.single.shutdownCalls, 1);
    expect(harness.activeSessions, 0);
    coordinator.dispose();
  });

  test('lifecycle resumes only the same session that was playing', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;

    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    expect(session.lifecycleQuiesceCalls, 1);
    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(session.lifecycleResumeCalls, 1);
    expect(session.playCalls, 2);

    await coordinator.pause();
    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(session.playCalls, 2);

    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    await coordinator.deactivate();
    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(session.playCalls, 2);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('factory completion after lifecycle pause never autoplays', () async {
    final harness = _SessionHarness();
    final factoryGate = Completer<void>();
    harness.nextFactoryGate = factoryGate;
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    final activation = coordinator.activate(_video('a'));
    await harness.waitForFactoryCount(1);
    final pause = coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    factoryGate.complete();
    await Future.wait([activation, pause]);

    final session = harness.sessions.single;
    expect(session.playCalls, 0);
    expect(session.lifecycleQuiesceCalls, 1);
    expect(coordinator.state.isPlaying, isFalse);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('start completion after lifecycle pause never autoplays', () async {
    final harness = _SessionHarness();
    final startGate = Completer<void>();
    harness.nextStartGate = startGate;
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    final activation = coordinator.activate(_video('a'));
    await harness.waitForSessionCount(1);
    final pause = coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    startGate.complete();
    await Future.wait([activation, pause]);

    final session = harness.sessions.single;
    expect(session.playCalls, 0);
    expect(session.lifecycleQuiesceCalls, 1);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'an initially suspended coordinator activates without playing',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(
        factory: harness.create,
        initialLifecycleState: AppLifecycleState.paused,
      );

      await coordinator.activate(_video('a'));

      expect(harness.sessions.single.playCalls, 0);
      expect(harness.sessions.single.lifecycleQuiesceCalls, 1);
      expect(coordinator.lifecycleSuspended, isTrue);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('activation while suspended remains ready and paused', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);

    await coordinator.activate(_video('a'));

    expect(harness.sessions.single.playCalls, 0);
    expect(coordinator.state.phase, InlinePlaybackPhase.ready);
    expect(coordinator.state.isPlaying, isFalse);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('resumed does not autoplay a session that never played', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(
      factory: harness.create,
      initialLifecycleState: AppLifecycleState.paused,
    );
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;

    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);

    expect(session.lifecycleResumeCalls, 1);
    expect(session.playCalls, 0);
    expect(coordinator.state.isPlaying, isFalse);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('resumed restores the same session that was actually playing', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;

    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);

    expect(
      harness.events,
      containsAllInOrder([
        'lifecycle-quiesce:a',
        'lifecycle-resume:a',
        'play:a',
      ]),
    );
    expect(session.playCalls, 2);
    expect(coordinator.state.isPlaying, isTrue);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('target changes do not clear global lifecycle suspension', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);

    await coordinator.activate(_video('b'));
    final second = harness.sessions.last;

    expect(coordinator.lifecycleSuspended, isTrue);
    expect(second.playCalls, 0);
    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(second.playCalls, 0);
    expect(harness.sessions.first.playCalls, 1);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('delayed lifecycle pause reconciles to a newer resumed state', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;
    final pauseGate = Completer<void>();
    session.lifecycleQuiesceGate = pauseGate;

    final pause = coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    await _waitUntil(() => session.lifecycleQuiesceCalls == 1);
    final resume = coordinator.handleAppLifecycleState(
      AppLifecycleState.resumed,
    );
    pauseGate.complete();
    await Future.wait([pause, resume]);

    expect(session.lifecycleResumeCalls, 1);
    expect(session.playCalls, 2);
    expect(coordinator.lifecycleSuspended, isFalse);
    expect(coordinator.state.isPlaying, isTrue);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'a newer pause prevents a delayed lifecycle resume from playing',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      await coordinator.activate(_video('a'));
      final session = harness.sessions.single;
      await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
      final resumeGate = Completer<void>();
      session.lifecycleResumeGate = resumeGate;

      final resume = coordinator.handleAppLifecycleState(
        AppLifecycleState.resumed,
      );
      await _waitUntil(() => session.lifecycleResumeCalls == 1);
      final pause = coordinator.handleAppLifecycleState(
        AppLifecycleState.paused,
      );
      resumeGate.complete();
      await Future.wait([resume, pause]);

      expect(session.playCalls, 1);
      expect(coordinator.lifecycleSuspended, isTrue);
      expect(coordinator.state.isPlaying, isFalse);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('a failed lifecycle resume never falls through to play', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;
    await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
    session.lifecycleResumeError = StateError('resume failed');
    final playCallsBeforeResume = session.playCalls;

    await expectLater(
      coordinator.handleAppLifecycleState(AppLifecycleState.resumed),
      completes,
    );
    await coordinator.play();

    expect(session.lifecycleResumeCalls, 2);
    expect(session.playCalls, playCallsBeforeResume);
    expect(session.state.isPlaying, isFalse);
    expect(coordinator.state.isPlaying, isFalse);

    session.lifecycleResumeError = null;
    await coordinator.play();
    expect(session.lifecycleResumeCalls, 3);
    expect(session.playCalls, playCallsBeforeResume + 1);
    expect(coordinator.state.isPlaying, isTrue);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'lifecycle quiescence and user pause use distinct session APIs',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      await coordinator.activate(_video('a'));
      final session = harness.sessions.single;

      await coordinator.handleAppLifecycleState(AppLifecycleState.paused);
      await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);
      final ordinaryPausesBeforeUserAction = session.pauseCalls;
      await coordinator.pause();

      expect(session.lifecycleQuiesceCalls, 1);
      expect(session.lifecycleResumeCalls, 1);
      expect(session.lifecyclePauseCalls, 0);
      expect(session.pauseCalls, ordinaryPausesBeforeUserAction + 1);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('retirement references are released after 101 session churns', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    for (var index = 0; index < 101; index++) {
      await coordinator.activate(_video('video-$index'));
    }
    await coordinator.deactivate();

    expect(harness.maxActiveSessions, 1);
    expect(harness.activeSessions, 0);
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'pending retirement stays single-flight and releases its reference',
    () async {
      final harness = _SessionHarness();
      final shutdownGate = Completer<void>();
      harness.nextShutdownGate = shutdownGate;
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      await coordinator.activate(_video('a'));
      final session = harness.sessions.single;

      final deactivation = coordinator.deactivate();
      await _waitUntil(() => session.shutdownCalls == 1);
      final repeatedDeactivation = coordinator.deactivate();

      expect(coordinator.inFlightRetirementCount, 1);
      expect(session.shutdownCalls, 1);
      expect(harness.activeSessions, 1);
      shutdownGate.complete();
      await Future.wait([deactivation, repeatedDeactivation]);

      expect(session.shutdownCalls, 1);
      expect(harness.activeSessions, 0);
      expect(harness.maxActiveSessions, 1);
      expect(coordinator.inFlightRetirementCount, 0);
      expect(coordinator.inFlightQuiescenceCount, 0);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('failed state returned by start is never followed by play', () async {
    final harness = _SessionHarness();
    harness.nextStartFailureMessage = 'original playback failure';
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    await coordinator.activate(_video('a'));

    final session = harness.sessions.single;
    expect(session.playCalls, 0);
    expect(session.shutdownCalls, 1);
    expect(coordinator.state.phase, InlinePlaybackPhase.failed);
    expect(coordinator.state.errorMessage, 'original playback failure');
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'control operations and retirement settle without async errors',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      await coordinator.activate(_video('a'));
      final session = harness.sessions.single;
      await coordinator.pause();
      final playGate = Completer<void>();
      session.playGate = playGate;

      final play = coordinator.play();
      await _waitUntil(() => session.playCalls == 2);
      final pause = coordinator.pause();
      final seek = coordinator.seek(const Duration(seconds: 12));
      final deactivate = coordinator.deactivate();
      playGate.complete();

      await expectLater(
        Future.wait([play, pause, seek, deactivate]),
        completes,
      );
      expect(session.shutdownCalls, 1);
      expect(harness.activeSessions, 0);
      expect(coordinator.inFlightRetirementCount, 0);
      expect(coordinator.inFlightQuiescenceCount, 0);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('blocked seek + deactivate starts quiescence immediately', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;
    final seekGate = Completer<void>();
    session.seekGate = seekGate;

    final seek = coordinator.seek(const Duration(seconds: 12));
    await _waitUntil(() => session.seekCalls == 1);
    final deactivation = coordinator.deactivate();
    await _waitUntil(() => session.quiesceCalls == 1);

    expect(harness.events, containsAllInOrder(['seek:a', 'quiesce:a']));
    expect(session.maxConcurrentCalls, 2);
    expect(session.shutdownCalls, 0);
    expect(coordinator.state.itemId, isNull);
    expect(coordinator.state.phase, InlinePlaybackPhase.inactive);

    seekGate.complete();
    await Future.wait([seek, deactivation]);

    expect(session.shutdownCalls, 1);
    expect(coordinator.state.itemId, isNull);
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test(
    'blocked seek + lifecycle pause starts lifecycle quiescence immediately',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      await coordinator.activate(_video('a'));
      final session = harness.sessions.single;
      final seekGate = Completer<void>();
      session.seekGate = seekGate;

      final seek = coordinator.seek(const Duration(seconds: 20));
      await _waitUntil(() => session.seekCalls == 1);
      final pause = coordinator.handleAppLifecycleState(
        AppLifecycleState.paused,
      );
      await _waitUntil(() => session.lifecycleQuiesceCalls == 1);

      expect(
        harness.events,
        containsAllInOrder(['seek:a', 'lifecycle-quiesce:a']),
      );
      expect(session.maxConcurrentCalls, 2);
      expect(session.playCalls, 1);
      expect(coordinator.lifecycleSuspended, isTrue);

      seekGate.complete();
      await Future.wait([seek, pause]);
      await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);

      expect(session.lifecycleResumeCalls, 1);
      expect(session.playCalls, 2);
      expect(coordinator.state.isPlaying, isTrue);
      expect(coordinator.inFlightQuiescenceCount, 0);
      await coordinator.shutdown();
      coordinator.dispose();
    },
  );

  test('blocked seek + activate B closes A before creating B', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final sessionA = harness.sessions.single;
    final seekGate = Completer<void>();
    sessionA.seekGate = seekGate;

    final seek = coordinator.seek(const Duration(seconds: 25));
    await _waitUntil(() => sessionA.seekCalls == 1);
    final activationB = coordinator.activate(_video('b'));
    await _waitUntil(() => sessionA.quiesceCalls == 1);

    expect(harness.sessions, hasLength(1));
    expect(sessionA.shutdownCalls, 0);
    expect(coordinator.state.itemId, 'b');
    expect(coordinator.state.phase, InlinePlaybackPhase.loading);

    seekGate.complete();
    await Future.wait([seek, activationB]);

    expect(
      harness.events,
      containsAllInOrder(['quiesce:a', 'shutdown:a', 'create:b']),
    );
    expect(sessionA.shutdownCalls, 1);
    expect(sessionA.playCalls, 1);
    expect(harness.sessions.last.playCalls, 1);
    expect(harness.maxActiveSessions, 1);
    expect(coordinator.state.itemId, 'b');
    await coordinator.shutdown();
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);
    coordinator.dispose();
  });

  test('blocked play + deactivate cannot resurrect stale playback', () async {
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      await coordinator.activate(_video('a'));
      final session = harness.sessions.single;
      await coordinator.pause();
      final playGate = Completer<void>();
      session.playGate = playGate;

      final play = coordinator.play();
      await _waitUntil(() => session.playCalls == 2);
      final deactivation = coordinator.deactivate();
      await _waitUntil(() => session.quiesceCalls == 1);

      expect(session.maxConcurrentCalls, 2);
      expect(coordinator.state.itemId, isNull);
      expect(session.shutdownCalls, 0);

      playGate.complete();
      await Future.wait([play, deactivation]);

      expect(session.state.isPlaying, isFalse);
      expect(session.shutdownCalls, 1);
      expect(coordinator.state.phase, InlinePlaybackPhase.inactive);
      expect(coordinator.inFlightRetirementCount, 0);
      expect(coordinator.inFlightQuiescenceCount, 0);
      await coordinator.shutdown();
      coordinator.dispose();
    }, (error, _) => uncaught.add(error));
    expect(uncaught, isEmpty);
  });

  test('retirement upgrades an in-flight lifecycle quiescence', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;
    final lifecycleGate = Completer<void>();
    session.lifecycleQuiesceGate = lifecycleGate;

    final lifecyclePause = coordinator.handleAppLifecycleState(
      AppLifecycleState.paused,
    );
    await _waitUntil(() => session.lifecycleQuiesceCalls == 1);
    final deactivation = coordinator.deactivate();
    await Future<void>.delayed(Duration.zero);

    expect(session.quiesceCalls, 0);
    expect(session.lifecycleQuiesceCalls, 1);
    expect(coordinator.inFlightQuiescenceCount, 1);
    expect(coordinator.state.phase, InlinePlaybackPhase.inactive);

    lifecycleGate.complete();
    await Future.wait([lifecyclePause, deactivation]);

    expect(session.quiesceCalls, 0);
    expect(session.lifecycleQuiesceCalls, 1);
    expect(session.shutdownCalls, 1);
    expect(harness.activeSessions, 0);
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('memory pressure is forwarded only to the active session', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);

    await coordinator.handleMemoryPressure();
    await coordinator.activate(_video('a'));
    await coordinator.handleMemoryPressure();
    await coordinator.deactivate();
    await coordinator.handleMemoryPressure();

    expect(harness.sessions.single.memoryPressureCalls, 1);
    await coordinator.shutdown();
    coordinator.dispose();
  });

  test('completed playback stays active and replay seeks to zero', () async {
    final harness = _SessionHarness();
    final coordinator = InlinePlaybackCoordinator(factory: harness.create);
    await coordinator.activate(_video('a'));
    final session = harness.sessions.single;
    session.completeAt(const Duration(minutes: 3));

    expect(coordinator.state.isCompleted, isTrue);
    expect(coordinator.state.itemId, 'a');
    await coordinator.play();

    expect(session.seekPositions, [Duration.zero]);
    expect(session.playCalls, 2);
    expect(coordinator.state.itemId, 'a');
    await coordinator.shutdown();
    coordinator.dispose();
  });
}

class _SessionHarness {
  final List<_FakeInlinePlaybackSession> sessions = [];
  final List<String> events = [];
  Completer<void>? nextStartGate;
  Completer<void>? nextFactoryGate;
  Completer<void>? nextShutdownGate;
  Object? nextStartError;
  String? nextStartFailureMessage;
  int factoryCalls = 0;
  int activeSessions = 0;
  int maxActiveSessions = 0;

  Future<InlinePlaybackSession> create(EmbyItem item) async {
    factoryCalls++;
    final factoryGate = nextFactoryGate;
    nextFactoryGate = null;
    await factoryGate?.future;
    final session = _FakeInlinePlaybackSession(
      itemId: item.id,
      harness: this,
      startGate: nextStartGate,
      startError: nextStartError,
      startFailureMessage: nextStartFailureMessage,
      shutdownGate: nextShutdownGate,
    );
    nextStartGate = null;
    nextStartError = null;
    nextStartFailureMessage = null;
    nextShutdownGate = null;
    sessions.add(session);
    activeSessions++;
    if (activeSessions > maxActiveSessions) {
      maxActiveSessions = activeSessions;
    }
    events.add('create:${item.id}');
    return session;
  }

  Future<void> waitForSessionCount(int count) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (sessions.length >= count) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('Timed out waiting for $count inline sessions');
  }

  Future<void> waitForFactoryCount(int count) =>
      _waitUntil(() => factoryCalls >= count);
}

class _FakeInlinePlaybackSession extends ChangeNotifier
    implements InlinePlaybackSession {
  _FakeInlinePlaybackSession({
    required this.itemId,
    required this.harness,
    this.startGate,
    this.startError,
    this.startFailureMessage,
    this.shutdownGate,
  }) : _state = InlinePlaybackState(itemId: itemId);

  @override
  final String itemId;
  final _SessionHarness harness;
  final Completer<void>? startGate;
  final Object? startError;
  final String? startFailureMessage;
  final Completer<void>? shutdownGate;
  InlinePlaybackState _state;
  bool _shutdown = false;
  int startCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int quiesceCalls = 0;
  int lifecyclePauseCalls = 0;
  int lifecycleQuiesceCalls = 0;
  int lifecycleResumeCalls = 0;
  int seekCalls = 0;
  int shutdownCalls = 0;
  int memoryPressureCalls = 0;
  int concurrentCalls = 0;
  int maxConcurrentCalls = 0;
  final List<Duration?> resumePositions = [];
  final List<Duration> seekPositions = [];
  Completer<void>? playGate;
  Completer<void>? pauseGate;
  Completer<void>? quiesceGate;
  Completer<void>? lifecyclePauseGate;
  Completer<void>? lifecycleQuiesceGate;
  Completer<void>? lifecycleResumeGate;
  Object? lifecycleResumeError;
  Completer<void>? seekGate;
  bool _retiring = false;
  bool _lifecycleQuiesced = false;

  @override
  InlinePlaybackState get state => _state;

  @override
  Future<void> start({Duration? resumePosition}) async {
    startCalls++;
    resumePositions.add(resumePosition);
    harness.events.add('start:$itemId');
    _setState(
      _state.copyWith(phase: InlinePlaybackPhase.loading, isBuffering: true),
    );
    await startGate?.future;
    if (startError case final error?) {
      _setState(
        _state.copyWith(
          phase: InlinePlaybackPhase.failed,
          isBuffering: false,
          errorMessage: error.toString(),
        ),
      );
      throw error;
    }
    if (startFailureMessage case final message?) {
      _setState(
        _state.copyWith(
          phase: InlinePlaybackPhase.failed,
          isBuffering: false,
          errorMessage: message,
        ),
      );
      return;
    }
    if (_shutdown) return;
    _setState(
      _state.copyWith(
        phase: InlinePlaybackPhase.ready,
        position: resumePosition ?? Duration.zero,
        duration: const Duration(minutes: 10),
        isBuffering: false,
      ),
    );
  }

  @override
  Future<void> play() async {
    playCalls++;
    harness.events.add('play:$itemId');
    _beginCall();
    try {
      await playGate?.future;
      if (_retiring || _lifecycleQuiesced) return;
      _setState(
        _state.copyWith(
          phase: InlinePlaybackPhase.ready,
          isPlaying: true,
          isCompleted: false,
        ),
      );
    } finally {
      _endCall();
    }
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    harness.events.add('pause:$itemId');
    await pauseGate?.future;
    _setState(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> pauseForLifecycle() async {
    lifecyclePauseCalls++;
    harness.events.add('lifecycle-pause:$itemId');
    _lifecycleQuiesced = true;
    await lifecyclePauseGate?.future;
    _setState(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> quiesce() async {
    quiesceCalls++;
    harness.events.add('quiesce:$itemId');
    _retiring = true;
    _beginCall();
    try {
      await quiesceGate?.future;
      _setState(_state.copyWith(isPlaying: false));
    } finally {
      _endCall();
    }
  }

  @override
  Future<void> quiesceForLifecycle() async {
    lifecycleQuiesceCalls++;
    harness.events.add('lifecycle-quiesce:$itemId');
    _lifecycleQuiesced = true;
    _beginCall();
    try {
      await lifecycleQuiesceGate?.future;
      _setState(_state.copyWith(isPlaying: false));
    } finally {
      _endCall();
    }
  }

  @override
  Future<void> resumeForLifecycle() async {
    lifecycleResumeCalls++;
    harness.events.add('lifecycle-resume:$itemId');
    await lifecycleResumeGate?.future;
    if (lifecycleResumeError case final error?) throw error;
    if (!_retiring) _lifecycleQuiesced = false;
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    harness.events.add('seek:$itemId');
    _beginCall();
    try {
      await seekGate?.future;
      seekPositions.add(position);
      if (_retiring || _lifecycleQuiesced) return;
      _setState(
        _state.copyWith(
          position: position,
          isCompleted: position >= _state.duration,
        ),
      );
    } finally {
      _endCall();
    }
  }

  @override
  Future<void> handleMemoryPressure() async {
    memoryPressureCalls++;
  }

  @override
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    shutdownCalls++;
    harness.events.add('shutdown:$itemId');
    await shutdownGate?.future;
    harness.activeSessions--;
  }

  void setPosition(Duration position) {
    _setState(_state.copyWith(position: position));
  }

  void completeAt(Duration position) {
    _setState(
      _state.copyWith(
        phase: InlinePlaybackPhase.ready,
        position: position,
        duration: position,
        isPlaying: false,
        isCompleted: true,
      ),
    );
  }

  void _setState(InlinePlaybackState value) {
    _state = value;
    notifyListeners();
  }

  void _beginCall() {
    concurrentCalls++;
    if (concurrentCalls > maxConcurrentCalls) {
      maxConcurrentCalls = concurrentCalls;
    }
  }

  void _endCall() {
    concurrentCalls--;
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for asynchronous test condition');
}

EmbyItem _video(String id) => EmbyItem(
  id: id,
  name: 'Video $id',
  type: 'Video',
  mediaType: 'Video',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);
