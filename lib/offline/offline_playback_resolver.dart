import 'dart:io';

import '../downloads/download_models.dart';
import '../models/emby_models.dart';
import '../playback/emby_stream_resolver.dart';

class OfflinePlaybackResolver implements PlaybackStreamResolver {
  const OfflinePlaybackResolver(this.offlineItem);

  final OfflineMediaItem offlineItem;

  @override
  bool get canForceTranscode => false;

  @override
  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async {
    if (forceTranscode) {
      throw StateError('Offline media cannot be transcoded');
    }
    if (item.id != offlineItem.itemId) {
      throw StateError('Offline item identity does not match playback item');
    }
    final file = File(offlineItem.localMediaPath);
    if (!await file.exists() || await file.length() <= 0) {
      throw const FileSystemException('Offline media file is missing');
    }
    final defaultSubtitleStreamIndex = _defaultSubtitleStreamIndex(
      offlineItem.metadata.mediaStreams,
    );
    final resolvedSubtitleStreamIndex = subtitleDisabled
        ? null
        : subtitleStreamIndex ?? defaultSubtitleStreamIndex;
    final source = PlaybackMediaSource(
      id: offlineItem.mediaSourceId,
      supportsDirectPlay: true,
      supportsDirectStream: false,
      supportsTranscoding: false,
      mediaStreams: offlineItem.metadata.mediaStreams,
      transcodingReasons: const [],
      container: offlineItem.metadata.container,
      defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
    );
    return PlaybackPlan(
      uri: file.uri,
      mediaSourceId: offlineItem.mediaSourceId,
      playSessionId: null,
      method: PlayMethod.directPlay,
      usesServerAuthentication: false,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: resolvedSubtitleStreamIndex,
      subtitleDisabled: subtitleDisabled,
      container: offlineItem.metadata.container,
      sourceProtocol: 'File',
      duration: Duration(microseconds: (item.runTimeTicks ?? 0) ~/ 10),
      transportKind: PlaybackTransportKind.offlineLocal,
      mediaStreams: offlineItem.metadata.mediaStreams,
      transcodingReasons: const [],
      availableMediaSources: [source],
    );
  }

  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.file(rawUrl);
}

int? _defaultSubtitleStreamIndex(List<Map<String, dynamic>> streams) {
  for (final stream in streams) {
    if (stream['Type']?.toString().toLowerCase() != 'subtitle' ||
        stream['IsDefault'] != true) {
      continue;
    }
    final value = stream['Index'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return null;
}
