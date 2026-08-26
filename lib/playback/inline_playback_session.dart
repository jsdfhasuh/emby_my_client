import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

enum InlinePlaybackPhase { inactive, loading, ready, failed }

@immutable
class InlinePlaybackState {
  const InlinePlaybackState({
    this.itemId,
    this.phase = InlinePlaybackPhase.inactive,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.errorMessage,
    this.videoController,
  });

  final String? itemId;
  final InlinePlaybackPhase phase;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;
  final String? errorMessage;
  final VideoController? videoController;

  bool get isReady => phase == InlinePlaybackPhase.ready;
  bool get hasError => phase == InlinePlaybackPhase.failed;

  InlinePlaybackState copyWith({
    String? itemId,
    InlinePlaybackPhase? phase,
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    bool? isBuffering,
    bool? isCompleted,
    String? errorMessage,
    bool clearError = false,
    VideoController? videoController,
  }) => InlinePlaybackState(
    itemId: itemId ?? this.itemId,
    phase: phase ?? this.phase,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    isCompleted: isCompleted ?? this.isCompleted,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    videoController: videoController ?? this.videoController,
  );
}

abstract interface class InlinePlaybackSession implements Listenable {
  String get itemId;
  InlinePlaybackState get state;

  Future<void> start({Duration? resumePosition});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> handleMemoryPressure();
  Future<void> shutdown();
}
