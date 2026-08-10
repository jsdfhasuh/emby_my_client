import '../models/emby_models.dart';
import 'playback_engine.dart';

enum PlaybackPhase {
  idle,
  resolving,
  opening,
  waitingForReady,
  seekingResume,
  ready,
  retryingWithTranscode,
  recoveryPending,
  recovering,
  failed,
  stopping,
}

class PlaybackState {
  const PlaybackState({
    this.phase = PlaybackPhase.idle,
    this.position = Duration.zero,
    this.requestedPosition,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.playbackRate = 1,
    this.plan,
    this.errorMessage,
    this.statusMessage,
  });

  final PlaybackPhase phase;
  final Duration position;
  final Duration? requestedPosition;
  final Duration duration;
  final Duration buffer;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;
  final List<EngineTrack> audioTracks;
  final List<EngineTrack> subtitleTracks;
  final double playbackRate;
  final PlaybackPlan? plan;
  final String? errorMessage;
  final String? statusMessage;

  bool get isReady => phase == PlaybackPhase.ready;
  bool get hasError => phase == PlaybackPhase.failed;
  Duration get displayPosition => requestedPosition ?? position;

  PlaybackState copyWith({
    PlaybackPhase? phase,
    Duration? position,
    Duration? requestedPosition,
    bool clearRequestedPosition = false,
    Duration? duration,
    Duration? buffer,
    bool? isPlaying,
    bool? isBuffering,
    bool? isCompleted,
    List<EngineTrack>? audioTracks,
    List<EngineTrack>? subtitleTracks,
    double? playbackRate,
    PlaybackPlan? plan,
    bool clearPlan = false,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
  }) => PlaybackState(
    phase: phase ?? this.phase,
    position: position ?? this.position,
    requestedPosition: clearRequestedPosition
        ? null
        : requestedPosition ?? this.requestedPosition,
    duration: duration ?? this.duration,
    buffer: buffer ?? this.buffer,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    isCompleted: isCompleted ?? this.isCompleted,
    audioTracks: audioTracks ?? this.audioTracks,
    subtitleTracks: subtitleTracks ?? this.subtitleTracks,
    playbackRate: playbackRate ?? this.playbackRate,
    plan: clearPlan ? null : plan ?? this.plan,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    statusMessage: clearStatus ? null : statusMessage ?? this.statusMessage,
  );
}
