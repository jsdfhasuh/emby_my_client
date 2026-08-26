import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/emby_models.dart';
import 'inline_playback_session.dart';

typedef InlinePlaybackSessionFactory =
    Future<InlinePlaybackSession> Function(EmbyItem item);

class InlinePlaybackCoordinator extends ChangeNotifier {
  InlinePlaybackCoordinator({required InlinePlaybackSessionFactory factory})
    : _factory = factory;

  final InlinePlaybackSessionFactory _factory;
  final Map<String, Duration> _resumePositions = {};
  final Map<InlinePlaybackSession, Future<void>> _retirements = {};
  InlinePlaybackState _state = const InlinePlaybackState();
  InlinePlaybackSession? _session;
  VoidCallback? _sessionListener;
  EmbyItem? _targetItem;
  Future<void> _tail = Future<void>.value();
  Future<void>? _targetOperation;
  Future<void>? _shutdownOperation;
  int _generation = 0;
  bool _shuttingDown = false;
  bool _disposed = false;
  bool _lifecycleSuspended = false;
  bool _resumeAfterLifecycle = false;
  InlinePlaybackSession? _lifecycleSession;
  String? _lifecycleItemId;
  int? _lifecycleGeneration;

  InlinePlaybackState get state => _state;
  Map<String, Duration> get resumePositions =>
      Map<String, Duration>.unmodifiable(_resumePositions);

  Future<void> activate(EmbyItem item) {
    if (_shuttingDown || _disposed) return Future<void>.value();
    if (_targetItem?.id == item.id) {
      return _targetOperation ?? Future<void>.value();
    }

    final generation = ++_generation;
    _targetItem = item;
    _clearLifecycleIntent();
    final retirement = _session == null ? null : _retireSession(_session!);
    _publish(
      InlinePlaybackState(
        itemId: item.id,
        phase: InlinePlaybackPhase.loading,
        isBuffering: true,
      ),
    );

    late final Future<void> operation;
    operation = _enqueue(() async {
      if (retirement != null) await retirement;
      if (!_isCurrent(item.id, generation)) return;
      await _activateCurrent(item, generation);
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
    _clearLifecycleIntent();
    final retirement = _session == null ? null : _retireSession(_session!);
    _publish(const InlinePlaybackState());
    return _enqueue(() async {
      if (retirement != null) await retirement;
    });
  }

  Future<void> retry() {
    final item = _targetItem;
    if (item == null || _shuttingDown || _disposed) {
      return Future<void>.value();
    }
    ++_generation;
    _targetItem = null;
    return activate(item);
  }

  Future<void> play() async {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null || itemId == null) return;

    if (session.state.isCompleted) {
      await session.seek(Duration.zero);
      if (!_matches(session, itemId, generation)) return;
    }
    await session.play();
    if (_matches(session, itemId, generation)) {
      _publish(session.state);
    } else {
      await _retireSession(session);
    }
  }

  Future<void> pause() async {
    _clearLifecycleIntent();
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null || itemId == null) return;
    await _pauseSafely(session);
    _savePosition(session);
    if (_matches(session, itemId, generation)) _publish(session.state);
  }

  Future<void> seek(Duration position) async {
    final session = _session;
    final itemId = _targetItem?.id;
    final generation = _generation;
    if (session == null || itemId == null) return;
    await session.seek(position);
    if (_matches(session, itemId, generation)) _publish(session.state);
  }

  Future<void> handleAppLifecycleState(AppLifecycleState lifecycleState) async {
    switch (lifecycleState) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_lifecycleSuspended) return;
        _lifecycleSuspended = true;
        final session = _session;
        final itemId = _targetItem?.id;
        if (session == null || itemId == null) {
          _clearLifecycleResumeIdentity();
          return;
        }
        _resumeAfterLifecycle = session.state.isPlaying;
        _lifecycleSession = session;
        _lifecycleItemId = itemId;
        _lifecycleGeneration = _generation;
        await _pauseSafely(session);
        _savePosition(session);
        if (_matches(session, itemId, _generation)) _publish(session.state);
      case AppLifecycleState.resumed:
        if (!_lifecycleSuspended) return;
        _lifecycleSuspended = false;
        final shouldResume = _resumeAfterLifecycle;
        final session = _lifecycleSession;
        final itemId = _lifecycleItemId;
        final generation = _lifecycleGeneration;
        _clearLifecycleResumeIdentity();
        if (!shouldResume ||
            session == null ||
            itemId == null ||
            generation == null ||
            !_matches(session, itemId, generation)) {
          return;
        }
        await session.play();
        if (_matches(session, itemId, generation)) _publish(session.state);
    }
  }

  Future<void> handleMemoryPressure() async {
    final session = _session;
    if (session != null) await session.handleMemoryPressure();
  }

  Future<void> shutdown() {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    _shuttingDown = true;
    ++_generation;
    _targetItem = null;
    _targetOperation = null;
    _clearLifecycleIntent();
    final retirement = _session == null ? null : _retireSession(_session!);
    _publish(const InlinePlaybackState());
    return _shutdownOperation = _enqueue(() async {
      if (retirement != null) await retirement;
      final lateSession = _session;
      if (lateSession != null) await _retireSession(lateSession);
    });
  }

  Future<void> _activateCurrent(EmbyItem item, int generation) async {
    InlinePlaybackSession? session;
    try {
      session = await _factory(item);
      if (!_isCurrent(item.id, generation)) {
        await _retireSession(session);
        return;
      }

      _session = session;
      void listener() {
        if (_matches(session!, item.id, generation) &&
            !_retirements.containsKey(session)) {
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
      await session.play();
      if (!_matches(session, item.id, generation)) {
        await _retireSession(session);
        return;
      }
      _publish(session.state);
    } catch (error) {
      final failedState = session?.state;
      if (session != null) await _retireSession(session);
      if (_isCurrent(item.id, generation)) {
        _publish(
          InlinePlaybackState(
            itemId: item.id,
            phase: InlinePlaybackPhase.failed,
            position: failedState?.position ?? Duration.zero,
            duration: failedState?.duration ?? Duration.zero,
            errorMessage: failedState?.errorMessage ?? '视频加载失败，请重试',
          ),
        );
      }
    }
  }

  Future<void> _retireSession(InlinePlaybackSession session) =>
      _retirements.putIfAbsent(session, () => _retireSessionOnce(session));

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
      if (identical(_session, session)) _session = null;
    }
  }

  Future<void> _pauseSafely(InlinePlaybackSession session) async {
    try {
      await session.pause();
    } catch (_) {
      // Shutdown remains mandatory even if a backend pause fails.
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
    final next = _tail.then((_) => operation());
    _tail = next.catchError((Object _) {});
    return next;
  }

  void _publish(InlinePlaybackState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  void _clearLifecycleIntent() {
    _lifecycleSuspended = false;
    _clearLifecycleResumeIdentity();
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
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
