import 'dart:async';

import 'playback_operation_coordinator.dart';

typedef ClosePlaybackItem = Future<void> Function();
typedef OpenPlaybackItem = Future<void> Function(PlaybackItemSession session);

class PlayerSessionCoordinator {
  PlaybackItemSession? _currentSession;
  Future<void> _operation = Future<void>.value();
  bool _shutdown = false;

  PlaybackItemSession? get currentSession => _currentSession;
  bool get isShutdown => _shutdown;

  PlaybackItemSession beginInitialItem() {
    if (_shutdown || _currentSession != null) {
      throw StateError('A playback item session is already active');
    }
    final session = PlaybackItemSession.create();
    _currentSession = session;
    return session;
  }

  Future<void> switchItem({
    required ClosePlaybackItem closeCurrent,
    required OpenPlaybackItem openNext,
  }) => _enqueue(() async {
    if (_shutdown) return;
    await closeCurrent();
    if (_shutdown) return;
    final next = PlaybackItemSession.create();
    _currentSession = next;
    await openNext(next);
  });

  Future<void> recreateCurrent({
    required ClosePlaybackItem closeCurrent,
    required OpenPlaybackItem reopen,
  }) => _enqueue(() async {
    if (_shutdown) return;
    final current = _currentSession;
    if (current == null) throw StateError('No playback item session is active');
    await closeCurrent();
    if (_shutdown) return;
    await reopen(current);
  });

  Future<T> recreateCurrentResource<T>({
    required PlaybackItemSessionId sessionId,
    required Future<T> Function() recreate,
  }) {
    final completer = Completer<T>();
    unawaited(
      _enqueue(() async {
        if (_shutdown) {
          throw StateError('Player session is shutting down');
        }
        final current = _currentSession;
        if (current == null || current.id != sessionId) {
          throw StateError('Playback item session is stale');
        }
        completer.complete(await recreate());
      }).catchError((Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      }),
    );
    return completer.future;
  }

  Future<void> shutdown(ClosePlaybackItem closeCurrent) {
    if (_shutdown) return _operation;
    _shutdown = true;
    return _enqueue(() async {
      await closeCurrent();
      _currentSession = null;
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.catchError((Object _) {});
    return next;
  }
}
