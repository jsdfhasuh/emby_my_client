import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';
import '../platform/platform_capabilities.dart';
import '../playback/track_mapper.dart';

bool usesAmbientIPadDetailLayout(
  PlatformCapabilities capabilities,
  Size viewport,
) =>
    capabilities.targetDeviceFamily == 'iPad' &&
    viewport.width > viewport.height &&
    viewport.shortestSide >= 600;

DateTime? estimatedPlaybackEndAt(EmbyItem item, DateTime now) {
  final ticks = item.runTimeTicks;
  if (ticks == null || ticks <= 0) return null;
  final runtime = Duration(microseconds: ticks ~/ 10);
  final remaining = runtime - item.resumePosition;
  return now.add(remaining.isNegative ? Duration.zero : remaining);
}

@immutable
class ItemDetailTechnicalPresentation {
  const ItemDetailTechnicalPresentation({
    this.source,
    this.container,
    this.video,
    this.audio,
    this.bitrate,
    this.subtitle,
  });

  final String? source;
  final String? container;
  final String? video;
  final String? audio;
  final String? bitrate;
  final String? subtitle;

  List<String> get facts => [
    source,
    container,
    video,
    audio,
    bitrate,
    subtitle,
  ].whereType<String>().toList(growable: false);

  bool get isEmpty => facts.isEmpty;
}

ItemDetailTechnicalPresentation technicalPresentationForItem(EmbyItem item) {
  final source = _selectSource(item.mediaSources);
  final streams = _streamsForItem(item, source);
  if (source == null && streams.isEmpty) {
    return const ItemDetailTechnicalPresentation();
  }
  final video = _firstStream(streams, 'Video');
  final audio = _selectAudioStream(source, streams);
  final subtitles = const TrackMapper().fromStreams(streams, 'subtitle');
  return ItemDetailTechnicalPresentation(
    source: _cleanText(source?.name),
    container: _cleanText(source?.container ?? item.container)?.toUpperCase(),
    video: _videoLabel(video),
    audio: _audioLabel(audio),
    bitrate: _bitrateLabel(
      source?.bitrate ?? _streamInt(video, const ['BitRate', 'Bitrate']),
    ),
    subtitle: streams.isEmpty
        ? null
        : subtitles.isEmpty
        ? '无字幕'
        : '字幕 ${subtitles.length} 条',
  );
}

List<PlaybackTrack> subtitleTracksForItem(EmbyItem item) {
  final source = _selectSource(item.mediaSources);
  return const TrackMapper().fromStreams(
    _streamsForItem(item, source),
    'subtitle',
  );
}

int? defaultSubtitleStreamIndexForItem(EmbyItem item) {
  final source = _selectSource(item.mediaSources);
  final sourceDefault = source?.defaultSubtitleStreamIndex;
  if (sourceDefault != null) return sourceDefault;
  for (final track in subtitleTracksForItem(item)) {
    if (track.isDefault) return track.index;
  }
  return null;
}

PlaybackMediaSource? _selectSource(List<PlaybackMediaSource> sources) {
  if (sources.isEmpty) return null;
  for (final source in sources) {
    if (source.supportsDirectPlay ||
        source.supportsDirectStream ||
        source.supportsTranscoding) {
      return source;
    }
  }
  return sources.first;
}

List<Map<String, dynamic>> _streamsForItem(
  EmbyItem item,
  PlaybackMediaSource? source,
) => mergeMediaStreams(source?.mediaStreams ?? const [], item.mediaStreams);

Map<String, dynamic>? _selectAudioStream(
  PlaybackMediaSource? source,
  List<Map<String, dynamic>> streams,
) {
  final audio = streams
      .where((stream) => _streamType(stream) == 'audio')
      .toList(growable: false);
  if (audio.isEmpty) return null;
  final defaultIndex = source?.defaultAudioStreamIndex;
  if (defaultIndex != null) {
    for (final stream in audio) {
      if (_streamInt(stream, const ['Index']) == defaultIndex) return stream;
    }
  }
  for (final stream in audio) {
    if (stream['IsDefault'] == true) return stream;
  }
  return audio.first;
}

Map<String, dynamic>? _firstStream(
  List<Map<String, dynamic>> streams,
  String type,
) {
  final expected = type.toLowerCase();
  for (final stream in streams) {
    if (_streamType(stream) == expected) return stream;
  }
  return null;
}

String _streamType(Map<String, dynamic> stream) =>
    _cleanText(stream['Type'])?.toLowerCase() ?? '';

String? _videoLabel(Map<String, dynamic>? stream) {
  if (stream == null) return null;
  final codec = _cleanText(stream['Codec'])?.toUpperCase();
  final width = _streamInt(stream, const ['Width']);
  final height = _streamInt(stream, const ['Height']);
  final resolution = width != null && width > 0 && height != null && height > 0
      ? '$width×$height'
      : null;
  return _joinFacts([codec, resolution]);
}

String? _audioLabel(Map<String, dynamic>? stream) {
  if (stream == null) return null;
  final codec = _cleanText(stream['Codec'])?.toUpperCase();
  final layout = _cleanText(stream['ChannelLayout']);
  final channels = _streamInt(stream, const ['Channels']);
  final channelLabel =
      layout ?? (channels != null && channels > 0 ? '$channels 声道' : null);
  final language = _cleanText(stream['Language']);
  return _joinFacts([codec, channelLabel, language]);
}

String? _bitrateLabel(int? bitrate) {
  if (bitrate == null || bitrate <= 0) return null;
  if (bitrate >= 1000000) {
    final mbps = bitrate / 1000000;
    final value = mbps >= 10
        ? mbps.toStringAsFixed(0)
        : mbps.toStringAsFixed(1);
    return '$value Mbps';
  }
  return '${(bitrate / 1000).round()} kbps';
}

String? _joinFacts(Iterable<String?> values) {
  final facts = values.whereType<String>().toList(growable: false);
  return facts.isEmpty ? null : facts.join(' · ');
}

String? _cleanText(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int? _streamInt(Map<String, dynamic>? stream, List<String> keys) {
  if (stream == null) return null;
  for (final key in keys) {
    final value = stream[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}
