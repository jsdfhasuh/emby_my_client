import 'dart:async';

import 'package:flutter/widgets.dart';

import 'browse_cache.dart';

/// Refreshes mounted browse views after recovery without trusting network-type
/// changes as proof that this particular server is reachable.
class BrowseRefreshBinding with WidgetsBindingObserver {
  BrowseRefreshBinding({
    required this.state,
    required Future<void> Function() refresh,
    this.retryDelay = const Duration(seconds: 30),
    this.debounce = const Duration(milliseconds: 350),
  }) : _refresh = refresh,
       _revision = state.recoveryRevision {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    state.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _scheduleRetry();
  }

  final BrowseCacheState state;
  final Future<void> Function() _refresh;
  final Duration retryDelay;
  final Duration debounce;
  int _revision;
  Timer? _retry;
  Timer? _debounce;
  bool _disposed = false;
  bool _refreshing = false;
  bool _pending = false;
  bool _foreground = true;

  void _changed() {
    if (_disposed) return;
    if (state.authenticationRequired) {
      _retry?.cancel();
      _retry = null;
      _debounce?.cancel();
      _debounce = null;
      _pending = false;
      return;
    }
    if (_revision != state.recoveryRevision) {
      _revision = state.recoveryRevision;
      _scheduleRefresh();
    }
    _scheduleRetry();
  }

  void _scheduleRefresh() {
    if (!_foreground || _disposed || state.authenticationRequired) return;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      _debounce = null;
      unawaited(_runRefresh());
    });
  }

  void _scheduleRetry() {
    if (_disposed ||
        !_foreground ||
        !state.offline ||
        state.authenticationRequired) {
      _retry?.cancel();
      _retry = null;
      return;
    }
    if (_retry != null || _refreshing) return;
    _retry = Timer(retryDelay, () {
      _retry = null;
      unawaited(_runRefresh());
    });
  }

  Future<void> _runRefresh() async {
    if (_disposed || !_foreground || state.authenticationRequired) return;
    if (_refreshing) {
      _pending = true;
      return;
    }
    _refreshing = true;
    try {
      await _refresh();
    } catch (_) {
      // The page/API owns its error presentation. A failed automatic retry
      // must not become an unhandled asynchronous error or end future retries.
    } finally {
      _refreshing = false;
      if (_pending && !_disposed) {
        _pending = false;
        _scheduleRefresh();
      }
      _scheduleRetry();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _retry?.cancel();
      _retry = null;
      _debounce?.cancel();
      _debounce = null;
    } else if (this.state.needsRecovery) {
      _scheduleRefresh();
    }
    _scheduleRetry();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    state.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _debounce?.cancel();
  }
}
