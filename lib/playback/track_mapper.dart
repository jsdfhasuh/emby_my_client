import '../models/emby_models.dart';
import 'playback_engine.dart';

enum SubtitleDelivery { unspecified, external, embed, encode, hls, unsupported }

enum SubtitleFormat { missing, other, srt, ass, ssa, vtt, webvtt }

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
    this.deliveryMethod,
    this.format,
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
  final String? deliveryMethod;
  final String? format;
  bool usesDeliveredFormat(PlaybackPlan plan) =>
      plan.method != PlayMethod.directPlay &&
      delivery == SubtitleDelivery.embed &&
      format?.trim().isNotEmpty == true;

  /// An explicit Embed response may convert the source subtitle codec. Match
  /// its declared output format against the current output, never its index.
  PlaybackTrack mappingTrack(PlaybackPlan plan) => usesDeliveredFormat(plan)
      ? PlaybackTrack(
          index: index,
          type: type,
          title: originalTitle,
          displayTitle: displayTitle,
          language: language,
          codec: format?.trim().toLowerCase() == 'vtt' ? 'webvtt' : format,
          channels: channels,
          isDefault: isDefault,
          isForced: isForced,
          deliveryMethod: deliveryMethod,
          format: format,
          deliveryUrl: deliveryUrl,
        )
      : this;
  SubtitleDelivery get delivery => switch (deliveryMethod?.toLowerCase()) {
    null || '' => SubtitleDelivery.unspecified,
    'external' => SubtitleDelivery.external,
    'embed' => SubtitleDelivery.embed,
    'encode' => SubtitleDelivery.encode,
    'hls' => SubtitleDelivery.hls,
    _ => SubtitleDelivery.unsupported,
  };
  SubtitleFormat get safeFormat =>
      SubtitleFormat.values
          .where((value) => value.name == format?.toLowerCase())
          .firstOrNull ??
      (format == null ? SubtitleFormat.missing : SubtitleFormat.other);
  SubtitleDelivery deliveryFor(PlaybackPlan plan) {
    // Downloaded metadata describes the server source, not the local file.
    if (plan.transportKind == PlaybackTransportKind.offlineLocal) {
      return isExternal || delivery == SubtitleDelivery.external
          ? SubtitleDelivery.external
          : SubtitleDelivery.embed;
    }
    if (delivery != SubtitleDelivery.unspecified) return delivery;
    if (plan.method == PlayMethod.directPlay) {
      return isExternal ? SubtitleDelivery.external : SubtitleDelivery.embed;
    }
    return SubtitleDelivery.unspecified;
  }
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

enum TrackFieldComparison {
  same,
  conflict,
  missingLeft,
  missingRight,
  missingBoth,
}

/// Allowlisted diagnostic vocabulary. Arbitrary codec strings remain private.
enum TrackCodecLabel {
  missing,
  other,
  ass,
  ssa,
  assSsa,
  srt,
  subrip,
  pgs,
  hdmvPgsSubtitle,
  dvdSubtitle,
  webvtt,
  movText,
  text,
}

enum TrackCodecContext { strict, mpvMatroskaEmbedded }

/// Only fixed comparisons and codec labels; never IDs or free-form metadata.
class TrackCandidateEvidence {
  const TrackCandidateEvidence({
    required this.fields,
    required this.eligible,
    required this.nativeCodec,
    required this.serverCodecFamily,
    required this.nativeCodecFamily,
    required this.codecContext,
  });
  final Map<TrackMetadataField, TrackFieldComparison> fields;
  final bool eligible;
  final TrackCodecLabel nativeCodec;
  final TrackCodecLabel serverCodecFamily;
  final TrackCodecLabel nativeCodecFamily;
  final TrackCodecContext codecContext;
}

enum TrackSourceLookup { missing, unique, ambiguous }

enum TrackPlanInput { file, http, other }

