import 'dart:async';

import 'emby_event.dart';
import 'emby_websocket_client.dart';

typedef EmbyRealtimeRefreshPredicate = bool Function(EmbyEvent event);

bool isLibraryRefreshEvent(EmbyEvent event, {required String userId}) =>
    event is EmbyLibraryChanged ||
    (event is EmbyUserDataChanged && event.userId == userId);

class RealtimeRefreshBinding {
  RealtimeRefreshBinding({
    required EmbyWebSocketClient client,
    required Future<void> Function() refresh,
    required EmbyRealtimeRefreshPredicate shouldRefresh,
    Duration debounce = const Duration(milliseconds: 350),
  }) : _refresh = refresh,
       _shouldRefresh = shouldRefresh,
       _debounce = debounce {
    _subscription = client.events.listen(_onEvent);
  }

  final Future<void> Function() _refresh;
  final EmbyRealtimeRefreshPredicate _shouldRefresh;
  final Duration _debounce;
  late final StreamSubscription<EmbyEvent> _subscription;
  Timer? _timer;
  bool _refreshing = false;
  bool _refreshPending = false;
  bool _disposed = false;

  void _onEvent(EmbyEvent event) {
    if (_disposed || !_shouldRefresh(event)) return;
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(_runRefresh()));
  }

  Future<void> _runRefresh() async {
    if (_disposed) return;
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    try {
      await _refresh();
    } finally {
      _refreshing = false;
      if (_refreshPending && !_disposed) {
        _refreshPending = false;
        await _runRefresh();
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    await _subscription.cancel();
  }
}
