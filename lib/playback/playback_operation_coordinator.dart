import 'dart:async';
import 'dart:math';

enum PlaybackNativeOperationKind {
  urgentMute,
  open,
  play,
  pause,
  seek,
  stop,
  propertyWrite,
  lifecycleQuiesce,
  retirementQuiesce,
  dispose,
}

enum PlaybackRetirementState {
  active,
  quiescing,
  retiring,
  quarantined,
  closed,
}

class PlaybackNativeOperationTimeouts {
  const PlaybackNativeOperationTimeouts({
    this.urgentMute = const Duration(milliseconds: 750),
    this.open = const Duration(seconds: 18),
    this.play = const Duration(seconds: 3),
    this.pause = const Duration(seconds: 3),
    this.seek = const Duration(seconds: 8),
    this.stop = const Duration(seconds: 5),
    this.propertyWrite = const Duration(seconds: 2),
    this.lifecycleQuiesce = const Duration(seconds: 2),
    this.retirementQuiesce = const Duration(seconds: 3),
    this.dispose = const Duration(seconds: 5),
    this.shutdownBarrier = const Duration(seconds: 5),
  });

  final Duration urgentMute;
  final Duration open;
  final Duration play;
  final Duration pause;
  final Duration seek;
  final Duration stop;
  final Duration propertyWrite;
  final Duration lifecycleQuiesce;
  final Duration retirementQuiesce;
  final Duration dispose;
  final Duration shutdownBarrier;

  Duration forKind(PlaybackNativeOperationKind kind) => switch (kind) {
    PlaybackNativeOperationKind.urgentMute => urgentMute,
    PlaybackNativeOperationKind.open => open,
    PlaybackNativeOperationKind.play => play,
    PlaybackNativeOperationKind.pause => pause,
    PlaybackNativeOperationKind.seek => seek,
    PlaybackNativeOperationKind.stop => stop,
    PlaybackNativeOperationKind.propertyWrite => propertyWrite,
    PlaybackNativeOperationKind.lifecycleQuiesce => lifecycleQuiesce,
    PlaybackNativeOperationKind.retirementQuiesce => retirementQuiesce,
    PlaybackNativeOperationKind.dispose => dispose,
  };
}

enum PlaybackNativeBarrierDisposition { completed, failed, timedOut }

class PlaybackNativeBarrierResult {
  const PlaybackNativeBarrierResult._(
    this.disposition, {
    this.error,
    this.stackTrace,
  });

  const PlaybackNativeBarrierResult.completed()
    : this._(PlaybackNativeBarrierDisposition.completed);

  const PlaybackNativeBarrierResult.failed(Object error, StackTrace stackTrace)
    : this._(
        PlaybackNativeBarrierDisposition.failed,
        error: error,
        stackTrace: stackTrace,
      );

  const PlaybackNativeBarrierResult.timedOut()
    : this._(PlaybackNativeBarrierDisposition.timedOut);

  final PlaybackNativeBarrierDisposition disposition;
  final Object? error;
  final StackTrace? stackTrace;

  bool get timedOut => disposition == PlaybackNativeBarrierDisposition.timedOut;
}

class PlaybackNativeOperationTimedOut implements Exception {
  const PlaybackNativeOperationTimedOut({
    required this.kind,
    required this.timeout,
  });

  final PlaybackNativeOperationKind kind;
  final Duration timeout;

  @override
  String toString() =>
      'Native playback operation ${kind.name} exceeded $timeout';
}

class PlaybackNativeOperation {
  PlaybackNativeOperation._({
    required this.kind,
    required this.timeout,
    required this.nativeFuture,
    required this.barrierFuture,
    required this.logicalFuture,
  });