class TrackSourceEvidence {
  const TrackSourceEvidence({
    required this.transport,
    required this.input,
    required this.sourceLookup,
    required this.streamLookup,
    required this.planSourceFields,
  });
  final PlaybackTransportKind transport;
  final TrackPlanInput input;
  final TrackSourceLookup sourceLookup;
  final TrackSourceLookup streamLookup;
  // Plan metadata compared with the selected source's metadata. This does not
  // establish that either metadata snapshot describes the native input file.
  final Map<TrackMetadataField, TrackFieldComparison> planSourceFields;
}

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
    this.trackEvidence = const [],
    this.serverCodec = TrackCodecLabel.missing,
  });
  final TrackMappingStatus status;
  final String? engineId;
  final TrackMappingReason reason;
  final int realTrackCount;
  final int candidateCount;
  final Set<TrackMetadataField> serverFields;
  final Set<TrackMetadataField> engineFields;
  final Set<TrackMetadataField> conflictFields;
  final List<TrackCandidateEvidence> trackEvidence;
  final TrackCodecLabel serverCodec;

  TrackMappingResult asUnavailable(TrackMappingReason reason) =>
      TrackMappingResult(
        TrackMappingStatus.unavailable,
        reason: reason,
        realTrackCount: realTrackCount,
        candidateCount: 0,
        serverFields: serverFields,
        engineFields: engineFields,
        conflictFields: conflictFields,
        trackEvidence: trackEvidence,
        serverCodec: serverCodec,
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
    List<EngineTrack> engineTracks, {
    SubtitleMappingContext context = const SubtitleMappingContext.unknown(),
  }) {
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
    final trackEvidence = <TrackCandidateEvidence>[];
    for (final track in tracks) {
      final assSsa =
          serverTrack?.type.toLowerCase() == 'subtitle' &&
          serverTrack?.isExternal == false &&
          context.isMpvMatroskaEmbedded(track);
      final expectedCodec = _codec(serverTrack?.codec, assSsa: assSsa);
      final fields = <TrackMetadataField, Object?>{
        TrackMetadataField.language: _language(track.language),
        TrackMetadataField.codec: _codec(track.codec, assSsa: assSsa),
        TrackMetadataField.title: _text(track.title),
        TrackMetadataField.channels: track.channels,
      };
      var evidence = false;
      var conflict = false;
      final comparisons = <TrackMetadataField, TrackFieldComparison>{};
      for (final field in fields.keys) {
        final actual = fields[field];
        if (actual != null) engineFields.add(field);
        final expected = field == TrackMetadataField.codec
            ? expectedCodec
            : server[field];
        comparisons[field] = _compare(expected, actual);
        if (expected == null || actual == null) continue;
        evidence = true;
        if (expected != actual) {
          conflicts.add(field);
          conflict = true;
        }
      }
      if (evidence && !conflict) matching.add(track);
      trackEvidence.add(
        TrackCandidateEvidence(
          fields: Map.unmodifiable(comparisons),
          eligible: evidence && !conflict,
          nativeCodec: _codecLabel(_text(track.codec)),
          serverCodecFamily: _codecLabel(expectedCodec),
          nativeCodecFamily: _codecLabel(fields[TrackMetadataField.codec]),
          codecContext: assSsa
              ? TrackCodecContext.mpvMatroskaEmbedded
              : TrackCodecContext.strict,
        ),
      );
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
      trackEvidence: List.unmodifiable(trackEvidence),
      serverCodec: _codecLabel(_text(serverTrack?.codec)),
    );
  }

  TrackSourceEvidence sourceEvidence(PlaybackPlan plan, int streamIndex) {
    final sources = plan.availableMediaSources
        .where((source) => source.id == plan.mediaSourceId)
        .toList();
    final streams = sources.length == 1
        ? fromStreams(
            sources.single.mediaStreams,
            'subtitle',
          ).where((track) => track.index == streamIndex).toList()
        : <PlaybackTrack>[];
    final planTrack = findByIndex(plan, 'subtitle', streamIndex);
    final sourceTrack = streams.length == 1 ? streams.single : null;
    Map<TrackMetadataField, Object?> fields(PlaybackTrack? track) => {
      TrackMetadataField.language: _language(track?.language),
      TrackMetadataField.codec: _codec(track?.codec),
      TrackMetadataField.title: _text(track?.originalTitle),
      TrackMetadataField.channels: track?.channels,
    };
    final expected = fields(planTrack);
    final actual = fields(sourceTrack);
    TrackSourceLookup lookup(int count) => count == 0
        ? TrackSourceLookup.missing
        : count == 1
        ? TrackSourceLookup.unique
        : TrackSourceLookup.ambiguous;
    return TrackSourceEvidence(
      transport: plan.transportKind,
      input: plan.uri.scheme == 'file'
          ? TrackPlanInput.file
          : {'http', 'https'}.contains(plan.uri.scheme)
          ? TrackPlanInput.http
          : TrackPlanInput.other,
      sourceLookup: lookup(sources.length),
      streamLookup: lookup(streams.length),
      planSourceFields: Map.unmodifiable({
        for (final field in expected.keys)
          field: _compare(expected[field], actual[field]),
      }),
    );
  }

  static TrackFieldComparison _compare(Object? expected, Object? actual) =>
      expected == null
      ? actual == null
            ? TrackFieldComparison.missingBoth
            : TrackFieldComparison.missingLeft
      : actual == null
      ? TrackFieldComparison.missingRight
      : expected == actual
      ? TrackFieldComparison.same
      : TrackFieldComparison.conflict;

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

  // ASS/SSA compatibility is only native Matroska track identity, not format
  // equivalence for conversion, external loading, audio or other demuxers.
  // mpv v0.36.0 demux/demux_mkv.c:1705-1710 maps both tags to "ass".
  static Object? _codec(String? value, {bool assSsa = false}) =>
      switch (_text(value)) {
        'srt' || 'subrip' => 'subrip',
        'ass' || 'ssa' when assSsa => TrackCodecLabel.assSsa,
        final value => value,
      };

  static TrackCodecLabel _codecLabel(Object? value) => switch (value) {
    null => TrackCodecLabel.missing,
    TrackCodecLabel.assSsa => TrackCodecLabel.assSsa,
    'ass' => TrackCodecLabel.ass,
    'ssa' => TrackCodecLabel.ssa,
    'srt' => TrackCodecLabel.srt,
    'subrip' => TrackCodecLabel.subrip,
    'pgs' => TrackCodecLabel.pgs,
    'hdmv_pgs_subtitle' => TrackCodecLabel.hdmvPgsSubtitle,
    'dvd_subtitle' => TrackCodecLabel.dvdSubtitle,
    'webvtt' => TrackCodecLabel.webvtt,
    'mov_text' => TrackCodecLabel.movText,
    'text' => TrackCodecLabel.text,
    _ => TrackCodecLabel.other,
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
      deliveryMethod: json['DeliveryMethod']?.toString(),
      format: json['Format']?.toString(),
    );
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
