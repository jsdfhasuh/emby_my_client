class PlaybackRecoveryPolicy {
  const PlaybackRecoveryPolicy({
    this.seekRecoveryWindow = const Duration(seconds: 15),
    this.stablePlaybackWindow = const Duration(seconds: 5),
    this.fingerprintDedupeWindow = const Duration(seconds: 2),
    this.recoveryAttemptTimeout = const Duration(seconds: 15),
  });

  final Duration seekRecoveryWindow;
  final Duration stablePlaybackWindow;
  final Duration fingerprintDedupeWindow;
  final Duration recoveryAttemptTimeout;
}
