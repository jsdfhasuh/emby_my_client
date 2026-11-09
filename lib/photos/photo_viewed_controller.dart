import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';

typedef PhotoViewedWriter = Future<void> Function(String itemId, bool viewed);

/// Records only a successfully displayed, settled foreground photo. Prefetching
/// never enters this controller; explicit unviewed marks last for this session.
class PhotoViewedController extends ChangeNotifier {
  PhotoViewedController({
    required PhotoViewedWriter writeViewed,
    required void Function(String itemId, bool viewed) onSaved,
    this.viewingDelay = const Duration(seconds: 1),
  }) : _writeViewed = writeViewed,
       _onSaved = onSaved;

  final PhotoViewedWriter _writeViewed;
  final void Function(String itemId, bool viewed) _onSaved;
  final Duration viewingDelay;
  final Map<String, bool> _viewed = {};
  final Map<String, Object> _failures = {};
  final Map<String, Future<bool>> _pending = {};
  final Set<String> _automaticAttempts = {};
  final Set<String> _manualUnviewed = {};
  String? _currentItemId;
  bool _imageDisplayed = false;
  bool _foreground = true;
  bool _closed = false;
  bool _disposed = false;
  Timer? _timer;

  String? get currentItemId => _currentItemId;
  bool get isViewed => _viewed[_currentItemId] ?? false;
  bool get isSaving => _pending.containsKey(_currentItemId);
  Object? get error => _failures[_currentItemId];

  void activate(EmbyItem? item) {
    if (_closed || _disposed) return;
    final photo = item?.isPhoto == true ? item : null;
    if (_currentItemId == photo?.id) return;
    _cancelTimer();
    _currentItemId = photo?.id;
    _imageDisplayed = false;
    if (photo != null) {
      _viewed.putIfAbsent(photo.id, () => photo.userData.isPlayed);
    }
    _notify();
  }

  void setForeground(bool foreground) {
    if (_closed || _disposed || _foreground == foreground) return;
    _foreground = foreground;
    _scheduleIfEligible();
  }

  void imageDisplayed(String itemId, bool displayed) {
    if (_closed || _disposed || itemId != _currentItemId) return;
    if (_imageDisplayed == displayed) return;
    _imageDisplayed = displayed;
    _scheduleIfEligible();
  }

  Future<bool> markCurrent({required bool viewed}) {
    final itemId = _currentItemId;
    if (_closed || _disposed || itemId == null || isSaving) {
      return Future.value(false);
    }
    _cancelTimer();
    _automaticAttempts.add(itemId);
    if (!viewed) _manualUnviewed.add(itemId);
    if (_viewed[itemId] == viewed && !_failures.containsKey(itemId)) {
      return Future.value(true);
    }
    return _save(itemId, viewed);
  }

  bool get _canAutomaticallyMark {
    final itemId = _currentItemId;
    return !_closed &&
        !_disposed &&
        _foreground &&
        _imageDisplayed &&
        itemId != null &&
        !isViewed &&
        !isSaving &&
        !_automaticAttempts.contains(itemId) &&
        !_manualUnviewed.contains(itemId);
  }

  void _scheduleIfEligible() {
    _cancelTimer();
    if (!_canAutomaticallyMark) return;
    final itemId = _currentItemId!;
    _timer = Timer(viewingDelay, () {
      _timer = null;
      if (!_canAutomaticallyMark || _currentItemId != itemId) return;
      _automaticAttempts.add(itemId);
      unawaited(_save(itemId, true));
    });
  }

  Future<bool> _save(String itemId, bool viewed) {
    final existing = _pending[itemId];
    if (existing != null) return existing;
    final completer = Completer<bool>();
    _pending[itemId] = completer.future;
    _failures.remove(itemId);
    _notify();
    unawaited(() async {
      var saved = false;
      try {
        await _writeViewed(itemId, viewed);
        if (!_disposed) {
          _viewed[itemId] = viewed;
          _failures.remove(itemId);
          _onSaved(itemId, viewed);
        }
        saved = true;
      } catch (error, stackTrace) {
        if (!_disposed) _failures[itemId] = error;
        DiagnosticLog.instance.error(
          'photo',
          'Photo viewed status could not be saved',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        _pending.remove(itemId);
        _notify();
        completer.complete(saved);
      }
    }());
    return completer.future;
  }

  Future<Set<String>> finish({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    _closed = true;
    _cancelTimer();
    try {
      await Future.wait(_pending.values.toList()).timeout(timeout);
      return const {};
    } on TimeoutException {
      DiagnosticLog.instance.warning(
        'photo',
        'Photo viewed status still pending on viewer exit; refresh required',
      );
      return Set.unmodifiable(_pending.keys);
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _closed = true;
    _cancelTimer();
    super.dispose();
  }
}
