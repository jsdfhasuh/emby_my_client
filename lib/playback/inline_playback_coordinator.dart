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
  final Map<InlinePlaybackSession, Future<void>> _quiescences = {};
  final Set<InlinePlaybackSession> _retiringSessions = {};
  final Set<InlinePlaybackSession> _lifecycleQuiescedSessions = {};
  final Set<InlinePlaybackSession> _lifecycleResumingSessions = {};
  final Map<InlinePlaybackSession, int> _mutedSessionNotifications = {};
  InlinePlaybackState _state = const InlinePlaybackState();
  InlinePlaybackSession? _session;
  VoidCallback? _sessionListener;
  EmbyItem? _targetItem;
  final Queue<_QueuedInlineOperation> _operations = Queue();
  _QueuedInlineOperation? _activeOperation;
  bool _operationRunning = false;
  Future<void>? _targetOperation;
  Future<void>? _shutdownOperation;
  int _generation = 0;
  int _lifecycleRevision = 0;
  bool _shuttingDown = false;
  bool _detachedAndQuarantined = false;
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
  int get inFlightQuiescenceCount => _quiescences.length;

  @visibleForTesting
  bool get lifecycleSuspended => _lifecycleSuspended;

  @visibleForTesting
  bool get detachedAndQuarantined => _detachedAndQuarantined;

  Future<void> activate(EmbyItem item) {
    if (_shuttingDown || _disposed) return Future<void>.value();
    if (_targetItem?.id == item.id) {
      return _targetOperation ?? Future<void>.value();
    }

    final previousSession = _session;
    final previousQuiescence = previousSession == null
        ? null
        : _beginRetirementQuiescence(previousSession);
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
      if (previousSession != null) {
        await _retireSession(previousSession, quiescence: previousQuiescence);
      }
      if (!_isCurrent(item.id, generation)) return;
      await _activateCurrent(item, generation, lifecycleRevision);
    });
    _targetOperation = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_targetOperation, operation)) _targetOperation = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_targetOperation, operation)) _targetOperation = null;
        },
      ),
    );
    return operation;
  }

  Future<void> deactivate() {
    if (_shuttingDown || _disposed) return Future<void>.value();
    final session = _session;
    final quiescence = session == null
        ? null
        : _beginRetirementQuiescence(session);
    ++_generation;
    _targetItem = null;
    _targetOperation = null;
    _clearLifecycleResumeIdentity();
    _publish(const InlinePlaybackState());
    return _enqueue(() async {
      if (session != null) {
        await _retireSession(session, quiescence: quiescence);
      }
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
    if (session == null ||
        itemId == null ||
        _retiringSessions.contains(session)) {
      return Future<void>.value();
    }
    return _enqueue(() async {
      if (!_matches(session, itemId, generation) ||
          _retiringSessions.contains(session) ||
          _lifecycleSuspended ||
          session.state.hasError) {
        return;
      }
      if (_sessionLifecycleSuspended ||
          _lifecycleQuiescedSessions.contains(session)) {
        final lifecycleResumed = await _ensureLifecycleResumed(session);
        if (!lifecycleResumed ||
            !_matches(session, itemId, generation) ||
            _retiringSessions.contains(session) ||
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
    if (session == null ||
        itemId == null ||
        _retiringSessions.contains(session)) {
      return Future<void>.value();
    }
    return _enqueue(() async {
      if (!_matches(session, itemId, generation) ||
          _retiringSessions.contains(session)) {
        return;
      }
      await _pauseSafely(session);
      _savePosition(session);
      if (_matches(session, itemId, generation)) _publish(session.state);
    });
  }

  Future<void> seek(Duration position) {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null ||
        itemId == null ||
        _retiringSessions.contains(session) ||
        _lifecycleQuiescedSessions.contains(session)) {
      return Future<void>.value();
    }
    return _enqueue(() async {
      if (!_matches(session, itemId, generation) ||
          _retiringSessions.contains(session) ||
          _lifecycleQuiescedSessions.contains(session)) {
        return;
      }
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
      if (session != null && itemId != null) {
        _beginLifecycleQuiescence(
          session,
          force: _lifecycleResumingSessions.contains(session),
        );
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
    if (session == null ||
        itemId == null ||
        _retiringSessions.contains(session)) {
      return Future<void>.value();
    }
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
    final session = _session;
    final quiescence = session == null
        ? null
        : _beginRetirementQuiescence(session);
    _shuttingDown = true;
    ++_generation;
    _targetItem = null;
    _targetOperation = null;
    _clearLifecycleResumeIdentity();
    _publish(const InlinePlaybackState());
    return _shutdownOperation = _enqueue(() async {
      if (session != null) {
        await _retireSession(session, quiescence: quiescence);
      }
    });
  }

  void detachAndQuarantine() {
    if (_detachedAndQuarantined) return;
    _detachedAndQuarantined = true;
    _shuttingDown = true;
    ++_generation;
    _targetItem = null;
    _targetOperation = null;
    _clearLifecycleResumeIdentity();

    final session = _session;
    if (session != null) {
      _savePosition(session);
      final listener = _sessionListener;
      if (listener != null) session.removeListener(listener);
    }
    _sessionListener = null;
    _session = null;
    _sessionLifecycleSuspended = false;
    _lifecycleQuiescedSessions.clear();
    _lifecycleResumingSessions.clear();
    _retiringSessions.clear();
    _mutedSessionNotifications.clear();
    _quiescences.clear();
    _retirements.clear();

    final activeOperation = _activeOperation;
    if (activeOperation != null && !activeOperation.completer.isCompleted) {
      activeOperation.completer.complete();
    }
    while (_operations.isNotEmpty) {
      final queued = _operations.removeFirst();
      if (!queued.completer.isCompleted) queued.completer.complete();
    }
    _shutdownOperation ??= Future<void>.value();
    if (_state.phase != InlinePlaybackPhase.inactive || _state.itemId != null) {
      _publish(const InlinePlaybackState());
    }
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
        final quiescence = _beginRetirementQuiescence(session);
        await _retireSession(session, quiescence: quiescence);
        return;
      }

      _session = session;
      _sessionLifecycleSuspended = false;
      void listener() {
        if (_matches(session!, item.id, generation) &&
            !_retirements.containsKey(session) &&
            !_retiringSessions.contains(session) &&
            !_lifecycleQuiescedSessions.contains(session) &&
            !_mutedSessionNotifications.containsKey(session)) {
          _publish(session.state);
        }
      }

      _sessionListener = listener;
      session.addListener(listener);
      if (_lifecycleSuspended) {
        _beginLifecycleQuiescence(session);
      }
      await session.start(resumePosition: _resumePositions[item.id]);
      if (!_matches(session, item.id, generation)) {
        final quiescence = _beginRetirementQuiescence(session);
        await _retireSession(session, quiescence: quiescence);
        return;
      }
      final startedState = session.state;
      if (startedState.hasError) {
        final quiescence = _beginRetirementQuiescence(session);
        await _retireSession(session, quiescence: quiescence);
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
      if (session != null) {
        final quiescence = _beginRetirementQuiescence(session);
        await _retireSession(session, quiescence: quiescence);
      }
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
      final quiescence = _beginRetirementQuiescence(session);
      await _retireSession(session, quiescence: quiescence);
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
    final quiescence = _beginRetirementQuiescence(session);
    await _retireSession(session, quiescence: quiescence);
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

  Future<void> _retireSession(
    InlinePlaybackSession session, {
    Future<void>? quiescence,
  }) {
    final existing = _retirements[session];
    if (existing != null) return existing;
    final urgentQuiescence = quiescence ?? _beginRetirementQuiescence(session);
    late final Future<void> retirement;
    retirement = (() async {
      try {
        await _retireSessionOnce(session, urgentQuiescence);
      } finally {
        if (identical(_retirements[session], retirement)) {
          _retirements.remove(session);
        }
      }
    })();
    _retirements[session] = retirement;
    unawaited(
      retirement.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return retirement;
  }

  Future<void> _retireSessionOnce(
    InlinePlaybackSession session,
    Future<void> quiescence,
  ) async {
    await _awaitQuiescenceSafely(quiescence);
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
      _retiringSessions.remove(session);
      _lifecycleQuiescedSessions.remove(session);
      _lifecycleResumingSessions.remove(session);
      _quiescences.remove(session);
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
    if (!identical(_session, session) || _retiringSessions.contains(session)) {
      return;
    }
    _sessionLifecycleSuspended = true;
    final quiescence = _beginLifecycleQuiescence(
      session,
      force: _lifecycleResumingSessions.contains(session),
    );
    await _awaitQuiescenceSafely(quiescence);
  }

  Future<bool> _ensureLifecycleResumed(InlinePlaybackSession session) async {
    if (!identical(_session, session) || _retiringSessions.contains(session)) {
      return false;
    }
    if (!_sessionLifecycleSuspended &&
        !_lifecycleQuiescedSessions.contains(session)) {
      return true;
    }
    final revision = _lifecycleRevision;
    final quiescence = _quiescences[session];
    if (quiescence != null) await _awaitQuiescenceSafely(quiescence);
    if (!identical(_session, session) ||
        _retiringSessions.contains(session) ||
        _lifecycleSuspended ||
        revision != _lifecycleRevision) {
      return false;
    }
    _lifecycleResumingSessions.add(session);
    try {
      await _runMuted(session, session.resumeForLifecycle);
      if (!identical(_session, session) ||
          _retiringSessions.contains(session)) {
        return false;
      }
      if (_lifecycleSuspended || revision != _lifecycleRevision) {
        final requiescence = _beginLifecycleQuiescence(session, force: true);
        await _awaitQuiescenceSafely(requiescence);
        return false;
      }
      _lifecycleQuiescedSessions.remove(session);
      _sessionLifecycleSuspended = false;
      return true;
    } catch (_) {
      // Keep the session marked suspended when reconciliation fails.
      return false;
    } finally {
      _lifecycleResumingSessions.remove(session);
    }
  }

  Future<void> _beginRetirementQuiescence(InlinePlaybackSession session) {
    final firstRetirementIntent = _retiringSessions.add(session);
    final existing = _quiescences[session];
    if (existing != null) return existing;
    if (!firstRetirementIntent) return Future<void>.value();
    return _trackQuiescence(session, session.quiesce);
  }

  Future<void> _beginLifecycleQuiescence(
    InlinePlaybackSession session, {
    bool force = false,
  }) {
    if (_retiringSessions.contains(session)) {
      return _quiescences[session] ?? Future<void>.value();
    }
    final firstLifecycleIntent = _lifecycleQuiescedSessions.add(session);
    if (identical(_session, session)) _sessionLifecycleSuspended = true;
    final existing = _quiescences[session];
    if (existing != null) return existing;
    if (!firstLifecycleIntent && !force) return Future<void>.value();
    return _trackQuiescence(session, session.quiesceForLifecycle);
  }

  Future<void> _trackQuiescence(
    InlinePlaybackSession session,
    Future<void> Function() operation,
  ) {
    final source = Future<void>.sync(() => _runMuted(session, operation));
    late final Future<void> tracked;
    tracked = (() async {
      try {
        await source;
      } finally {
        if (identical(_quiescences[session], tracked)) {
          _quiescences.remove(session);
        }
      }
    })();
    _quiescences[session] = tracked;
    unawaited(tracked.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return tracked;
  }

  Future<void> _awaitQuiescenceSafely(Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      // Final shutdown must proceed even when urgent output pause fails.
    }
  }

  Future<void> _runMuted(
    InlinePlaybackSession session,
    Future<void> Function() operation,
  ) async {
    _mutedSessionNotifications.update(
      session,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    try {
      await operation();
    } finally {
      final remaining = (_mutedSessionNotifications[session] ?? 1) - 1;
      if (remaining <= 0) {
        _mutedSessionNotifications.remove(session);
      } else {
        _mutedSessionNotifications[session] = remaining;
      }
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
    _activeOperation = queued;
    late final Future<void> operation;
    try {
      operation = queued.operation();
    } catch (error, stackTrace) {
      if (!queued.completer.isCompleted) {
        queued.completer.completeError(error, stackTrace);
      }
      if (identical(_activeOperation, queued)) _activeOperation = null;
      _operationRunning = false;
      _drainOperations();
      return;
    }
    unawaited(
      operation.then<void>(
        (_) {
          if (!queued.completer.isCompleted) queued.completer.complete();
          if (identical(_activeOperation, queued)) _activeOperation = null;
          _operationRunning = false;
          _drainOperations();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!queued.completer.isCompleted) {
            queued.completer.completeError(error, stackTrace);
          }
          if (identical(_activeOperation, queued)) _activeOperation = null;
          _operationRunning = false;
          _drainOperations();
        },
      ),
    );
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
