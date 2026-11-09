import '../models/emby_models.dart';

enum LibraryWatchState { unwatched, inProgress, watched }

/// The visible state of a single photo or playable video.
///
/// A position or percentage means watching has started, but only the server's
/// Played flag marks a video as watched. Containers have no leaf viewing state.
class LibraryWatchStatus {
  const LibraryWatchStatus._({
    required this.state,
    required this.isPhoto,
    this.progress,
  });

  final LibraryWatchState state;
  final bool isPhoto;
  final double? progress;

  static LibraryWatchStatus? forItem(EmbyItem item) {
    if (item.isLibraryContainer || item.isSeries || item.type == 'Season') {
      return null;
    }
    if (!item.isPhoto && !item.isPlayable) return null;
    if (item.userData.isPlayed) {
      return LibraryWatchStatus._(
        state: LibraryWatchState.watched,
        isPhoto: item.isPhoto,
      );
    }
    if (item.isPhoto) {
      return const LibraryWatchStatus._(
        state: LibraryWatchState.unwatched,
        isPhoto: true,
      );
    }

    final percentage = item.userData.playedPercentage;
    final hasPercentage = percentage.isFinite && percentage > 0;
    final position = item.userData.playbackPositionTicks;
    if (!hasPercentage && position <= 0) {
      return const LibraryWatchStatus._(
        state: LibraryWatchState.unwatched,
        isPhoto: false,
      );
    }

    final duration = item.runTimeTicks;
    final progress = hasPercentage
        ? (percentage / 100).clamp(0.0, 1.0)
        : duration != null && duration > 0
        ? (position / duration).clamp(0.0, 1.0)
        : null;
    return LibraryWatchStatus._(
      state: LibraryWatchState.inProgress,
      isPhoto: false,
      progress: progress,
    );
  }

  String get label => switch (state) {
    LibraryWatchState.unwatched => isPhoto ? '未查看' : '未观看',
    LibraryWatchState.watched => isPhoto ? '已查看' : '已观看',
    LibraryWatchState.inProgress =>
      progress == null ? '观看中' : '观看中 ${(progress! * 100).round()}%',
  };
}
