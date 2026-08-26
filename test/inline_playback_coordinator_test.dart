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
    'deactivation pauses before shutdown and restores local position',
    () async {
      final harness = _SessionHarness();
      final coordinator = InlinePlaybackCoordinator(factory: harness.create);
      final item = _video('a');
      await coordinator.activate(item);
      harness.sessions.single.setPosition(const Duration(seconds: 37));

      final deactivation = coordinator.deactivate();
      expect(harness.events.last, 'pause:a');
      await deactivation;

      expect(harness.events, containsAllInOrder(['pause:a', 'shutdown:a']));
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
        'pause:a',
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
      expect(stale.pauseCalls, greaterThanOrEqualTo(1));
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
    expect(session.pauseCalls, 1);
    await coordinator.handleAppLifecycleState(AppLifecycleState.resumed);
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
  Object? nextStartError;
  int activeSessions = 0;
  int maxActiveSessions = 0;

  Future<InlinePlaybackSession> create(EmbyItem item) async {
    final session = _FakeInlinePlaybackSession(
      itemId: item.id,
      harness: this,
      startGate: nextStartGate,
      startError: nextStartError,
    );
    nextStartGate = null;
    nextStartError = null;
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
}

class _FakeInlinePlaybackSession extends ChangeNotifier
    implements InlinePlaybackSession {
  _FakeInlinePlaybackSession({
    required this.itemId,
    required this.harness,
    this.startGate,
    this.startError,
  }) : _state = InlinePlaybackState(itemId: itemId);

  @override
  final String itemId;
  final _SessionHarness harness;
  final Completer<void>? startGate;
  final Object? startError;
  InlinePlaybackState _state;
  bool _shutdown = false;
  int startCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int shutdownCalls = 0;
  int memoryPressureCalls = 0;
  final List<Duration?> resumePositions = [];
  final List<Duration> seekPositions = [];

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
    _setState(
      _state.copyWith(
        phase: InlinePlaybackPhase.ready,
        isPlaying: true,
        isCompleted: false,
      ),
    );
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    harness.events.add('pause:$itemId');
    _setState(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> seek(Duration position) async {
    seekPositions.add(position);
    _setState(
      _state.copyWith(
        position: position,
        isCompleted: position >= _state.duration,
      ),
    );
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
