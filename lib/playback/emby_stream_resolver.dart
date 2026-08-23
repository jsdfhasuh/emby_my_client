import '../data/emby_api.dart';
import '../models/emby_models.dart';

abstract interface class PlaybackStreamResolver {
  bool get canForceTranscode;

  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  });

  Uri resolveExternalUrl(String rawUrl);
}

class EmbyStreamResolver implements PlaybackStreamResolver {
  const EmbyStreamResolver(this.api);

  final EmbyApi api;

  @override
  bool get canForceTranscode => true;

  @override
  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) => api.getPlaybackPlan(
    item,
    mediaSourceId: mediaSourceId,
    audioStreamIndex: audioStreamIndex,
    subtitleStreamIndex: subtitleStreamIndex,
    subtitleDisabled: subtitleDisabled,
    maxStreamingBitrate: maxStreamingBitrate,
    forceTranscode: forceTranscode,
  );

  @override
  Uri resolveExternalUrl(String rawUrl) => api.resolveMediaUrl(rawUrl);
}
