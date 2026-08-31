import 'dart:async';

import 'trickplay_frame_resolver.dart';

enum TrickplayPreviewStatus { idle, loading, ready, unavailable }

enum TrickplayPreviewFailureReason {
  metadataUnavailable,
  sourceMismatch,
  invalidMetadata,
  requestTimeout,
  networkFailure,
  decodeFailure,
}

class TrickplayPreviewLoadException implements Exception {
  const TrickplayPreviewLoadException(this.reason, {this.cause});

  final TrickplayPreviewFailureReason reason;
  final Object? cause;

  @override
  String toString() => 'TrickplayPreviewLoadException($reason, $cause)';
}

class TrickplayPreviewLoad<T> {
  TrickplayPreviewLoad({required this.future, required void Function() cancel})
    : _cancel = cancel;

  factory TrickplayPreviewLoad.future(Future<T> future) =>
      TrickplayPreviewLoad(future: future, cancel: () {});

  final Future<T> future;
  final void Function() _cancel;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

class TrickplaySheetIdentity {
  const TrickplaySheetIdentity({
    required this.playerItemGeneration,
    required this.itemId,
    required this.mediaSourceId,
    required this.resolutionWidth,
    required this.resolutionHeight,
    required this.tileColumns,
    required this.tileRows,
    required this.intervalMilliseconds,
    required this.thumbnailCount,
    required this.sheetIndex,
  });

  final String playerItemGeneration;
  final String itemId;
  final String mediaSourceId;
  final int resolutionWidth;
  final int resolutionHeight;
  final int tileColumns;
  final int tileRows;
  final int intervalMilliseconds;
  final int? thumbnailCount;
  final int sheetIndex;

  @override
  bool operator ==(Object other) =>
      other is TrickplaySheetIdentity &&
      other.playerItemGeneration == playerItemGeneration &&
      other.itemId == itemId &&
      other.mediaSourceId == mediaSourceId &&
      other.resolutionWidth == resolutionWidth &&
      other.resolutionHeight == resolutionHeight &&
      other.tileColumns == tileColumns &&
      other.tileRows == tileRows &&
      other.intervalMilliseconds == intervalMilliseconds &&
      other.thumbnailCount == thumbnailCount &&
      other.sheetIndex == sheetIndex;

  @override
  int get hashCode => Object.hash(
    playerItemGeneration,
    itemId,
    mediaSourceId,
    resolutionWidth,
    resolutionHeight,
    tileColumns,
    tileRows,
    intervalMilliseconds,
    thumbnailCount,
    sheetIndex,
  );
}

class TrickplayPreviewRequest {
  const TrickplayPreviewRequest({required this.identity, required this.frame});

  final TrickplaySheetIdentity identity;
  final TrickplayFrame frame;
}

class TrickplayPreviewState<T> {
  const TrickplayPreviewState({
    required this.status,
    this.sheet,
    this.sheetIdentity,
    this.frame,
    this.failureReason,
  });

  const TrickplayPreviewState.idle()
    : status = TrickplayPreviewStatus.idle,
      sheet = null,
      sheetIdentity = null,
      frame = null,
      failureReason = null;

  final TrickplayPreviewStatus status;
  final T? sheet;
  final TrickplaySheetIdentity? sheetIdentity;
  final TrickplayFrame? frame;
  final TrickplayPreviewFailureReason? failureReason;
}

typedef TrickplayPreviewListener<T> =
    void Function(TrickplayPreviewState<T> state);

class TrickplayPreviewController<T> {
  TrickplayPreviewController({
    TrickplayPreviewListener<T>? onChanged,
    Duration requestTimeout = const Duration(seconds: 3),
  }) : assert(requestTimeout > Duration.zero),
       _requestTimeout = requestTimeout,
       _listeners = {?onChanged};

  final Duration _requestTimeout;
  final Set<TrickplayPreviewListener<T>> _listeners;
  final Map<TrickplaySheetIdentity, _TrickplayLoadEntry<T>> _loads = {};
  final Map<TrickplaySheetIdentity, TrickplayPreviewFailureReason>
  _failedSheets = {};
  TrickplayPreviewState<T> _state = const TrickplayPreviewState.idle();
  TrickplayPreviewRequest? _latestRequest;
  int _generation = 0;
  bool _disposed = false;

  TrickplayPreviewState<T> get state => _state;

