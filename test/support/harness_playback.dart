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
