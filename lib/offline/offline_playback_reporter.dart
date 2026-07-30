import '../downloads/download_models.dart';
import '../models/emby_models.dart';
import '../playback/playback_session_reporter.dart';

typedef OfflineProgressWriter =
    Future<void> Function(Duration position, bool played);

class OfflinePlaybackReporter implements PlaybackReporter {
  OfflinePlaybackReporter({
    required this.item,
    required OfflineProgressWriter writeProgress,
  }) : _writeProgress = writeProgress;

  final OfflineMediaItem item;
  final OfflineProgressWriter _writeProgress;

  @override
  void activate(PlaybackPlan plan) {}

  @override
  void updatePlan(PlaybackPlan plan) {}

  @override
  Future<void> reportStart(Duration position) => _save(position);

  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) => _save(position);

  @override
  Future<void> stop(Duration position) => _save(position);

  @override
  Future<void> cleanup(PlaybackPlan plan) async {}

  Future<void> _save(Duration position) {
    final runtimeTicks = item.metadata.runTimeTicks;
    final played =
        runtimeTicks != null &&
        runtimeTicks > 0 &&
        position.inMicroseconds * 10 >= runtimeTicks * 0.9;
    return _writeProgress(position, played);
  }
}
