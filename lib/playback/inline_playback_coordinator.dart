import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../models/emby_models.dart';
import 'inline_playback_session.dart';

typedef InlinePlaybackSessionFactory =
    Future<InlinePlaybackSession> Function(EmbyItem item);

class InlinePlaybackCoordinator extends ChangeNotifier {
  InlinePlaybackCoordinator({
    required InlinePlaybackSessionFactory factory,
    AppLifecycleState initialLifecycleState = AppLifecycleState.resumed,
  }) : _factory = factory,
       _lifecycleSuspended = initialLifecycleState != AppLifecycleState.resumed;

  final InlinePlaybackSessionFactory _factory;
  final Map<String, Duration> _resumePositions = {};
  final Map<InlinePlaybackSession, Future<void>> _retirements = {};
  final Set<InlinePlaybackSession> _mutedSessionNotifications = {};
  InlinePlaybackState _state = const InlinePlaybackState();
  InlinePlaybackSession? _session;
  VoidCallback? _sessionListener;
  EmbyItem? _targetItem;
  final Queue<_QueuedInlineOperation> _operations = Queue();
  bool _operationRunning = false;
  Future<void>? _targetOperation;
  Future<void>? _shutdownOperation;
  int _generation = 0;
  int _lifecycleRevision = 0;
  bool _shuttingDown = false;
  bool _disposed = false;
  bool _lifecycleSuspended;
  bool _sessionLifecycleSuspended = false;
  bool _resumeAfterLifecycle = false;
  InlinePlaybackSession? _lifecycleSession;
  String? _lifecycleItemId;
  int? _lifecycleGeneration;

  InlinePlaybackState get state => _state;
  Map<String, Duration> get resumePositions =>
      Map<String, Duration>.unmodifiable(_resumePositions);

  @visibleForTesting
  int get inFlightRetirementCount => _retirements.length;

  @visibleForTesting
  bool get lifecycleSuspended => _lifecycleSuspended;

