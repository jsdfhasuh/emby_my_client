import 'dart:async';

import 'native_playback_property_access.dart';

enum PlaybackCacheTelemetryStatus {
  available,
  fieldTemporarilyAbsent,
  unsupported,
  readFailed,
}

class PlaybackCacheTelemetryRange {
  const PlaybackCacheTelemetryRange({required this.start, required this.end});

  final Duration start;
  final Duration end;
}

class PlaybackCacheNativeState {
  const PlaybackCacheNativeState({
    this.fileCacheBytes,
    this.rawInputRateBytesPerSecond,
    this.seekableRanges = const [],
    this.cacheDuration,
    this.readerPts,
  });

  final int? fileCacheBytes;
  final int? rawInputRateBytesPerSecond;
  final List<PlaybackCacheTelemetryRange> seekableRanges;
  final Duration? cacheDuration;
  final Duration? readerPts;
}

class PlaybackCacheTelemetryRead {
  const PlaybackCacheTelemetryRead({required this.status, this.state});

  const PlaybackCacheTelemetryRead.available(PlaybackCacheNativeState state)
    : this(status: PlaybackCacheTelemetryStatus.available, state: state);

  const PlaybackCacheTelemetryRead.fieldTemporarilyAbsent()
    : this(status: PlaybackCacheTelemetryStatus.fieldTemporarilyAbsent);

  const PlaybackCacheTelemetryRead.unsupported()
    : this(status: PlaybackCacheTelemetryStatus.unsupported);

  const PlaybackCacheTelemetryRead.readFailed()
    : this(status: PlaybackCacheTelemetryStatus.readFailed);

  final PlaybackCacheTelemetryStatus status;
  final PlaybackCacheNativeState? state;
}

abstract interface class PlaybackCacheTelemetryReader {
  Future<PlaybackCacheTelemetryRead> readDemuxerCacheState();
}

class NativePlaybackCacheTelemetryReader
    implements PlaybackCacheTelemetryReader {
  NativePlaybackCacheTelemetryReader({
    required this.access,
    this.timeout = const Duration(seconds: 1),
    this.timeoutReporter,
  });

  final NativePlaybackPropertyAccess access;
  final Duration timeout;
  final NativePlaybackTimeoutReporter? timeoutReporter;

  @override
  Future<PlaybackCacheTelemetryRead> readDemuxerCacheState() async {
    Object? raw;
    try {
      raw = await withNativePlaybackTimeout(
        access.getNative('demuxer-cache-state'),
        operation: NativePlaybackOperationKind.propertyRead,
        timeout: timeout,
        onTimeout: timeoutReporter,
      );
    } catch (_) {
      return const PlaybackCacheTelemetryRead.readFailed();
    }

    if (raw == null) {
      try {
        final supported = await withNativePlaybackTimeout(
          access.hasProperty('demuxer-cache-state'),
          operation: NativePlaybackOperationKind.propertyRead,
          timeout: timeout,
          onTimeout: timeoutReporter,
        );
        return supported
            ? const PlaybackCacheTelemetryRead.fieldTemporarilyAbsent()
            : const PlaybackCacheTelemetryRead.unsupported();
      } catch (_) {
        return const PlaybackCacheTelemetryRead.readFailed();
      }
    }

    if (raw is! Map) {
      return const PlaybackCacheTelemetryRead.fieldTemporarilyAbsent();
    }
    final state = _parseState(raw);
    if (state == null) {
      return const PlaybackCacheTelemetryRead.fieldTemporarilyAbsent();
    }
    return PlaybackCacheTelemetryRead.available(state);
  }

  static PlaybackCacheNativeState? _parseState(Map<Object?, Object?> raw) {
    final fileCacheBytes = _parseNonNegativeInt(raw['file-cache-bytes']);
    final inputRate = _parseNonNegativeInt(raw['raw-input-rate']);
    final ranges = _parseRanges(raw['seekable-ranges']);
    final cacheDuration = _parseDuration(raw['cache-duration']);
    final readerPts = _parseDuration(raw['reader-pts']);
    if (fileCacheBytes == null &&
        inputRate == null &&
        ranges.isEmpty &&
        cacheDuration == null &&
        readerPts == null) {
      return null;
    }
    return PlaybackCacheNativeState(
      fileCacheBytes: fileCacheBytes,
      rawInputRateBytesPerSecond: inputRate,
      seekableRanges: ranges,
      cacheDuration: cacheDuration,
      readerPts: readerPts,
    );
  }

  static List<PlaybackCacheTelemetryRange> _parseRanges(Object? value) {
    if (value is! Iterable) return const [];
    final result = <PlaybackCacheTelemetryRange>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final start = _parseFiniteDouble(entry['start']);
      final end = _parseFiniteDouble(entry['end']);
      if (start == null || end == null || start < 0 || end <= start) {
        continue;
      }
      result.add(
        PlaybackCacheTelemetryRange(
          start: _durationFromSeconds(start),
          end: _durationFromSeconds(end),
        ),
      );
    }
    result.sort((left, right) => left.start.compareTo(right.start));
    return List.unmodifiable(result);
  }

  static Duration? _parseDuration(Object? value) {
    final seconds = _parseFiniteDouble(value);
    return seconds == null || seconds < 0
        ? null
        : _durationFromSeconds(seconds);
  }

  static Duration _durationFromSeconds(double seconds) => Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );

  static int? _parseNonNegativeInt(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString().trim() ?? '');
    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    final rounded = parsed.round();
    return parsed == rounded ? rounded : null;
  }

  static double? _parseFiniteDouble(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString().trim() ?? '');
    return parsed != null && parsed.isFinite ? parsed : null;
  }
}

