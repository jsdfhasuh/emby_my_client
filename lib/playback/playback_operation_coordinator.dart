import 'dart:async';
import 'dart:math';

enum SeekDisposition { executed, superseded, cancelled, failed }

enum SeekFailureKind {
  engineError,
  callTimeout,
  settleTimeout,
  higherPriorityOperation,
  staleSession,
}

enum SeekSource {
  resume,
  horizontalDrag,
  doubleTap,
  progressBar,
  chapter,
  skipIntro,
  remote,
  controls,
  recovery,
}

class SeekResult {
  const SeekResult({
    required this.disposition,
    required this.requestedTarget,
    required this.settled,
    this.committedPosition,
    this.failureKind,
  });

  final SeekDisposition disposition;
  final Duration requestedTarget;
  final bool settled;
  final Duration? committedPosition;
  final SeekFailureKind? failureKind;
}

class PlaybackItemSessionId {
  const PlaybackItemSessionId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PlaybackItemSessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

enum AutomaticPlaybackOpenReason {
  initial,
  cacheCreateMemoryRetry,
  startupTranscodeFallback,
  cacheSafetyReopen,
  runtimeSameMethodRecovery,
  runtimeTranscodeRecovery,
}

enum PlaybackControlOperationPriority {
  userReconfigure,
  cacheSafety,
  runtimeRecovery,
}

class PlaybackControlOperationLease {
  PlaybackControlOperationLease._({
    required bool Function() isCurrent,
    required this.cancelled,
  }) : _isCurrent = isCurrent;

  final bool Function() _isCurrent;
  final Future<void> cancelled;

  bool get isCurrent => _isCurrent();
}

typedef PlaybackControlOperation =
    Future<void> Function(PlaybackControlOperationLease lease);

class PlaybackItemSession {
  PlaybackItemSession._(this.id);

  factory PlaybackItemSession.create({Random? random}) {
    final source = random ?? Random.secure();
    final value = List<int>.generate(
      4,
      (_) => source.nextInt(0x100000000),
      growable: false,
    ).map((part) => part.toRadixString(16).padLeft(8, '0')).join();
    return PlaybackItemSession._(PlaybackItemSessionId(value));
  }

  factory PlaybackItemSession.forTest(String value) =>
      PlaybackItemSession._(PlaybackItemSessionId(value));

  static const int maximumAutomaticOpenCount = 6;

  final PlaybackItemSessionId id;
  final Set<AutomaticPlaybackOpenReason> _automaticOpenReasons = {};

  int get automaticOpenCount => _automaticOpenReasons.length;

  bool hasUsed(AutomaticPlaybackOpenReason reason) =>
      _automaticOpenReasons.contains(reason);

  bool tryReserveAutomaticOpen(AutomaticPlaybackOpenReason reason) {
    if (_automaticOpenReasons.contains(reason) ||
        automaticOpenCount >= maximumAutomaticOpenCount) {
      return false;
    }
    _automaticOpenReasons.add(reason);
    return true;
  }
}

typedef PlaybackEngineSeek = Future<void> Function(Duration target);
typedef PlaybackTargetClamp = Duration Function(Duration target);
typedef RequestedPositionListener = void Function(Duration? position);
typedef PlaybackSessionCurrent = bool Function(PlaybackItemSessionId sessionId);

class PlaybackOperationCoordinator {
  PlaybackOperationCoordinator({
    required this.sessionId,
    required PlaybackEngineSeek seekEngine,
    required PlaybackTargetClamp clampTarget,
    RequestedPositionListener? onRequestedPositionChanged,
    void Function()? onControlOperationInvalidated,
    PlaybackSessionCurrent? isSessionCurrent,
    this.seekCallTimeout = const Duration(seconds: 8),
    this.seekSettleTimeout = const Duration(seconds: 2),
    this.seekTolerance = const Duration(seconds: 2),
  }) : _seekEngine = seekEngine,
       _clampTarget = clampTarget,
       _onRequestedPositionChanged = onRequestedPositionChanged,
       _onControlOperationInvalidated = onControlOperationInvalidated,
       _isSessionCurrent = isSessionCurrent;