  Future<void> activate(EmbyItem item) {
    if (_shuttingDown || _disposed) return Future<void>.value();
    if (_targetItem?.id == item.id) {
      return _targetOperation ?? Future<void>.value();
    }

    final generation = ++_generation;
    final lifecycleRevision = _lifecycleRevision;
    _targetItem = item;
    _clearLifecycleResumeIdentity();
    _publish(
      InlinePlaybackState(
        itemId: item.id,
        phase: InlinePlaybackPhase.loading,
        isBuffering: true,
      ),
    );

    late final Future<void> operation;
    operation = _enqueue(() async {
      final previousSession = _session;
      if (previousSession != null) await _retireSession(previousSession);
      if (!_isCurrent(item.id, generation)) return;
      await _activateCurrent(item, generation, lifecycleRevision);
    });
    _targetOperation = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_targetOperation, operation)) _targetOperation = null;
      }),
    );
    return operation;
  }

  Future<void> deactivate() {
    if (_shuttingDown || _disposed) return Future<void>.value();
    ++_generation;
    _targetItem = null;
    _targetOperation = null;
    _clearLifecycleResumeIdentity();
    _publish(const InlinePlaybackState());
    return _enqueue(() async {
      final session = _session;
      if (session != null) await _retireSession(session);
    });
  }

  Future<void> retry() {
    final item = _targetItem;
    if (item == null || _shuttingDown || _disposed) {
      return Future<void>.value();
    }
    ++_generation;
    _targetItem = null;
    _clearLifecycleResumeIdentity();
    return activate(item);
  }

  Future<void> play() {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    final lifecycleRevision = _lifecycleRevision;
    if (session == null || itemId == null) return Future<void>.value();
    return _enqueue(() async {
      if (!_matches(session, itemId, generation) ||
          _lifecycleSuspended ||
          session.state.hasError) {
        return;
      }
      if (_sessionLifecycleSuspended) {
        final lifecycleResumed = await _ensureLifecycleResumed(session);
        if (!lifecycleResumed ||
            !_matches(session, itemId, generation) ||
            _lifecycleSuspended ||
            _lifecycleRevision != lifecycleRevision) {
          return;
        }
      }
      try {
        if (session.state.isCompleted) {
          await _runMuted(session, () => session.seek(Duration.zero));
          if (!_matches(session, itemId, generation)) return;
        }
        await _runMuted(session, session.play);
        await _finishPlayOperation(
          session: session,
          itemId: itemId,
          generation: generation,
          lifecycleRevision: lifecycleRevision,
        );
      } catch (_) {
        await _failSession(session, itemId, generation);
      }
    });
  }

  Future<void> pause() {
    _clearLifecycleResumeIdentity();
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null || itemId == null) return Future<void>.value();
    return _enqueue(() async {
      if (!_matches(session, itemId, generation)) return;
      await _pauseSafely(session);
      _savePosition(session);
      if (_matches(session, itemId, generation)) _publish(session.state);
    });
  }

  Future<void> seek(Duration position) {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null || itemId == null) return Future<void>.value();
    return _enqueue(() async {
      if (!_matches(session, itemId, generation)) return;
      try {
        await _runMuted(session, () => session.seek(position));
        if (_matches(session, itemId, generation)) _publish(session.state);
      } catch (_) {
        await _failSession(session, itemId, generation);
      }
    });
  }

  Future<void> handleAppLifecycleState(AppLifecycleState lifecycleState) {
    if (_shuttingDown || _disposed) return Future<void>.value();
    final shouldSuspend = lifecycleState != AppLifecycleState.resumed;
    if (shouldSuspend) {
      if (_lifecycleSuspended) return Future<void>.value();
      _lifecycleSuspended = true;
      final revision = ++_lifecycleRevision;
      final session = _session;
      final itemId = _targetItem?.id;
      final generation = _generation;
      final wasPlaying =
          session != null &&
          itemId != null &&
          _matches(session, itemId, generation) &&
          session.state.isPlaying;
      if (wasPlaying) {
        _resumeAfterLifecycle = true;
        _lifecycleSession = session;
        _lifecycleItemId = itemId;
        _lifecycleGeneration = generation;
      } else {
        _clearLifecycleResumeIdentity();
      }
      return _enqueue(() => _reconcileLifecyclePause(revision));
    }

    if (!_lifecycleSuspended) return Future<void>.value();
    _lifecycleSuspended = false;
    final revision = ++_lifecycleRevision;
    final shouldResume = _resumeAfterLifecycle;
    final resumeSession = _lifecycleSession;
    final resumeItemId = _lifecycleItemId;
    final resumeGeneration = _lifecycleGeneration;
    _clearLifecycleResumeIdentity();
    return _enqueue(
      () => _reconcileLifecycleResume(
        revision: revision,
        shouldResume: shouldResume,
        resumeSession: resumeSession,
        resumeItemId: resumeItemId,
        resumeGeneration: resumeGeneration,
      ),
    );
  }

  Future<void> handleMemoryPressure() {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null || itemId == null) return Future<void>.value();
    return _enqueue(() async {
      if (!_matches(session, itemId, generation)) return;
      try {
        await session.handleMemoryPressure();
      } catch (_) {
        // Memory pressure handling must not break the control queue.
      }
    });
  }

  Future<void> shutdown() {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    _shuttingDown = true;
    ++_generation;
    _targetItem = null;
    _targetOperation = null;
    _clearLifecycleResumeIdentity();
    _publish(const InlinePlaybackState());
    return _shutdownOperation = _enqueue(() async {
      final session = _session;
      if (session != null) await _retireSession(session);
    });
  }

  Future<void> _activateCurrent(
    EmbyItem item,
    int generation,
    int activationLifecycleRevision,
  ) async {
    InlinePlaybackSession? session;
    try {
      session = await _factory(item);
      if (!_isCurrent(item.id, generation)) {
        await _retireSession(session);
        return;
      }

      _session = session;
      _sessionLifecycleSuspended = false;
      void listener() {
        if (_matches(session!, item.id, generation) &&
            !_retirements.containsKey(session) &&
            !_mutedSessionNotifications.contains(session)) {
          _publish(session.state);
        }
      }

      _sessionListener = listener;
      session.addListener(listener);
      await session.start(resumePosition: _resumePositions[item.id]);
      if (!_matches(session, item.id, generation)) {
        await _retireSession(session);
        return;
      }
      final startedState = session.state;
      if (startedState.hasError) {
        await _retireSession(session);
        if (_isCurrent(item.id, generation)) _publish(startedState);
        return;
      }
      if (_lifecycleSuspended) {
        await _ensureLifecyclePaused(session);
        _savePosition(session);
        if (_matches(session, item.id, generation)) _publish(session.state);
        return;
      }
      if (_lifecycleRevision != activationLifecycleRevision) {
        _publish(session.state);
        return;
      }
      await _runMuted(session, session.play);
      await _finishPlayOperation(
        session: session,
        itemId: item.id,
        generation: generation,
        lifecycleRevision: activationLifecycleRevision,
      );
    } catch (_) {
      final failedState = session?.state;
      if (session != null) await _retireSession(session);
      if (_isCurrent(item.id, generation)) {
        _publish(_failedState(item.id, failedState));
      }
    }
  }

  Future<void> _finishPlayOperation({
    required InlinePlaybackSession session,
    required String itemId,
    required int generation,
    required int lifecycleRevision,
  }) async {
    if (!_matches(session, itemId, generation)) {
      await _retireSession(session);
      return;
    }
    if (_lifecycleRevision != lifecycleRevision) {
      if (_lifecycleSuspended) {
        await _ensureLifecyclePaused(session);
      } else {
        await _pauseSafely(session);
      }
      _savePosition(session);
      if (_matches(session, itemId, generation)) _publish(session.state);
      return;
    }
    if (_lifecycleSuspended) {
      await _ensureLifecyclePaused(session);
      _savePosition(session);
    }
    if (_matches(session, itemId, generation)) _publish(session.state);
  }

  Future<void> _reconcileLifecyclePause(int revision) async {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null ||
        itemId == null ||
        !_matches(session, itemId, generation)) {
      return;
    }
    await _ensureLifecyclePaused(session);
    _savePosition(session);
    if (revision == _lifecycleRevision &&
        _lifecycleSuspended &&
        _matches(session, itemId, generation)) {
      _publish(session.state);
    }
  }

  Future<void> _reconcileLifecycleResume({
    required int revision,
    required bool shouldResume,
    required InlinePlaybackSession? resumeSession,
    required String? resumeItemId,
    required int? resumeGeneration,
  }) async {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null ||
        itemId == null ||
        !_matches(session, itemId, generation)) {
      return;
    }
    final lifecycleResumed = await _ensureLifecycleResumed(session);
    if (!lifecycleResumed) return;
    if (revision != _lifecycleRevision ||
        _lifecycleSuspended ||
        !_matches(session, itemId, generation)) {
      return;
    }
    final resumeMatches =
        shouldResume &&
        identical(session, resumeSession) &&
        itemId == resumeItemId &&
        generation == resumeGeneration;
    if (!resumeMatches) {
      _publish(session.state);
      return;
    }
    try {
      await _runMuted(session, session.play);
      await _finishPlayOperation(
        session: session,
        itemId: itemId,
        generation: generation,
        lifecycleRevision: revision,
      );
    } catch (_) {
      await _failSession(session, itemId, generation);
    }
  }

  Future<void> _failSession(
    InlinePlaybackSession session,
    String itemId,
    int generation,
  ) async {
    final failedState = session.state;
    await _retireSession(session);
    if (_isCurrent(itemId, generation)) {
      _publish(_failedState(itemId, failedState));
    }
  }

  InlinePlaybackState _failedState(
    String itemId,
    InlinePlaybackState? failedState,
  ) {
    if (failedState?.hasError ?? false) return failedState!;
    return InlinePlaybackState(
      itemId: itemId,
      phase: InlinePlaybackPhase.failed,
      position: failedState?.position ?? Duration.zero,
      duration: failedState?.duration ?? Duration.zero,
      errorMessage: failedState?.errorMessage ?? '视频加载失败，请重试',
    );
  }

  Future<void> _retireSession(InlinePlaybackSession session) {
    final existing = _retirements[session];
    if (existing != null) return existing;
    late final Future<void> retirement;
    retirement = _retireSessionOnce(session).whenComplete(() {
      if (identical(_retirements[session], retirement)) {
        _retirements.remove(session);
      }
    });
    _retirements[session] = retirement;
    return retirement;
  }

  Future<void> _retireSessionOnce(InlinePlaybackSession session) async {
    await _pauseSafely(session);
    _savePosition(session);
    if (identical(_session, session)) {
      final listener = _sessionListener;
      if (listener != null) session.removeListener(listener);
      _sessionListener = null;
    }
    try {
      await session.shutdown();
    } catch (_) {
      // A failed teardown must not prevent the next serialized session.
    } finally {
      _mutedSessionNotifications.remove(session);
      if (identical(_session, session)) {
        _session = null;
        _sessionLifecycleSuspended = false;
      }
    }
  }

  Future<void> _pauseSafely(InlinePlaybackSession session) async {
    try {
      await _runMuted(session, session.pause);
    } catch (_) {
      // Shutdown remains mandatory even if a backend pause fails.
    }
  }

  Future<void> _ensureLifecyclePaused(InlinePlaybackSession session) async {
    if (!identical(_session, session) || _sessionLifecycleSuspended) return;
    _sessionLifecycleSuspended = true;
    try {
      await _runMuted(session, session.pauseForLifecycle);
    } catch (_) {
      // The controller records suspension before pausing its backend.
    }
  }

  Future<bool> _ensureLifecycleResumed(InlinePlaybackSession session) async {
    if (!identical(_session, session)) return false;
    if (!_sessionLifecycleSuspended) return true;
    try {
      await _runMuted(session, session.resumeForLifecycle);
      if (!identical(_session, session)) return false;
      _sessionLifecycleSuspended = false;
      return true;
    } catch (_) {
      // Keep the session marked suspended when reconciliation fails.
      return false;
    }
  }

  Future<void> _runMuted(
    InlinePlaybackSession session,
    Future<void> Function() operation,
  ) async {
    _mutedSessionNotifications.add(session);
    try {
      await operation();
    } finally {
      _mutedSessionNotifications.remove(session);
    }
  }

  void _savePosition(InlinePlaybackSession session) {
    if (!session.state.isReady) return;
    _resumePositions[session.itemId] = session.state.position;
  }

  bool _isCurrent(String itemId, int generation) =>
      !_shuttingDown &&
      !_disposed &&
      _generation == generation &&
      _targetItem?.id == itemId;

  bool _matches(InlinePlaybackSession session, String itemId, int generation) =>
      identical(_session, session) && _isCurrent(itemId, generation);

  Future<void> _enqueue(Future<void> Function() operation) {
    final completer = Completer<void>();
    _operations.add(
      _QueuedInlineOperation(operation: operation, completer: completer),
    );
    _drainOperations();
    return completer.future;
  }

  void _drainOperations() {
    if (_operationRunning || _operations.isEmpty) return;
    _operationRunning = true;
    final queued = _operations.removeFirst();
    late final Future<void> operation;
    try {
      operation = queued.operation();
    } catch (error, stackTrace) {
      queued.completer.completeError(error, stackTrace);
      _operationRunning = false;
      _drainOperations();
      return;
    }
    operation
        .then<void>(
          (_) => queued.completer.complete(),
          onError: (Object error, StackTrace stackTrace) =>
              queued.completer.completeError(error, stackTrace),
        )
        .whenComplete(() {
          _operationRunning = false;
          _drainOperations();
        });
  }

  void _publish(InlinePlaybackState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  void _clearLifecycleResumeIdentity() {
    _resumeAfterLifecycle = false;
    _lifecycleSession = null;
    _lifecycleItemId = null;
    _lifecycleGeneration = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    final shutdownOperation = shutdown();
    _disposed = true;
    unawaited(shutdownOperation);
    super.dispose();
  }
}

class _QueuedInlineOperation {
  const _QueuedInlineOperation({
    required this.operation,
    required this.completer,
  });

  final Future<void> Function() operation;
  final Completer<void> completer;
}
