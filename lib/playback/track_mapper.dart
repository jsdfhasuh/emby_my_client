import '../models/emby_models.dart';
import 'playback_engine.dart';

class PlaybackTrack {
  const PlaybackTrack({
    required this.index,
    required this.type,
    String? title,
    this.displayTitle,
    this.language,
    this.codec,
    this.channels,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.deliveryUrl,
  }) : originalTitle = title;

  final int index;
  final String type;

  /// The container's original Title is identity evidence. DisplayTitle is a
  /// server-generated UI label and must never constrain track matching.
  final String? originalTitle;
  final String? displayTitle;
  String? get title => displayTitle ?? originalTitle;
  final String? language;
  final String? codec;
  final int? channels;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;
  final String? deliveryUrl;
}

enum TrackMappingStatus { matched, unavailable, ambiguous }

enum TrackMappingReason {
  matched,
  noTracks,
  missingServerTrack,
  insufficientMetadata,
  metadataConflict,
  multipleCandidates,
  externalLocationMissing,
  trackWaitTimedOut,
}

enum TrackMetadataField { language, codec, title, channels, displayTitle }

class TrackMappingResult {
  const TrackMappingResult(
    this.status, {
    this.engineId,
    required this.reason,
    required this.realTrackCount,
    required this.candidateCount,
    this.serverFields = const {},
    this.engineFields = const {},
    this.conflictFields = const {},
  });
  final TrackMappingStatus status;
  final String? engineId;
  final TrackMappingReason reason;
  final int realTrackCount;
  final int candidateCount;
  final Set<TrackMetadataField> serverFields;
  final Set<TrackMetadataField> engineFields;
  final Set<TrackMetadataField> conflictFields;

  TrackMappingResult asUnavailable(TrackMappingReason reason) =>
      TrackMappingResult(
        TrackMappingStatus.unavailable,
        reason: reason,
        realTrackCount: realTrackCount,
        candidateCount: 0,
        serverFields: serverFields,
        engineFields: engineFields,
        conflictFields: conflictFields,
      );
}

class TrackMapper {
  const TrackMapper();

  List<PlaybackTrack> fromPlan(PlaybackPlan plan, String type) {
    return fromStreams(plan.mediaStreams, type);
  }

  List<PlaybackTrack> fromStreams(
    Iterable<Map<String, dynamic>> streams,
    String type,
  ) {
    final normalizedType = type.toLowerCase();
    return streams
        .where(
          (stream) =>
              stream['Type']?.toString().toLowerCase() == normalizedType,
        )
        .map(_fromJson)
        .whereType<PlaybackTrack>()
        .toList(growable: false);
  }

  String? engineTrackId(
    PlaybackTrack serverTrack,
    List<EngineTrack> engineTracks,
  ) => match(serverTrack, engineTracks).engineId;

  TrackMappingResult match(
    PlaybackTrack? serverTrack,
    List<EngineTrack> engineTracks,
  ) {
    final tracks = engineTracks.where(isRealTrack).toList(growable: false);
    final server = <TrackMetadataField, Object?>{
      TrackMetadataField.language: _language(serverTrack?.language),
      TrackMetadataField.codec: _codec(serverTrack?.codec),
      TrackMetadataField.title: _text(serverTrack?.originalTitle),
      TrackMetadataField.channels: serverTrack?.channels,
    };
    final serverFields = {
      for (final entry in server.entries)
        if (entry.value != null) entry.key,
      if (_text(serverTrack?.displayTitle) != null)
        TrackMetadataField.displayTitle,
    };
    final engineFields = <TrackMetadataField>{};
    final conflicts = <TrackMetadataField>{};
    final matching = <EngineTrack>[];
    for (final track in tracks) {
      final fields = <TrackMetadataField, Object?>{
        TrackMetadataField.language: _language(track.language),
        TrackMetadataField.codec: _codec(track.codec),
        TrackMetadataField.title: _text(track.title),
        TrackMetadataField.channels: track.channels,
      };
      var evidence = false;
      var conflict = false;
      for (final field in fields.keys) {
        final actual = fields[field];
        if (actual != null) engineFields.add(field);
        final expected = server[field];
        if (expected == null || actual == null) continue;
        evidence = true;
        if (expected != actual) {
          conflicts.add(field);
          conflict = true;
        }
      }
      if (evidence && !conflict) matching.add(track);
    }
    final status = switch (matching.length) {
      0 => TrackMappingStatus.unavailable,
      1 => TrackMappingStatus.matched,
      _ => TrackMappingStatus.ambiguous,
    };
    final reason = serverTrack == null
        ? TrackMappingReason.missingServerTrack
        : tracks.isEmpty
        ? TrackMappingReason.noTracks
        : switch (status) {
            TrackMappingStatus.matched => TrackMappingReason.matched,
            TrackMappingStatus.ambiguous =>
              TrackMappingReason.multipleCandidates,
            TrackMappingStatus.unavailable =>
              conflicts.isEmpty
                  ? TrackMappingReason.insufficientMetadata
                  : TrackMappingReason.metadataConflict,
          };
    return TrackMappingResult(
      status,
      engineId: matching.length == 1 ? matching.single.id : null,
      reason: reason,
      realTrackCount: tracks.length,
      candidateCount: matching.length,
      serverFields: Set.unmodifiable(serverFields),
      engineFields: Set.unmodifiable(engineFields),
      conflictFields: Set.unmodifiable(conflicts),
    );
  }

  static bool isRealTrack(EngineTrack track) =>
      !{'', 'auto', 'no'}.contains(track.id.trim().toLowerCase());

  static String? _text(String? value) {
    final text = value?.trim().toLowerCase();
    return text == null || text.isEmpty || text == 'und' ? null : text;
  }

  static String? _language(String? value) => switch (_text(value)) {
    'eng' || 'en' => 'en',
    'chi' || 'zho' || 'zh' => 'zh',
    'jpn' || 'ja' => 'ja',
    'fra' || 'fre' || 'fr' => 'fr',
    'deu' || 'ger' || 'de' => 'de',
    'spa' || 'es' => 'es',
    'kor' || 'ko' => 'ko',
    final value => value,
  };

  // Restrict aliases to the same subtitle format. Do not collapse distinct
  // formats (for example ASS/SSA) or language regions/scripts to guess a track.
  static String? _codec(String? value) => switch (_text(value)) {
    'srt' || 'subrip' => 'subrip',
    final value => value,
  };

  PlaybackTrack? findByIndex(PlaybackPlan plan, String type, int index) =>
      fromPlan(plan, type).where((track) => track.index == index).firstOrNull;

  PlaybackTrack? _fromJson(Map<String, dynamic> json) {
    final index = _asInt(json['Index']);
    if (index == null) return null;
    return PlaybackTrack(
      index: index,
      type: json['Type']?.toString() ?? 'Unknown',
      title: json['Title']?.toString(),
      displayTitle: json['DisplayTitle']?.toString(),
      language: json['Language']?.toString(),
      codec: json['Codec']?.toString(),
      channels: _asInt(json['Channels']),
      isDefault: json['IsDefault'] as bool? ?? false,
      isForced: json['IsForced'] as bool? ?? false,
      isExternal: json['IsExternal'] as bool? ?? false,
      deliveryUrl: json['DeliveryUrl']?.toString(),
    );
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
