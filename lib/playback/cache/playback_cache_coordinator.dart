import 'dart:async';
import 'dart:math';

import 'playback_cache_engine.dart';
import 'playback_cache_policy.dart';
import 'playback_cache_storage.dart';

enum PlaybackCacheSafetyReason { budget, lowSpace, memoryPressure }

class PlaybackCacheObservation {
  const PlaybackCacheObservation({
    required this.engineSnapshot,
    required this.actualForward,
    required this.actualBackward,
    required this.availableBytes,
    required this.stopThresholdBytes,
    required this.lowSpaceTriggerBytes,
  });

  final PlaybackCacheEngineSnapshot? engineSnapshot;
  final Duration? actualForward;
  final Duration? actualBackward;
  final int? availableBytes;
  final int stopThresholdBytes;
  final int lowSpaceTriggerBytes;
}

typedef PlaybackCachePositionReader = Duration Function();
typedef PlaybackCacheObservationListener =
    void Function(PlaybackCacheObservation observation);
typedef PlaybackCacheSafetyHandler =
    Future<void> Function(PlaybackCacheSafetyReason reason);

class PlaybackCacheCoordinator {
  PlaybackCacheCoordinator({
    required this.engine,
    required this.storage,
    required this.session,
    required this.profile,
    required this.mediaBitrate,
    required this.committedPosition,
    required this.onObservation,
    required this.onSafetyReopen,
    this.statePollInterval = const Duration(seconds: 1),
    this.spacePollInterval = const Duration(seconds: 10),
    this.expectedCloseLatency = const Duration(seconds: 2),
  });

  static const int _mib = 1024 * 1024;

  final PlaybackCacheEngine engine;
  final PlaybackCacheStorage storage;
  final PlaybackCacheSession session;
  final ResolvedPlaybackCacheProfile profile;
  final int? mediaBitrate;
  final PlaybackCachePositionReader committedPosition;
  final PlaybackCacheObservationListener onObservation;
  final PlaybackCacheSafetyHandler onSafetyReopen;
  final Duration statePollInterval;
  final Duration spacePollInterval;
  final Duration expectedCloseLatency;

  Timer? _stateTimer;
  Timer? _spaceTimer;
  Future<void>? _refreshInFlight;
  bool _refreshAgain = false;
  bool _refreshAgainWithSpace = false;
  bool _active = false;
  bool _safetyRequested = false;
  int? _lastAvailableBytes;

