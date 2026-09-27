import 'package:dio/dio.dart';
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
  EmbyStreamResolver(this.api);

  final EmbyApi api;
  final Object _itemSession = Object();
  final Set<String> _strmSources = {};
  CancelToken? _pending;
  int _generation = 0;
  bool _direct = false;

  void cancelPending() {
    _generation++;
    _pending?.cancel('playback_cancelled');
  }

  @override
  bool get canForceTranscode => !_direct;

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
    cancelPending();
    final generation = _generation;
    final cancellation = _pending = CancelToken();
    final plan = await api.resolveOnlinePlayback(
      item,
      itemSession: _itemSession,
      generation: generation,
      cancelToken: cancellation,
      isCurrent: () => generation == _generation,
      knownStrm: _strmSources.contains('${item.id}:$mediaSourceId'),
      mediaSourceId: mediaSourceId,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      subtitleDisabled: subtitleDisabled,
      maxStreamingBitrate: maxStreamingBitrate,
      forceTranscode: forceTranscode,
    );
    if (generation != _generation) throw StateError('Playback cancelled');
    _direct = plan.isSourceDirect;
    if (_direct) _strmSources.add('${item.id}:${plan.mediaSourceId}');
    return plan;
  }

  @override
  Uri resolveExternalUrl(String rawUrl) => api.resolveMediaUrl(rawUrl);
}