  final PlaybackItemSessionId sessionId;
  PlaybackEngineSeek _seekEngine;
  final PlaybackTargetClamp _clampTarget;
  final RequestedPositionListener? _onRequestedPositionChanged;
  final void Function()? _onControlOperationInvalidated;
  final PlaybackSessionCurrent? _isSessionCurrent;
  final Duration seekCallTimeout;
  final Duration seekSettleTimeout;
  final Duration seekTolerance;

  Duration _committedPosition = Duration.zero;
  Duration? _requestedPosition;
  _SeekRequest? _inFlight;
  _SeekRequest? _pending;
  _SettleWaiter? _settleWaiter;
  bool _draining = false;
  bool _nativeSeekOutstanding = false;
  bool _shutdown = false;
  int _operationGeneration = 0;
  int _engineGeneration = 0;
  final List<_ControlOperationRequest> _controlPending = [];
  _ControlOperationRequest? _controlActive;
  bool _controlDraining = false;
  int _controlSequence = 0;

  Duration get committedPosition => _committedPosition;
  Duration? get requestedPosition => _requestedPosition;
  int get operationGeneration => _operationGeneration;
  bool get isShutdown => _shutdown;

  Future<void> runControlOperation({
    required PlaybackControlOperationPriority priority,
    required PlaybackControlOperation operation,
  }) {
    if (_shutdown) return Future<void>.value();
    invalidateForHigherPriorityOperation();

    var invalidatedLowerPriorityOperation = false;
    final active = _controlActive;
    if (active != null && active.priority.index < priority.index) {
      invalidatedLowerPriorityOperation |= _cancelControlOperation(active);
    }
    for (final pending in List<_ControlOperationRequest>.of(_controlPending)) {
      if (pending.priority.index < priority.index) {
        invalidatedLowerPriorityOperation |= _cancelControlOperation(pending);
        _controlPending.remove(pending);
      }
    }
    if (invalidatedLowerPriorityOperation) {
      _onControlOperationInvalidated?.call();
    }

    final request = _ControlOperationRequest(
      priority: priority,
      sequence: _controlSequence++,
      operation: operation,
    );
    _controlPending.add(request);
    _controlPending.sort((left, right) {
      final priorityOrder = right.priority.index.compareTo(left.priority.index);
      return priorityOrder != 0
          ? priorityOrder
          : left.sequence.compareTo(right.sequence);
    });
    unawaited(_drainControlOperations());
    return request.result.future;
  }

  void replaceSeekEngine(PlaybackEngineSeek seekEngine) {
    invalidateForHigherPriorityOperation();
    _engineGeneration++;
    _seekEngine = seekEngine;
  }

  Future<SeekResult> seekAbsolute(
    Duration target, {
    required SeekSource source,
  }) => _enqueue(_clampTarget(target), source);

  Future<SeekResult> seekRelative(
    Duration delta, {
    required SeekSource source,
  }) {
    final base = _requestedPosition ?? _committedPosition;
    return _enqueue(_clampTarget(base + delta), source);
  }

  void updateCommittedPosition(Duration position) {
    if (_shutdown) return;
    _committedPosition = _clampTarget(position);
    final waiter = _settleWaiter;
    if (waiter == null || waiter.generation != _operationGeneration) return;
    if (_difference(_committedPosition, waiter.target) <= seekTolerance &&
        !waiter.completer.isCompleted) {
      waiter.completer.complete();
    }
  }

  void invalidateForHigherPriorityOperation() {
    if (_shutdown) return;
    _operationGeneration++;
    _completePending(
      disposition: SeekDisposition.cancelled,
      failureKind: SeekFailureKind.higherPriorityOperation,
    );
    _completeInFlight(
      disposition: SeekDisposition.cancelled,
      failureKind: SeekFailureKind.higherPriorityOperation,
    );
    _completeSettleWaiter();
    _refreshRequestedPosition();
  }

  void shutdown() {
    if (_shutdown) return;
    _shutdown = true;
    _operationGeneration++;
    _completePending(
      disposition: SeekDisposition.cancelled,
      failureKind: SeekFailureKind.staleSession,
    );
    _completeInFlight(
      disposition: SeekDisposition.cancelled,
      failureKind: SeekFailureKind.staleSession,
    );
    _completeSettleWaiter();
    _refreshRequestedPosition();
    final active = _controlActive;
    if (active != null) _cancelControlOperation(active);
    for (final pending in List<_ControlOperationRequest>.of(_controlPending)) {
      _cancelControlOperation(pending);
    }
    _controlPending.clear();
  }

