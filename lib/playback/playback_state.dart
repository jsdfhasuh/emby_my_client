import 'subtitle_target.dart';
import 'subtitle_problem.dart';
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

enum SubtitleSelectionSource {
  serverDefault,
  explicit,
  native,
  localExternal,
  disabled,
}

class SubtitleSelection {
  const SubtitleSelection.followServerDefault()
    : this._(SubtitleSelectionSource.serverDefault, null, null);
  const SubtitleSelection.disabled()
    : this._(SubtitleSelectionSource.disabled, null, null);
  const SubtitleSelection.explicitStream(int index)
    : this._(SubtitleSelectionSource.explicit, index, null);
  const SubtitleSelection.nativeTrack(NativeSubtitleTrack target)
    : this._(SubtitleSelectionSource.native, null, target);
  SubtitleSelection.localExternal(LocalExternalAsset target)
    : this._(SubtitleSelectionSource.localExternal, target.index, target);
  const SubtitleSelection._(
    this.source,
    this.streamIndex,
    this._target, [
    this.requestRevision = 0,
    this.inputEpoch,
  ]);
  final SubtitleSelectionSource source;
  final int? streamIndex;
  final SubtitleTarget? _target;
  SubtitleTarget? get target =>
      _target ??
      (source == SubtitleSelectionSource.explicit
          ? ServerStream(streamIndex!)
          : null);
  final int requestRevision;
  final int? inputEpoch;
  SubtitleSelection withRevision(int revision, int epoch) =>
      SubtitleSelection._(source, streamIndex, target, revision, epoch);
  bool get isDisabled => source == SubtitleSelectionSource.disabled;
  @override
  bool operator ==(Object other) =>
      other is SubtitleSelection &&
      other.source == source &&
      other.streamIndex == streamIndex &&
      (source != SubtitleSelectionSource.native &&
              source != SubtitleSelectionSource.localExternal ||
          identical(other.target, target));
  @override
  int get hashCode => Object.hash(
    source,
    streamIndex,
    source == SubtitleSelectionSource.native ||
            source == SubtitleSelectionSource.localExternal
        ? target
        : null,
  );
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
    this.appliedNativeSubtitleId,
    this.subtitleApplicationGeneration = 0,
    this.subtitleSelectionError,
    this.subtitleProblem,
    this.actualSubtitleCodec,
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
  final String? appliedNativeSubtitleId;
  final int subtitleApplicationGeneration;
  final String? subtitleSelectionError;
  final SubtitleProblem? subtitleProblem;
  final String? actualSubtitleCodec;
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
    String? appliedNativeSubtitleId,
    bool clearAppliedNativeSubtitleId = false,
    bool clearAppliedSubtitleStreamIndex = false,
    int? subtitleApplicationGeneration,
    String? subtitleSelectionError,
    SubtitleProblem? subtitleProblem,
    String? actualSubtitleCodec,
    bool clearActualSubtitleCodec = false,
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
    appliedNativeSubtitleId: clearAppliedNativeSubtitleId
        ? null
        : appliedNativeSubtitleId ?? this.appliedNativeSubtitleId,
    subtitleApplicationGeneration:
        subtitleApplicationGeneration ?? this.subtitleApplicationGeneration,
    actualSubtitleCodec:
        (clearActualSubtitleCodec ||
            (subtitleSelectionStatus != null &&
                subtitleSelectionStatus !=
                    SubtitleSelectionStatus.appliedEmbedded &&
                subtitleSelectionStatus !=
                    SubtitleSelectionStatus.appliedExternal &&
                subtitleSelectionStatus !=
                    SubtitleSelectionStatus.appliedServer))
        ? null
        : actualSubtitleCodec ?? this.actualSubtitleCodec,
    subtitleProblem: clearSubtitleSelectionError
        ? null
        : subtitleProblem ?? this.subtitleProblem,
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
