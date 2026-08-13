class PlaybackSeekStatisticsSnapshot {
  const PlaybackSeekStatisticsSnapshot({
    required this.requested,
    required this.executed,
    required this.superseded,
    required this.failed,
    required this.cancelled,
  });

  final int requested;
  final int executed;
  final int superseded;
  final int failed;
  final int cancelled;
}