  void addListener(TrickplayPreviewListener<T> listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(TrickplayPreviewListener<T> listener) {
    _listeners.remove(listener);
  }

  void beginScrubSession() {
    _generation++;
    _latestRequest = null;
    _failedSheets.clear();
    _cancelLoads();
    _setState(const TrickplayPreviewState.idle());
  }

  void resetResource() {
    _generation++;
    _latestRequest = null;
    _failedSheets.clear();
    _cancelLoads();
    _setState(const TrickplayPreviewState.idle());
  }

  void showUnavailable(TrickplayPreviewFailureReason reason) {
    if (_disposed) return;
    _generation++;
    _latestRequest = null;
    _cancelLoads();
    _setState(
      TrickplayPreviewState(
        status: TrickplayPreviewStatus.unavailable,
        failureReason: reason,
      ),
    );
  }

  Future<void> request({
    required TrickplayPreviewRequest request,
    required TrickplayPreviewLoad<T> Function(TrickplaySheetIdentity identity)
    load,
  }) async {
    if (_disposed) return;
    final requestGeneration = _generation;
    _latestRequest = request;
    final current = _state;
    if (current.status == TrickplayPreviewStatus.ready &&
        current.sheet != null &&
        current.sheetIdentity == request.identity) {
      _setState(
        TrickplayPreviewState(
          status: TrickplayPreviewStatus.ready,
          sheet: current.sheet,
          sheetIdentity: request.identity,
          frame: request.frame,
        ),
      );
      return;
    }

    _setState(
      const TrickplayPreviewState(status: TrickplayPreviewStatus.loading),
    );

    final priorFailure = _failedSheets[request.identity];
    if (priorFailure != null) {
      _setState(
        TrickplayPreviewState(
          status: TrickplayPreviewStatus.unavailable,
          failureReason: priorFailure,
        ),
      );
      return;
    }

    final entry = _loads.putIfAbsent(
      request.identity,
      () => _createLoadEntry(request.identity, load),
    );

    try {
      final loadedSheet = await entry.future;
      if (!_isCurrent(requestGeneration, request.identity)) return;
      final latest = _latestRequest;
      if (latest == null || latest.identity != request.identity) return;
      _setState(
        TrickplayPreviewState(
          status: TrickplayPreviewStatus.ready,
          sheet: loadedSheet,
          sheetIdentity: request.identity,
          frame: latest.frame,
        ),
      );
    } catch (error) {
      if (!_isCurrent(requestGeneration, request.identity)) return;
      final failure = error is TrickplayPreviewLoadException
          ? error.reason
          : TrickplayPreviewFailureReason.decodeFailure;
      entry.load.cancel();
      _failedSheets[request.identity] = failure;
      _setState(
        TrickplayPreviewState(
          status: TrickplayPreviewStatus.unavailable,
          failureReason: failure,
        ),
      );
    }
  }

  void invalidate() {
    if (_disposed) return;
    _generation++;
    _latestRequest = null;
    _failedSheets.clear();
    _cancelLoads();
    _setState(const TrickplayPreviewState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _latestRequest = null;
    _cancelLoads();
    _listeners.clear();
    _state = const TrickplayPreviewState.idle();
  }

  _TrickplayLoadEntry<T> _createLoadEntry(
    TrickplaySheetIdentity identity,
    TrickplayPreviewLoad<T> Function(TrickplaySheetIdentity identity) load,
  ) {
    final handle = load(identity);
    late final _TrickplayLoadEntry<T> entry;
    final future = handle.future
        .timeout(
          _requestTimeout,
          onTimeout: () {
            handle.cancel();
            throw const TrickplayPreviewLoadException(
              TrickplayPreviewFailureReason.requestTimeout,
            );
          },
        )
        .whenComplete(() {
          if (identical(_loads[identity], entry)) _loads.remove(identity);
        });
    entry = _TrickplayLoadEntry(load: handle, future: future);
    return entry;
  }

  void _cancelLoads() {
    final loads = _loads.values.toList(growable: false);
    _loads.clear();
    for (final entry in loads) {
      entry.load.cancel();
    }
  }

  bool _isCurrent(int requestGeneration, TrickplaySheetIdentity identity) =>
      !_disposed &&
      requestGeneration == _generation &&
      _latestRequest?.identity == identity;

  void _setState(TrickplayPreviewState<T> state) {
    if (_disposed) return;
    _state = state;
    for (final listener in List<TrickplayPreviewListener<T>>.of(_listeners)) {
      listener(state);
    }
  }
}

class _TrickplayLoadEntry<T> {
  const _TrickplayLoadEntry({required this.load, required this.future});

  final TrickplayPreviewLoad<T> load;
  final Future<T> future;
}
