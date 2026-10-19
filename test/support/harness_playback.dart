/// Exercise the actual play/pause control while waiting for acknowledged state.
/// A visible cue can predate the play event (for example after a paused seek),
/// so it cannot substitute for confirmation that the requested play has begun.
Future<void> playHarnessCueAndPause({
  required Future<void> Function() tapPlayPause,
  required Future<void> Function(bool playing) waitForPlaying,
  required Future<void> Function() waitForCue,
}) async {
  await waitForPlaying(false);
  await tapPlayPause();
  await waitForPlaying(true);
  await waitForCue();
  await tapPlayPause();
  await waitForPlaying(false);
}

/// Opening can finish legally paused after lifecycle quiescence. Observe the
/// actual current input before choosing a real UI toggle; always prove it can
/// play, then prove it is paused again before the first screenshot.
Future<void> pauseHarnessStartup({
  required Future<bool> Function() waitForReadyPlaying,
  required Future<void> Function() tapPlayPause,
  required Future<void> Function(bool playing) waitForPlaying,
}) async {
  if (!await waitForReadyPlaying()) {
    await tapPlayPause();
    await waitForPlaying(true);
  }
  await tapPlayPause();
  await waitForPlaying(false);
}

bool harnessPlayingAcknowledged(Map<String, Object?> value, bool playing) =>
    value['playerFound'] == true &&
    value['uiPlaying'] == playing &&
    value['dartPlaying'] == playing &&
    value['dartCompleted'] == false &&
    value['pause'] == (playing ? 'no' : 'yes') &&
    value['eof-reached'] == 'no' &&
    !value.containsKey('nativeReadError');

bool harnessStartupAcknowledged(Map<String, Object?> value) =>
    value['controllerReadyBefore'] == true &&
    value['controllerReadyAfter'] == true &&
    value['samePlayer'] == true &&
    value['epochBefore'] is int &&
    value['epochBefore'] == value['epochAfter'] &&
    value['dartDurationMs'] == 12000 &&
    double.tryParse('${value['duration']}') == 12 &&
    value['seeking'] == 'no' &&
    (harnessPlayingAcknowledged(value, true) ||
        harnessPlayingAcknowledged(value, false));

/// A replacement input is valid on a later probe, but one probe must never
/// combine the previous route's player with the current controller's engine.
bool harnessStartupResourceStable({
  required Object? engineBefore,
  required Object? engineAfter,
  required Object? routePlayerBefore,
  required Object? routePlayerAfter,
  required Object? boundPlayer,
}) =>
    engineBefore != null &&
    routePlayerBefore != null &&
    boundPlayer != null &&
    identical(engineBefore, engineAfter) &&
    identical(routePlayerBefore, routePlayerAfter) &&
    identical(routePlayerBefore, boundPlayer);
