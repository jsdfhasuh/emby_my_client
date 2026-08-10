import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import 'cache/playback_cache_storage.dart';

enum PlaybackDiagnosticsStorageSimulation { none, lowSpace, capacityUnknown }

class PlaybackDiagnosticsTestOverrides {
  const PlaybackDiagnosticsTestOverrides({
    this.streamBufferBytes,
    this.sessionTargetBytes,
    this.storageSimulation = PlaybackDiagnosticsStorageSimulation.none,
    this.injectApprovedSeekFailureAfterNextExecutedSeek = false,
    this.forceCacheCreateFailureObservation = false,
  });

  final int? streamBufferBytes;
  final int? sessionTargetBytes;
  final PlaybackDiagnosticsStorageSimulation storageSimulation;
  final bool injectApprovedSeekFailureAfterNextExecutedSeek;
  final bool forceCacheCreateFailureObservation;

  bool get isActive =>
      streamBufferBytes != null ||
      sessionTargetBytes != null ||
      storageSimulation != PlaybackDiagnosticsStorageSimulation.none ||
      injectApprovedSeekFailureAfterNextExecutedSeek ||
      forceCacheCreateFailureObservation;

  List<String> get activeTypes => [
    if (streamBufferBytes != null) 'streamBuffer',
    if (sessionTargetBytes != null) 'sessionTarget',
    if (storageSimulation != PlaybackDiagnosticsStorageSimulation.none)
      'storageSimulation',
    if (injectApprovedSeekFailureAfterNextExecutedSeek) 'seekFailure',
    if (forceCacheCreateFailureObservation) 'cacheCreateFailure',
  ];

  PlaybackCacheStorageSnapshot applyStorageSimulation(
    PlaybackCacheStorageSnapshot actual,
  ) => switch (storageSimulation) {
    PlaybackDiagnosticsStorageSimulation.none => actual,
    PlaybackDiagnosticsStorageSimulation.capacityUnknown =>
      const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.storageCapacityUnknown,
      ),
    PlaybackDiagnosticsStorageSimulation.lowSpace =>
      actual.session == null
          ? const PlaybackCacheStorageSnapshot.unavailable(
              PlaybackCacheStorageFailureReason.storageCapacityUnknown,
            )
          : PlaybackCacheStorageSnapshot.available(
              session: actual.session!,
              freeBytes: 256 * 1024 * 1024,
            ),
  };
}

class PlaybackDiagnosticsTestOverridesController extends ChangeNotifier {
  PlaybackDiagnosticsTestOverrides _next =
      const PlaybackDiagnosticsTestOverrides();

  PlaybackDiagnosticsTestOverrides get next => _next;
  bool get isActive => _next.isActive;

  void enable(PlaybackDiagnosticsTestOverrides overrides) {
    if (!overrides.isActive) {
      clear();
      return;
    }
    _next = overrides;
    DiagnosticLog.instance.info(
      'playback',
      'event=playback_test_override_enabled testOverrideActive=true '
          'types=${overrides.activeTypes.join(',')}',
    );
    notifyListeners();
  }

  PlaybackDiagnosticsTestOverrides? consumeForPlayback() {
    if (!_next.isActive) return null;
    final consumed = _next;
    _next = const PlaybackDiagnosticsTestOverrides();
    notifyListeners();
    return consumed;
  }

  void clear() {
    if (!_next.isActive) return;
    _next = const PlaybackDiagnosticsTestOverrides();
    DiagnosticLog.instance.info(
      'playback',
      'event=playback_test_override_cleared testOverrideActive=false',
    );
    notifyListeners();
  }
}
