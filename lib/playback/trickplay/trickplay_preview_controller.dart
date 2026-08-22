import 'trickplay_frame_resolver.dart';

enum TrickplayPreviewStatus { idle, loading, ready, unavailable }

class TrickplaySheetIdentity {
  const TrickplaySheetIdentity({
    required this.playerItemGeneration,
    required this.itemId,
    required this.mediaSourceId,
    required this.resolutionWidth,
    required this.sheetIndex,
  });

  final String playerItemGeneration;
  final String itemId;
  final String mediaSourceId;
  final int resolutionWidth;
  final int sheetIndex;

  @override
  bool operator ==(Object other) =>
      other is TrickplaySheetIdentity &&
      other.playerItemGeneration == playerItemGeneration &&
      other.itemId == itemId &&
      other.mediaSourceId == mediaSourceId &&
      other.resolutionWidth == resolutionWidth &&
      other.sheetIndex == sheetIndex;

  @override
  int get hashCode => Object.hash(
    playerItemGeneration,
    itemId,
    mediaSourceId,
    resolutionWidth,
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
  });

  const TrickplayPreviewState.idle()
    : status = TrickplayPreviewStatus.idle,
      sheet = null,
      sheetIdentity = null,
      frame = null;

  final TrickplayPreviewStatus status;
  final T? sheet;
  final TrickplaySheetIdentity? sheetIdentity;
  final TrickplayFrame? frame;
}

typedef TrickplayPreviewListener<T> =
    void Function(TrickplayPreviewState<T> state);

class TrickplayPreviewController<T> {
  TrickplayPreviewController({TrickplayPreviewListener<T>? onChanged})
    : _listeners = {?onChanged};

  final Set<TrickplayPreviewListener<T>> _listeners;
  final Map<TrickplaySheetIdentity, Future<T>> _loads = {};
  final Set<TrickplaySheetIdentity> _failedSheets = {};
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
    _setState(const TrickplayPreviewState.idle());
  }

  void resetResource() {
    _generation++;
    _latestRequest = null;
    _failedSheets.clear();
    _setState(const TrickplayPreviewState.idle());
  }

  void showUnavailable() {
    if (_disposed) return;
    _latestRequest = null;
    _setState(
      const TrickplayPreviewState(status: TrickplayPreviewStatus.unavailable),
    );
  }

  Future<void> request({
    required TrickplayPreviewRequest request,
    required Future<T> Function(TrickplaySheetIdentity identity) load,
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

    if (_failedSheets.contains(request.identity)) {
      _setState(
        const TrickplayPreviewState(status: TrickplayPreviewStatus.unavailable),
      );
      return;
    }

    final sheet = _loads.putIfAbsent(request.identity, () async {
      try {
        return await load(request.identity);
      } finally {
        _loads.remove(request.identity);
      }
    });

    try {
      final loadedSheet = await sheet;
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
    } catch (_) {
      if (!_isCurrent(requestGeneration, request.identity)) return;
      _failedSheets.add(request.identity);
      _setState(
        const TrickplayPreviewState(status: TrickplayPreviewStatus.unavailable),
      );
    }
  }

  void invalidate() {
    if (_disposed) return;
    _generation++;
    _latestRequest = null;
    _failedSheets.clear();
    _setState(const TrickplayPreviewState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _latestRequest = null;
    _listeners.clear();
    _state = const TrickplayPreviewState.idle();
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