class PlaybackCacheTelemetryReadCoordinator {
  PlaybackCacheTelemetryReadCoordinator({required this.reader});

  final PlaybackCacheTelemetryReader reader;
  _TelemetryReadOperation? _active;
  _TelemetryReadOperation? _pending;
  bool _disposed = false;

  Future<PlaybackCacheTelemetryRead?> readForGeneration({
    required int generation,
    required bool Function(int generation) isGenerationCurrent,
  }) {
    if (_disposed) return Future.value();
    final operation = _TelemetryReadOperation(
      generation: generation,
      isGenerationCurrent: isGenerationCurrent,
    );
    if (_active != null) {
      _pending?.complete(null);
      _pending = operation;
      return operation.future;
    }
    _start(operation);
    return operation.future;
  }

  Future<PlaybackCacheTelemetryRead> readDemuxerCacheState() async {
    final result = await readForGeneration(
      generation: 0,
      isGenerationCurrent: (_) => true,
    );
    return result ?? const PlaybackCacheTelemetryRead.readFailed();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending?.complete(null);
    _pending = null;
  }

  void _start(_TelemetryReadOperation operation) {
    _active = operation;
    Future<PlaybackCacheTelemetryRead> result;
    try {
      result = reader.readDemuxerCacheState();
    } catch (_) {
      result = Future.value(const PlaybackCacheTelemetryRead.readFailed());
    }
    result.then((value) => _finish(operation, value)).catchError((_) {
      _finish(operation, const PlaybackCacheTelemetryRead.readFailed());
    });
  }

  void _finish(
    _TelemetryReadOperation operation,
    PlaybackCacheTelemetryRead result,
  ) {
    if (!identical(_active, operation)) return;
    _active = null;
    final effective = operation.isGenerationCurrent(operation.generation)
        ? result
        : null;
    operation.complete(effective);
    final pending = _pending;
    _pending = null;
    if (!_disposed && pending != null) _start(pending);
  }
}

class _TelemetryReadOperation {
  _TelemetryReadOperation({
    required this.generation,
    required this.isGenerationCurrent,
  });

  final int generation;
  final bool Function(int generation) isGenerationCurrent;
  final Completer<PlaybackCacheTelemetryRead?> _completer = Completer();

  Future<PlaybackCacheTelemetryRead?> get future => _completer.future;

  void complete(PlaybackCacheTelemetryRead? value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }
}
