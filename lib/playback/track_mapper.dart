import '../models/emby_models.dart';
import 'playback_engine.dart';

class PlaybackTrack {
  const PlaybackTrack({
    required this.index,
    required this.type,
    this.title,
    this.language,
    this.codec,
    this.channels,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.deliveryUrl,
  });

  final int index;
  final String type;
  final String? title;
  final String? language;
  final String? codec;
  final int? channels;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;
  final String? deliveryUrl;
}

enum TrackMappingStatus { matched, unavailable, ambiguous }

class TrackMappingResult {
  const TrackMappingResult(this.status, [this.engineId]);
  final TrackMappingStatus status;
  final String? engineId;
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
    PlaybackTrack serverTrack,
    List<EngineTrack> engineTracks,
  ) {
    final matching = engineTracks
        .where((engineTrack) {
          if (engineTrack.id == 'auto' || engineTrack.id == 'no') return false;
          var evidence = false;
          for (final pair in [
            (_language(serverTrack.language), _language(engineTrack.language)),
            (_text(serverTrack.codec), _text(engineTrack.codec)),
            (_text(serverTrack.title), _text(engineTrack.title)),
            (serverTrack.channels, engineTrack.channels),
          ]) {
            if (pair.$1 == null || pair.$2 == null) continue;
            if (pair.$1 != pair.$2) return false;
            evidence = true;
          }
          return evidence;
        })
        .toList(growable: false);
    return switch (matching.length) {
      0 => const TrackMappingResult(TrackMappingStatus.unavailable),
      1 => TrackMappingResult(TrackMappingStatus.matched, matching.single.id),
      _ => const TrackMappingResult(TrackMappingStatus.ambiguous),
    };
  }

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

  PlaybackTrack? findByIndex(PlaybackPlan plan, String type, int index) =>
      fromPlan(plan, type).where((track) => track.index == index).firstOrNull;

  PlaybackTrack? _fromJson(Map<String, dynamic> json) {
    final index = _asInt(json['Index']);
    if (index == null) return null;
    return PlaybackTrack(
      index: index,
      type: json['Type']?.toString() ?? 'Unknown',
      title: json['DisplayTitle']?.toString() ?? json['Title']?.toString(),
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
