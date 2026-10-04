import '../core/strm_diagnostics.dart';
import 'source_input_failure.dart';
import 'strm_direct_play_policy.dart';
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
  EmbyStreamResolver(this.api, {StrmTrace? trace})
    : trace = trace ?? StrmTrace();
  final StrmTrace trace;

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
    final watch = Stopwatch()..start();
    trace.emit('strm_resolve', {'outcome': 'started', 'task': generation});
    try {
      final plan = await api.resolveOnlinePlayback(
        trace: trace,
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
      trace.emit('strm_resolve', {
        'outcome': 'succeeded',
        'task': generation,
        'elapsedMs': watch.elapsedMilliseconds,
        'route': plan.isSourceDirect ? 'source_direct' : 'server',
        'inputMode': plan.usesControlledInput ? 'stream_cb' : 'player',
        'fixedSource': true,
      });
      return plan;
    } catch (error, stack) {
      final cancelled = cancellation.isCancelled || generation != _generation;
      final reason = error is PlaybackResolveException
          ? switch (error.failure) {
              PlaybackResolveFailure.sourceIdentityConflict =>
                'identity_conflict',
              PlaybackResolveFailure.sourceMissing => 'source_missing',
              PlaybackResolveFailure.sourceIdentityUnresolved => 'unresolved',
              _ => 'unknown',
            }
          : error is EmbyApiException
          ? 'server_error'
          : 'unknown';
      SourceInputFailure(
        error: SourceInputException(
          cancelled ? 'cancelled' : reason,
          cause: error,
          stackTrace: stack,
          stage: error is PlaybackResolveException
              ? 'classification'
              : 'metadata',
          httpStatus: error is EmbyApiException ? error.statusCode : null,
        ),
        trace: trace,
        openAttempt: trace.currentAttempt,
        request: 0,
        stale: generation != _generation,
      ).record();
      trace.emit('strm_resolve', {
        'outcome': cancelled ? 'cancelled' : 'failed',
        'task': generation,
        'stale': generation != _generation,
        'cancelled': cancelled,
        'conflict':
            error is PlaybackResolveException &&
            error.failure == PlaybackResolveFailure.sourceIdentityConflict,
        'elapsedMs': watch.elapsedMilliseconds,
      });
      rethrow;
    }
  }

  @override
  Uri resolveExternalUrl(String rawUrl) => api.resolveMediaUrl(rawUrl);
}