  factory PlaybackNativeOperation.start({
    required PlaybackNativeOperationKind kind,
    required Duration timeout,
    required PlaybackEngineOperation operation,
    void Function()? onTimeout,
  }) {
    assert(timeout > Duration.zero);
    final nativeFuture = Future<void>.sync(operation);
    final barrierCompleter = Completer<PlaybackNativeBarrierResult>();
    final timer = Timer(timeout, () {
      if (barrierCompleter.isCompleted) return;
      onTimeout?.call();
      barrierCompleter.complete(const PlaybackNativeBarrierResult.timedOut());
    });
    nativeFuture.then<void>(
      (_) {
        if (barrierCompleter.isCompleted) return;
        timer.cancel();
        barrierCompleter.complete(
          const PlaybackNativeBarrierResult.completed(),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (barrierCompleter.isCompleted) return;
        timer.cancel();
        barrierCompleter.complete(
          PlaybackNativeBarrierResult.failed(error, stackTrace),
        );
      },
    );
    final barrierFuture = barrierCompleter.future;
    final logicalFuture = barrierFuture.then<void>((result) {
      switch (result.disposition) {
        case PlaybackNativeBarrierDisposition.completed:
          return;
        case PlaybackNativeBarrierDisposition.failed:
          Error.throwWithStackTrace(result.error!, result.stackTrace!);
        case PlaybackNativeBarrierDisposition.timedOut:
          throw PlaybackNativeOperationTimedOut(kind: kind, timeout: timeout);
      }
    });
    unawaited(
      logicalFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return PlaybackNativeOperation._(
      kind: kind,
      timeout: timeout,
      nativeFuture: nativeFuture,
      barrierFuture: barrierFuture,
      logicalFuture: logicalFuture,
    );
  }

  factory PlaybackNativeOperation.completed(PlaybackNativeOperationKind kind) {
    final nativeFuture = Future<void>.value();
    final barrierFuture = Future<PlaybackNativeBarrierResult>.value(
      const PlaybackNativeBarrierResult.completed(),
    );
    return PlaybackNativeOperation._(
      kind: kind,
      timeout: Duration.zero,
      nativeFuture: nativeFuture,
      barrierFuture: barrierFuture,
      logicalFuture: nativeFuture,
    );
  }

  final PlaybackNativeOperationKind kind;
  final Duration timeout;
  final Future<void> nativeFuture;
  final Future<PlaybackNativeBarrierResult> barrierFuture;
  final Future<void> logicalFuture;
}

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
  progressiveInputFallback,
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
typedef PlaybackEngineOperation = Future<void> Function();
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
    this.nativeOperationTimeouts = const PlaybackNativeOperationTimeouts(),
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
  final PlaybackNativeOperationTimeouts nativeOperationTimeouts;

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
  final Set<Future<void>> _nativeOperations = {};
  Future<void>? _shutdownOperation;

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

  PlaybackNativeOperation startTrackedNativeOperation({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
    Duration? barrierTimeout,
    void Function()? onTimeout,
  }) {
    if (_shutdown) return PlaybackNativeOperation.completed(kind);
    return _trackNativeOperation(
      kind: kind,
      operation: operation,
      barrierTimeout: barrierTimeout,
      onTimeout: onTimeout,
    );
  }

  Future<void> runTrackedNativeOperation({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
    Duration? barrierTimeout,
    void Function()? onTimeout,
  }) => startTrackedNativeOperation(
    kind: kind,
    operation: operation,
    barrierTimeout: barrierTimeout,
    onTimeout: onTimeout,
  ).logicalFuture;

  Future<void> beginQuiescence({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
    Duration? barrierTimeout,
    void Function()? onTimeout,
  }) {
    assert(
      kind == PlaybackNativeOperationKind.lifecycleQuiesce ||
          kind == PlaybackNativeOperationKind.retirementQuiesce,
    );
    if (_shutdown) return Future<void>.value();
    invalidateForHigherPriorityOperation();
    return _trackNativeOperation(
      kind: kind,
      operation: operation,
      barrierTimeout: barrierTimeout,
      onTimeout: onTimeout,
    ).logicalFuture;
  }

  Future<void> waitForNativeOperations() async {
    while (_nativeOperations.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_nativeOperations));
    }
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

  Future<void> shutdown() {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    if (!_shutdown) {
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
      for (final pending in List<_ControlOperationRequest>.of(
        _controlPending,
      )) {
        _cancelControlOperation(pending);
      }
      _controlPending.clear();
    }
    return _shutdownOperation = waitForNativeOperations().timeout(
      nativeOperationTimeouts.shutdownBarrier,
      onTimeout: () {},
    );
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

    late final PlaybackNativeOperation nativeOperation;
    try {
      nativeOperation = _trackNativeOperation(
        kind: PlaybackNativeOperationKind.seek,
        operation: () => _seekEngine(request.target),
        barrierTimeout: seekCallTimeout,
      );
      await nativeOperation.logicalFuture;
    } on PlaybackNativeOperationTimedOut {
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
        nativeOperation.nativeFuture.then<void>(
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

  PlaybackNativeOperation _trackNativeOperation({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
    Duration? barrierTimeout,
    void Function()? onTimeout,
  }) {
    final nativeOperation = PlaybackNativeOperation.start(
      kind: kind,
      timeout: barrierTimeout ?? nativeOperationTimeouts.forKind(kind),
      operation: operation,
      onTimeout: onTimeout,
    );
    final barrier = nativeOperation.barrierFuture.then<void>((_) {});
    _nativeOperations.add(barrier);
    unawaited(
      barrier.whenComplete(() {
        _nativeOperations.remove(barrier);
      }),
    );
    return nativeOperation;
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
