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

class TrackMapper {
  const TrackMapper();

  List<PlaybackTrack> fromPlan(PlaybackPlan plan, String type) {
    final normalizedType = type.toLowerCase();
    return plan.mediaStreams
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
  ) {
    for (final engineTrack in engineTracks) {
      if (engineTrack.id == serverTrack.index.toString()) {
        return engineTrack.id;
      }
    }

    final matching = engineTracks
        .where((engineTrack) {
          final languageMatches =
              serverTrack.language == null ||
              engineTrack.language == null ||
              serverTrack.language!.toLowerCase() ==
                  engineTrack.language!.toLowerCase();
          final codecMatches =
              serverTrack.codec == null ||
              engineTrack.codec == null ||
              serverTrack.codec!.toLowerCase() ==
                  engineTrack.codec!.toLowerCase();
          final titleMatches =
              serverTrack.title == null ||
              engineTrack.title == null ||
              serverTrack.title!.toLowerCase() ==
                  engineTrack.title!.toLowerCase();
          return languageMatches && codecMatches && titleMatches;
        })
        .toList(growable: false);
    return matching.length == 1 ? matching.single.id : null;
  }

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