  Future<void> _drainControlOperations() async {
    if (_controlDraining || _shutdown) return;
    _controlDraining = true;
    try {
      while (!_shutdown && _controlPending.isNotEmpty) {
        final request = _controlPending.removeAt(0);
        if (request.isCancelled) continue;
        _controlActive = request;
        final lease = PlaybackControlOperationLease._(
          isCurrent: () =>
              !_shutdown &&
              !request.isCancelled &&
              identical(_controlActive, request),
          cancelled: request.cancelled.future,
        );
        try {
          await request.operation(lease);
          if (!request.result.isCompleted) request.result.complete();
        } catch (error, stackTrace) {
          if (!request.result.isCompleted) {
            request.result.completeError(error, stackTrace);
          }
        } finally {
          if (identical(_controlActive, request)) _controlActive = null;
        }
      }
    } finally {
      _controlDraining = false;
      if (!_shutdown && _controlPending.isNotEmpty) {
        unawaited(_drainControlOperations());
      }
    }
  }

  bool _cancelControlOperation(_ControlOperationRequest request) {
    if (request.isCancelled) return false;
    request.isCancelled = true;
    if (!request.cancelled.isCompleted) request.cancelled.complete();
    if (!request.result.isCompleted) request.result.complete();
    return true;
  }

  Future<SeekResult> _enqueue(Duration target, SeekSource source) {
    if (_shutdown) {
      return Future.value(
        SeekResult(
          disposition: SeekDisposition.cancelled,
          requestedTarget: target,
          settled: false,
          committedPosition: _committedPosition,
          failureKind: SeekFailureKind.staleSession,
        ),
      );
    }
    if (_nativeSeekOutstanding) {
      return Future.value(
        SeekResult(
          disposition: SeekDisposition.failed,
          requestedTarget: target,
          settled: false,
          committedPosition: _committedPosition,
          failureKind: SeekFailureKind.higherPriorityOperation,
        ),
      );
    }

    final request = _SeekRequest(
      target: target,
      source: source,
      generation: _operationGeneration,
      engineGeneration: _engineGeneration,
      sessionId: sessionId,
    );
    final previous = _pending;
    if (previous != null) {
      _complete(
        previous,
        disposition: SeekDisposition.superseded,
        settled: false,
      );
    }
    _pending = request;
    _refreshRequestedPosition();
    unawaited(_drain());
    return request.completer.future;
  }

