import 'dart:async';

/// Counts new byte ranges only while waiting for the demuxer to become ready.
/// Re-reading cached data or repeatedly fetching the same range is not progress.
class SourceStartupProgress {
  void Function(int, int)? _onBytes;

  void recordBytes(int offset, int length) => _onBytes?.call(offset, length);

  Future<void> waitUntilReady(
    Future<void> ready, {
    required Duration idleTimeout,
    required Duration totalTimeout,
  }) async {
    if (_onBytes != null) throw StateError('Startup wait already active');
    final completed = Completer<void>();
    final intervals = <(int, int)>[];
    void fail(String reason) {
      if (!completed.isCompleted) {
        completed.completeError(TimeoutException(reason));
      }
    }

    var idle = Timer(
      idleTimeout,
      () => fail('Source startup made no progress'),
    );
    final total = Timer(
      totalTimeout,
      () => fail('Source startup budget exceeded'),
    );
    _onBytes = (offset, length) {
      if (completed.isCompleted || length <= 0) return;
      var start = offset;
      var end = offset + length;
      var added = length;
      var index = 0;
      while (index < intervals.length && intervals[index].$2 < start) {
        index++;
      }
      while (index < intervals.length && intervals[index].$1 <= end) {
        final prior = intervals.removeAt(index);
        final overlapStart = offset > prior.$1 ? offset : prior.$1;
        final overlapEnd = offset + length < prior.$2
            ? offset + length
            : prior.$2;
        if (overlapEnd > overlapStart) added -= overlapEnd - overlapStart;
        if (prior.$1 < start) start = prior.$1;
        if (prior.$2 > end) end = prior.$2;
      }
      intervals.insert(index, (start, end));
      if (added > 0) {
        idle.cancel();
        idle = Timer(
          idleTimeout,
          () => fail('Source startup made no progress'),
        );
      }
    };
    unawaited(
      ready.then<void>(
        (_) {
          if (!completed.isCompleted) completed.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!completed.isCompleted) completed.completeError(error, stack);
        },
      ),
    );
    try {
      await completed.future;
    } finally {
      _onBytes = null;
      idle.cancel();
      total.cancel();
    }
  }
}