  bool get isActive => _active;
  bool get safetyReopenRequested => _safetyRequested;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    await refreshNow(checkSpace: true);
    if (!_active || _safetyRequested) return;
    _startTimers();
  }

  void pause() {
    _stateTimer?.cancel();
    _spaceTimer?.cancel();
    _stateTimer = null;
    _spaceTimer = null;
  }

  Future<void> resume() async {
    if (!_active || _safetyRequested) return;
    await refreshNow(checkSpace: true);
    if (_active && !_safetyRequested) _startTimers();
  }

  Future<void> afterExecutedSeek() => refreshNow(checkSpace: true);

  Future<void> handleMemoryPressure() async {
    if (!_active || _safetyRequested) return;
    await _requestSafetyReopen(PlaybackCacheSafetyReason.memoryPressure);
  }

  Future<void> refreshNow({required bool checkSpace}) {
    if (!_active || _safetyRequested) return Future<void>.value();
    final current = _refreshInFlight;
    if (current != null) {
      _refreshAgain = true;
      _refreshAgainWithSpace = _refreshAgainWithSpace || checkSpace;
      return current;
    }
    final operation = _drainRefresh(checkSpace);
    _refreshInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_refreshInFlight, operation)) _refreshInFlight = null;
    });
  }

  Future<void> _drainRefresh(bool checkSpace) async {
    var shouldCheckSpace = checkSpace;
    do {
      _refreshAgain = false;
      _refreshAgainWithSpace = false;
      await _refresh(shouldCheckSpace);
      shouldCheckSpace = _refreshAgainWithSpace;
    } while (_active && !_safetyRequested && _refreshAgain);
  }

  Future<void> _refresh(bool checkSpace) async {
    PlaybackCacheEngineSnapshot? snapshot;
    try {
      snapshot = await engine.readCacheSnapshot();
    } catch (_) {
      snapshot = null;
    }
    if (!_active) return;

    if (checkSpace) {
      try {
        _lastAvailableBytes = await storage.freeBytesFor(session.directory);
      } catch (_) {
        _lastAvailableBytes = null;
      }
      if (!_active) return;
    }

    final rate = _effectiveRate(snapshot?.rawInputRateBytesPerSecond);
    final stopThreshold = cacheStopThresholdBytes(
      targetBytes: profile.sessionTargetBytes,
      inputRateBytesPerSecond: rate,
      pollInterval: statePollInterval,
      expectedCloseLatency: expectedCloseLatency,
    );
    final lowSpaceTrigger = cacheLowSpaceTriggerBytes(
      reservedFreeBytes: profile.reservedFreeBytes,
      inputRateBytesPerSecond: rate,
      pollInterval: spacePollInterval,
      expectedCloseLatency: expectedCloseLatency,
    );
    final ranges = normalizedPlaybackCacheRanges(
      snapshot?.seekableRanges ?? const [],
    );
    final actual = actualPlaybackCacheRange(
      ranges: ranges,
      position: committedPosition(),
    );
    try {
      onObservation(
        PlaybackCacheObservation(
          engineSnapshot: snapshot,
          actualForward: actual?.forward,
          actualBackward: actual?.backward,
          availableBytes: _lastAvailableBytes,
          stopThresholdBytes: stopThreshold,
          lowSpaceTriggerBytes: lowSpaceTrigger,
        ),
      );
    } catch (_) {
      // Observation delivery is diagnostic-only.
    }

    final available = _lastAvailableBytes;
    if (available != null && available <= lowSpaceTrigger) {
      await _requestSafetyReopen(PlaybackCacheSafetyReason.lowSpace);
      return;
    }
    final fileBytes = snapshot?.fileCacheBytes;
    if (fileBytes != null && fileBytes >= stopThreshold) {
      await _requestSafetyReopen(PlaybackCacheSafetyReason.budget);
    }
  }

  Future<void> _requestSafetyReopen(PlaybackCacheSafetyReason reason) async {
    if (!_active || _safetyRequested) return;
    _safetyRequested = true;
    pause();
    try {
      await onSafetyReopen(reason);
    } catch (_) {
      // Safety handling is best-effort and must never trap route shutdown.
    }
  }

  void _startTimers() {
    pause();
    _stateTimer = Timer.periodic(
      statePollInterval,
      (_) => unawaited(refreshNow(checkSpace: false)),
    );
    _spaceTimer = Timer.periodic(
      spacePollInterval,
      (_) => unawaited(refreshNow(checkSpace: true)),
    );
  }

  Future<void> stop() async {
    final inFlight = _refreshInFlight;
    cancel();
    await inFlight;
  }

  void cancel() {
    if (!_active) return;
    _active = false;
    pause();
  }

  int _effectiveRate(int? nativeRate) {
    if (nativeRate != null && nativeRate > 0) return nativeRate;
    final bitrateRate = ((mediaBitrate ?? 0) / 8 * 2).round();
    return max(bitrateRate, 8 * _mib);
  }
}

class PlaybackCacheActualRange {
  const PlaybackCacheActualRange({
    required this.backward,
    required this.forward,
  });

  final Duration backward;
  final Duration forward;
}

List<PlaybackCacheRange> normalizedPlaybackCacheRanges(
  Iterable<PlaybackCacheRange> source,
) {
  final sorted =
      source.where((range) => range.end > range.start).toList(growable: false)
        ..sort((left, right) => left.start.compareTo(right.start));
  if (sorted.isEmpty) return const [];
  final merged = <PlaybackCacheRange>[];
  var current = sorted.first;
  for (final next in sorted.skip(1)) {
    if (next.start <= current.end) {
      if (next.end > current.end) {
        current = PlaybackCacheRange(start: current.start, end: next.end);
      }
      continue;
    }
    merged.add(current);
    current = next;
  }
  merged.add(current);
  return List.unmodifiable(merged);
}

PlaybackCacheActualRange? actualPlaybackCacheRange({
  required Iterable<PlaybackCacheRange> ranges,
  required Duration position,
}) {
  for (final range in ranges) {
    if (position < range.start || position > range.end) continue;
    return PlaybackCacheActualRange(
      backward: position - range.start,
      forward: range.end - position,
    );
  }
  return null;
}

int cacheStopThresholdBytes({
  required int targetBytes,
  required int inputRateBytesPerSecond,
  required Duration pollInterval,
  required Duration expectedCloseLatency,
}) {
  const mib = 1024 * 1024;
  final rawGuard =
      inputRateBytesPerSecond *
      (pollInterval + expectedCloseLatency).inMilliseconds ~/
      1000;
  final maximumGuard = min(256 * mib, max(32 * mib, targetBytes ~/ 2));
  final guard = rawGuard.clamp(32 * mib, maximumGuard);
  return max(64 * mib, targetBytes - guard);
}

int cacheLowSpaceTriggerBytes({
  required int reservedFreeBytes,
  required int inputRateBytesPerSecond,
  required Duration pollInterval,
  required Duration expectedCloseLatency,
}) {
  const mib = 1024 * 1024;
  final rawGuard =
      inputRateBytesPerSecond *
      (pollInterval + expectedCloseLatency).inMilliseconds ~/
      1000;
  return reservedFreeBytes + rawGuard.clamp(64 * mib, 512 * mib);
}