  Future<void> _drain() async {
    if (_draining || _shutdown || _nativeSeekOutstanding) return;
    _draining = true;
    try {
      while (!_shutdown && !_nativeSeekOutstanding) {
        final request = _pending;
        if (request == null) break;
        _pending = null;
        _inFlight = request;
        _refreshRequestedPosition();
        await _execute(request);
        if (identical(_inFlight, request)) _inFlight = null;
        _refreshRequestedPosition();
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _execute(_SeekRequest request) async {
    if (!_isCurrent(request)) {
      _complete(
        request,
        disposition: SeekDisposition.cancelled,
        settled: false,
        failureKind: SeekFailureKind.staleSession,
      );
      return;
    }

    late final Future<void> nativeCall;
    try {
      nativeCall = Future.sync(() => _seekEngine(request.target));
      await nativeCall.timeout(seekCallTimeout);
    } on TimeoutException {
      _nativeSeekOutstanding = true;
      _operationGeneration++;
      _complete(
        request,
        disposition: SeekDisposition.failed,
        settled: false,
        failureKind: SeekFailureKind.callTimeout,
      );
      _completePending(
        disposition: SeekDisposition.failed,
        failureKind: SeekFailureKind.higherPriorityOperation,
      );
      _refreshRequestedPosition();
      unawaited(
        nativeCall.then<void>(
          (_) => _nativeSeekCompleted(),
          onError: (_) => _nativeSeekCompleted(),
        ),
      );
      return;
    } catch (_) {
      _complete(
        request,
        disposition: SeekDisposition.failed,
        settled: false,
        failureKind: SeekFailureKind.engineError,
      );
      return;
    }

    if (!_isCurrent(request)) {
      _complete(
        request,
        disposition: SeekDisposition.cancelled,
        settled: false,
        failureKind: _staleFailureKind(request),
      );
      return;
    }

    if (_difference(_committedPosition, request.target) > seekTolerance) {
      final waiter = _SettleWaiter(
        target: request.target,
        generation: request.generation,
      );
      _settleWaiter = waiter;
      try {
        await waiter.completer.future.timeout(seekSettleTimeout);
      } on TimeoutException {
        if (identical(_settleWaiter, waiter)) _settleWaiter = null;
        _complete(
          request,
          disposition: SeekDisposition.failed,
          settled: false,
          failureKind: SeekFailureKind.settleTimeout,
        );
        return;
      }
      if (identical(_settleWaiter, waiter)) _settleWaiter = null;
    }

    if (!_isCurrent(request)) {
      _complete(
        request,
        disposition: SeekDisposition.cancelled,
        settled: false,
        failureKind: _staleFailureKind(request),
      );
      return;
    }
    _complete(request, disposition: SeekDisposition.executed, settled: true);
  }

  void _nativeSeekCompleted() {
    _nativeSeekOutstanding = false;
    if (!_shutdown) unawaited(_drain());
  }

  bool _isCurrent(_SeekRequest request) =>
      !_shutdown &&
      request.sessionId == sessionId &&
      request.generation == _operationGeneration &&
      request.engineGeneration == _engineGeneration &&
      (_isSessionCurrent?.call(request.sessionId) ?? true);

  SeekFailureKind _staleFailureKind(_SeekRequest request) {
    final sessionIsCurrent = _isSessionCurrent?.call(request.sessionId) ?? true;
    return _shutdown ||
            request.sessionId != sessionId ||
            request.engineGeneration != _engineGeneration ||
            !sessionIsCurrent
        ? SeekFailureKind.staleSession
        : SeekFailureKind.higherPriorityOperation;
  }

  void _completePending({
    required SeekDisposition disposition,
    required SeekFailureKind failureKind,
  }) {
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      _complete(
        pending,
        disposition: disposition,
        settled: false,
        failureKind: failureKind,
      );
    }
  }

  void _completeInFlight({
    required SeekDisposition disposition,
    required SeekFailureKind failureKind,
  }) {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _complete(
        inFlight,
        disposition: disposition,
        settled: false,
        failureKind: failureKind,
      );
    }
  }

  void _completeSettleWaiter() {
    final waiter = _settleWaiter;
    _settleWaiter = null;
    if (waiter != null && !waiter.completer.isCompleted) {
      waiter.completer.complete();
    }
  }

  void _complete(
    _SeekRequest request, {
    required SeekDisposition disposition,
    required bool settled,
    SeekFailureKind? failureKind,
  }) {
    if (request.completer.isCompleted) return;
    request.completer.complete(
      SeekResult(
        disposition: disposition,
        requestedTarget: request.target,
        settled: settled,
        committedPosition: _committedPosition,
        failureKind: failureKind,
      ),
    );
  }

  void _refreshRequestedPosition() {
    final next = _pending?.target ?? _inFlight?.target;
    if (next == _requestedPosition) return;
    _requestedPosition = next;
    _onRequestedPositionChanged?.call(next);
  }

  static Duration _difference(Duration left, Duration right) =>
      Duration(microseconds: (left - right).inMicroseconds.abs());
}

class _SeekRequest {
  _SeekRequest({
    required this.target,
    required this.source,
    required this.generation,
    required this.engineGeneration,
    required this.sessionId,
  });

  final Duration target;
  final SeekSource source;
  final int generation;
  final int engineGeneration;
  final PlaybackItemSessionId sessionId;
  final Completer<SeekResult> completer = Completer<SeekResult>();
}

class _SettleWaiter {
  _SettleWaiter({required this.target, required this.generation});

  final Duration target;
  final int generation;
  final Completer<void> completer = Completer<void>();
}

class _ControlOperationRequest {
  _ControlOperationRequest({
    required this.priority,
    required this.sequence,
    required this.operation,
  });

  final PlaybackControlOperationPriority priority;
  final int sequence;
  final PlaybackControlOperation operation;
  final Completer<void> result = Completer<void>();
  final Completer<void> cancelled = Completer<void>();
  bool isCancelled = false;
}
