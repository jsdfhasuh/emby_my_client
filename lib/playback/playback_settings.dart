class PlaybackSettings {
  const PlaybackSettings({
    this.maxStreamingBitrate = 120000000,
    this.seekBackwardSeconds = 10,
    this.seekForwardSeconds = 10,
    this.playbackRate = 1,
    this.videoFit = 'contain',
    this.subtitleDelayMilliseconds = 0,
    this.audioDelayMilliseconds = 0,
    this.subtitleFontSize = 42,
    this.subtitleColor = 0xFFFFFFFF,
    this.subtitleOutlineColor = 0xFF000000,
    this.subtitlePosition = 100,
  });

  final int maxStreamingBitrate;
  final int seekBackwardSeconds;
  final int seekForwardSeconds;
  final double playbackRate;
  final String videoFit;
  final int subtitleDelayMilliseconds;
  final int audioDelayMilliseconds;
  final double subtitleFontSize;
  final int subtitleColor;
  final int subtitleOutlineColor;
  final int subtitlePosition;

  PlaybackSettings copyWith({
    int? maxStreamingBitrate,
    int? seekBackwardSeconds,
    int? seekForwardSeconds,
    double? playbackRate,
    String? videoFit,
    int? subtitleDelayMilliseconds,
    int? audioDelayMilliseconds,
    double? subtitleFontSize,
    int? subtitleColor,
    int? subtitleOutlineColor,
    int? subtitlePosition,
  }) => PlaybackSettings(
    maxStreamingBitrate: maxStreamingBitrate ?? this.maxStreamingBitrate,
    seekBackwardSeconds: seekBackwardSeconds ?? this.seekBackwardSeconds,
    seekForwardSeconds: seekForwardSeconds ?? this.seekForwardSeconds,
    playbackRate: playbackRate ?? this.playbackRate,
    videoFit: videoFit ?? this.videoFit,
    subtitleDelayMilliseconds:
        subtitleDelayMilliseconds ?? this.subtitleDelayMilliseconds,
    audioDelayMilliseconds:
        audioDelayMilliseconds ?? this.audioDelayMilliseconds,
    subtitleFontSize: subtitleFontSize ?? this.subtitleFontSize,
    subtitleColor: subtitleColor ?? this.subtitleColor,
    subtitleOutlineColor: subtitleOutlineColor ?? this.subtitleOutlineColor,
    subtitlePosition: subtitlePosition ?? this.subtitlePosition,
  );

  factory PlaybackSettings.fromJson(
    Map<String, dynamic> json,
  ) => PlaybackSettings(
    maxStreamingBitrate: _asInt(json['maxStreamingBitrate']) ?? 120000000,
    seekBackwardSeconds: _asInt(json['seekBackwardSeconds']) ?? 10,
    seekForwardSeconds: _asInt(json['seekForwardSeconds']) ?? 10,
    playbackRate: _asDouble(json['playbackRate']) ?? 1,
    videoFit: json['videoFit']?.toString() ?? 'contain',
    subtitleDelayMilliseconds: _asInt(json['subtitleDelayMilliseconds']) ?? 0,
    audioDelayMilliseconds: _asInt(json['audioDelayMilliseconds']) ?? 0,
    subtitleFontSize: _asDouble(json['subtitleFontSize']) ?? 42,
    subtitleColor: _asInt(json['subtitleColor']) ?? 0xFFFFFFFF,
    subtitleOutlineColor: _asInt(json['subtitleOutlineColor']) ?? 0xFF000000,
    subtitlePosition: _asInt(json['subtitlePosition']) ?? 100,
  );

  Map<String, dynamic> toJson() => {
    'maxStreamingBitrate': maxStreamingBitrate,
    'seekBackwardSeconds': seekBackwardSeconds,
    'seekForwardSeconds': seekForwardSeconds,
    'playbackRate': playbackRate,
    'videoFit': videoFit,
    'subtitleDelayMilliseconds': subtitleDelayMilliseconds,
    'audioDelayMilliseconds': audioDelayMilliseconds,
    'subtitleFontSize': subtitleFontSize,
    'subtitleColor': subtitleColor,
    'subtitleOutlineColor': subtitleOutlineColor,
    'subtitlePosition': subtitlePosition,
  };
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _asDouble(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
