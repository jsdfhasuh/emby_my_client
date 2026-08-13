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

class PlaybackCacheReadIdentity {
  const PlaybackCacheReadIdentity({
    required this.sessionIdentity,
    required this.engineIdentity,
    required this.operationGeneration,
  });

  final Object sessionIdentity;
  final Object engineIdentity;
  final int operationGeneration;
}

typedef PlaybackCacheReadIdentityCurrent =
    bool Function(PlaybackCacheReadIdentity identity);

/// Converts the copied MPV_FORMAT_NODE map into the small, stable model used
/// by playback diagnostics. Native readers may include additional fields; the
/// parser deliberately ignores them and never exposes the raw node.
class PlaybackCacheNativeNodeParser {
  const PlaybackCacheNativeNodeParser._();

  static PlaybackCacheNativeState? parse(Object? value) {
    if (value is! Map) return null;
    final raw = <Object?, Object?>{...value};
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
      if (access is NativePlaybackNodeAccess) {
        final nodeAccess = access as NativePlaybackNodeAccess;
        raw = await withNativePlaybackTimeout(
          nodeAccess.getNativeNode('demuxer-cache-state'),
          operation: NativePlaybackOperationKind.propertyRead,
          timeout: timeout,
          onTimeout: timeoutReporter,
        );
      } else {
        raw = await withNativePlaybackTimeout(
          access.getNative('demuxer-cache-state'),
          operation: NativePlaybackOperationKind.propertyRead,
          timeout: timeout,
          onTimeout: timeoutReporter,
        );
      }
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
    final state = PlaybackCacheNativeNodeParser.parse(raw);
    if (state == null) {
      return const PlaybackCacheTelemetryRead.fieldTemporarilyAbsent();
    }
    return PlaybackCacheTelemetryRead.available(state);
  }
}

class PlaybackCacheTelemetryReadCoordinator {
  PlaybackCacheTelemetryReadCoordinator({required this.reader});

  final PlaybackCacheTelemetryReader reader;
  _TelemetryReadOperation? _active;
  _TelemetryReadOperation? _pending;
  bool _disposed = false;

  Future<PlaybackCacheTelemetryRead?> readForIdentity({
    required PlaybackCacheReadIdentity identity,
    required PlaybackCacheReadIdentityCurrent isIdentityCurrent,
  }) {
    if (_disposed || !isIdentityCurrent(identity)) return Future.value();
    final operation = _TelemetryReadOperation(
      identity: identity,
      isIdentityCurrent: isIdentityCurrent,
    );
    if (_active != null) {
      _pending?.complete(null);
      _pending = operation;
      return operation.future;
    }
    _start(operation);
    return operation.future;
  }

  Future<PlaybackCacheTelemetryRead?> readForGeneration({
    required int generation,
    required bool Function(int generation) isGenerationCurrent,
  }) {
    final identity = PlaybackCacheReadIdentity(
      sessionIdentity: this,
      engineIdentity: reader,
      operationGeneration: generation,
    );
    return readForIdentity(
      identity: identity,
      isIdentityCurrent: (candidate) =>
          identical(candidate.sessionIdentity, this) &&
          identical(candidate.engineIdentity, reader) &&
          isGenerationCurrent(candidate.operationGeneration),
    );
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
    final active = _active;
    _active = null;
    active?.complete(null);
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
    final effective =
        !_disposed && operation.isIdentityCurrent(operation.identity)
        ? result
        : null;
    operation.complete(effective);
    final pending = _pending;
    _pending = null;
    if (_disposed || pending == null) return;
    if (!pending.isIdentityCurrent(pending.identity)) {
      pending.complete(null);
      return;
    }
    _start(pending);
  }
}

class _TelemetryReadOperation {
  _TelemetryReadOperation({
    required this.identity,
    required this.isIdentityCurrent,
  });

  final PlaybackCacheReadIdentity identity;
  final PlaybackCacheReadIdentityCurrent isIdentityCurrent;
  final Completer<PlaybackCacheTelemetryRead?> _completer = Completer();

  Future<PlaybackCacheTelemetryRead?> get future => _completer.future;

  void complete(PlaybackCacheTelemetryRead? value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }
}
