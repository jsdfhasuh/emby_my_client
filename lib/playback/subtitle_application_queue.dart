import 'dart:async';

class SubtitleApplicationSuperseded implements Exception {
  const SubtitleApplicationSuperseded();
}

/// One queue per engine. The operation MUST return the native completion, not
/// a timeout/cancellation wrapper. Caller timeouts never release this queue.
class SubtitleApplicationQueue {
  _SubtitleWrite? _pending;
  bool _running = false;

  Future<void> submit({
    required bool Function() isCurrent,
    required Future<void> Function() apply,
  }) {
    final previous = _pending;
    if (previous != null) {
      previous.result.completeError(const SubtitleApplicationSuperseded());
    }
    final write = _SubtitleWrite(isCurrent, apply);
    _pending = write;
    if (!_running) unawaited(_drain());
    return write.result.future;
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending != null) {
        final write = _pending!;
        _pending = null;
        try {
          if (!write.isCurrent()) throw const SubtitleApplicationSuperseded();
          await write.apply();
          if (!write.isCurrent()) throw const SubtitleApplicationSuperseded();
          write.result.complete();
        } catch (error, stack) {
          write.result.completeError(error, stack);
        }
      }
    } finally {
      _running = false;
    }
  }
}

class _SubtitleWrite {
  _SubtitleWrite(this.isCurrent, this.apply);
  final bool Function() isCurrent;
  final Future<void> Function() apply;
  final result = Completer<void>();
}
