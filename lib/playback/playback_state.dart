import '../models/emby_models.dart';
import 'cache/playback_cache_capabilities.dart';
import 'cache/playback_cache_coordinator.dart';
import 'cache/playback_cache_engine.dart';
import 'cache/playback_cache_policy.dart';
import 'playback_engine.dart';
import 'playback_operation_coordinator.dart';

Duration resolveCompletedSeekDisplayPosition({
  required Duration startPosition,
  required Duration requestedTarget,
  required SeekResult? result,
}) => result?.disposition == SeekDisposition.executed
    ? result?.committedPosition ?? requestedTarget
    : startPosition;

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

enum SubtitleSelectionSource { serverDefault, explicit, disabled }

class SubtitleSelection {
  const SubtitleSelection.followServerDefault()
    : source = SubtitleSelectionSource.serverDefault,
      streamIndex = null;

  const SubtitleSelection.disabled()
    : source = SubtitleSelectionSource.disabled,
      streamIndex = null;

  const SubtitleSelection.explicitStream(int index)
    : source = SubtitleSelectionSource.explicit,
      streamIndex = index;

  final SubtitleSelectionSource source;
  final int? streamIndex;

  bool get isDisabled => source == SubtitleSelectionSource.disabled;

  @override
  bool operator ==(Object other) =>
      other is SubtitleSelection &&
      other.source == source &&
      other.streamIndex == streamIndex;

  @override
  int get hashCode => Object.hash(source, streamIndex);
}

enum SubtitleSelectionStatus {
  notApplied,
  applying,
  waitingForTracks,
  appliedNone,
  appliedEmbedded,
  appliedExternal,
  appliedServer,
  disabled,
  failed,
}

enum AppliedSubtitleKind { none, embedded, external, server }

enum AudioSelectionStatus { notApplied, applying, applied, failed }

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
    this.audioSelectionStatus = AudioSelectionStatus.notApplied,
    this.appliedAudioStreamIndex,
    this.playbackRate = 1,
    this.plan,
    this.desiredSubtitleSelection =
        const SubtitleSelection.followServerDefault(),
    this.subtitleSelectionStatus = SubtitleSelectionStatus.notApplied,
    this.appliedSubtitleKind = AppliedSubtitleKind.none,
    this.appliedSubtitleStreamIndex,
    this.subtitleApplicationGeneration = 0,
    this.subtitleSelectionError,
    this.errorMessage,
    this.statusMessage,
    this.cacheProfile,
    this.cacheCapabilities,
    this.cacheSnapshot,
    this.cacheObservation,
    this.cacheRuntimeMode = PlaybackCacheRuntimeMode.unconfirmed,
    this.cacheFallbackReason = PlaybackCacheFallbackReason.none,
    this.diskCacheFailureObserved = false,
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
  final AudioSelectionStatus audioSelectionStatus;
  final int? appliedAudioStreamIndex;
  final double playbackRate;
  final PlaybackPlan? plan;
  final SubtitleSelection desiredSubtitleSelection;
  final SubtitleSelectionStatus subtitleSelectionStatus;
  final AppliedSubtitleKind appliedSubtitleKind;
  final int? appliedSubtitleStreamIndex;
  final int subtitleApplicationGeneration;
  final String? subtitleSelectionError;
  final String? errorMessage;
  final String? statusMessage;
  final ResolvedPlaybackCacheProfile? cacheProfile;
  final PlaybackCacheEngineCapabilities? cacheCapabilities;
  final PlaybackCacheEngineSnapshot? cacheSnapshot;
  final PlaybackCacheObservation? cacheObservation;
  final PlaybackCacheRuntimeMode cacheRuntimeMode;
  final PlaybackCacheFallbackReason cacheFallbackReason;
  final bool diskCacheFailureObserved;

  bool get isReady => phase == PlaybackPhase.ready;
  bool get hasError => phase == PlaybackPhase.failed;
  Duration get displayPosition => requestedPosition ?? position;
  bool get fullReadAheadReachedEnd =>
      cacheObservation?.fullReadAheadReachedEnd ?? false;
  bool get fullReadAheadTelemetryAvailable =>
      cacheObservation?.telemetryAvailable ?? false;

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
    AudioSelectionStatus? audioSelectionStatus,
    int? appliedAudioStreamIndex,
    bool clearAppliedAudioStreamIndex = false,
    double? playbackRate,
    PlaybackPlan? plan,
    bool clearPlan = false,
    SubtitleSelection? desiredSubtitleSelection,
    SubtitleSelectionStatus? subtitleSelectionStatus,
    AppliedSubtitleKind? appliedSubtitleKind,
    int? appliedSubtitleStreamIndex,
    bool clearAppliedSubtitleStreamIndex = false,
    int? subtitleApplicationGeneration,
    String? subtitleSelectionError,
    bool clearSubtitleSelectionError = false,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
    ResolvedPlaybackCacheProfile? cacheProfile,
    bool clearCacheProfile = false,
    PlaybackCacheEngineCapabilities? cacheCapabilities,
    PlaybackCacheEngineSnapshot? cacheSnapshot,
    bool clearCacheSnapshot = false,
    PlaybackCacheObservation? cacheObservation,
    bool clearCacheObservation = false,
    PlaybackCacheRuntimeMode? cacheRuntimeMode,
    PlaybackCacheFallbackReason? cacheFallbackReason,
    bool? diskCacheFailureObserved,
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
    audioSelectionStatus: audioSelectionStatus ?? this.audioSelectionStatus,
    appliedAudioStreamIndex: clearAppliedAudioStreamIndex
        ? null
        : appliedAudioStreamIndex ?? this.appliedAudioStreamIndex,
    playbackRate: playbackRate ?? this.playbackRate,
    plan: clearPlan ? null : plan ?? this.plan,
    desiredSubtitleSelection:
        desiredSubtitleSelection ?? this.desiredSubtitleSelection,
    subtitleSelectionStatus:
        subtitleSelectionStatus ?? this.subtitleSelectionStatus,
    appliedSubtitleKind: appliedSubtitleKind ?? this.appliedSubtitleKind,
    appliedSubtitleStreamIndex: clearAppliedSubtitleStreamIndex
        ? null
        : appliedSubtitleStreamIndex ?? this.appliedSubtitleStreamIndex,
    subtitleApplicationGeneration:
        subtitleApplicationGeneration ?? this.subtitleApplicationGeneration,
    subtitleSelectionError: clearSubtitleSelectionError
        ? null
        : subtitleSelectionError ?? this.subtitleSelectionError,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    statusMessage: clearStatus ? null : statusMessage ?? this.statusMessage,
    cacheProfile: clearCacheProfile ? null : cacheProfile ?? this.cacheProfile,
    cacheCapabilities: cacheCapabilities ?? this.cacheCapabilities,
    cacheSnapshot: clearCacheSnapshot
        ? null
        : cacheSnapshot ?? this.cacheSnapshot,
    cacheObservation: clearCacheObservation
        ? null
        : cacheObservation ?? this.cacheObservation,
    cacheRuntimeMode: cacheRuntimeMode ?? this.cacheRuntimeMode,
    cacheFallbackReason: cacheFallbackReason ?? this.cacheFallbackReason,
    diskCacheFailureObserved:
        diskCacheFailureObserved ?? this.diskCacheFailureObserved,
  );
}
