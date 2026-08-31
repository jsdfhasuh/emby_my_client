import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'cache/playback_cache_storage.dart';
import 'emby_stream_resolver.dart';
import 'playback_controller.dart';
import 'playback_diagnostics_test_overrides.dart';
import 'playback_engine.dart';
import 'playback_operation_coordinator.dart';
import 'playback_session_reporter.dart';
import 'playback_settings.dart';

abstract final class PlaybackSessionBootstrap {
  static PlaybackController createOnlineController({
    required EmbyApi api,
    required EmbyItem item,
    required PlaybackEngine engine,
    required PlaybackItemSession session,
    required PlaybackSettings settings,
    PlaybackEngineRecreator? engineRecreator,
    PlaybackEngineDisposalUnconfirmed? onEngineDisposalUnconfirmed,
    PlaybackNativeOperationTimeouts nativeOperationTimeouts =
        const PlaybackNativeOperationTimeouts(),
    PlaybackCacheStorage? cacheStorage,
    PlaybackDiagnosticsTestOverrides? testOverrides,
  }) => PlaybackController(
    item: item,
    engine: engine,
    resolver: EmbyStreamResolver(api),
    reporter: PlaybackSessionReporter(api: api, item: item),
    playbackHeaders: api.playbackHeaders,
    engineRecreator: engineRecreator,
    onEngineDisposalUnconfirmed: onEngineDisposalUnconfirmed,
    session: session,
    cacheSettings: settings.cache,
    cacheStorage: cacheStorage,
    testOverrides: testOverrides,
    maxStreamingBitrate: settings.maxStreamingBitrate,
    openTimeout: nativeOperationTimeouts.open,
    seekCallTimeout: nativeOperationTimeouts.seek,
    playPauseTimeout: nativeOperationTimeouts.play,
    propertyWriteTimeout: nativeOperationTimeouts.propertyWrite,
    lifecycleQuiesceTimeout: nativeOperationTimeouts.lifecycleQuiesce,
    retirementQuiesceTimeout: nativeOperationTimeouts.retirementQuiesce,
    shutdownBarrierTimeout: nativeOperationTimeouts.shutdownBarrier,
    stopTimeout: nativeOperationTimeouts.stop,
    disposeTimeout: nativeOperationTimeouts.dispose,
  );

  static Future<void> configureAndStart({
    required PlaybackController controller,
    required PlaybackSettings settings,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    Duration? resumePosition,
    bool playAfterReady = true,
  }) async {
    await controller.setPlaybackRate(settings.playbackRate);
    await controller.setAudioDelay(
      Duration(milliseconds: settings.audioDelayMilliseconds),
    );
    await controller.setSubtitleDelay(
      Duration(milliseconds: settings.subtitleDelayMilliseconds),
    );
    await controller.configureSubtitleStyle(
      fontSize: settings.subtitleFontSize,
      color: settings.subtitleColor,
      outlineColor: settings.subtitleOutlineColor,
      position: settings.subtitlePosition,
    );
    await controller.start(
      mediaSourceId: mediaSourceId,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      subtitleDisabled: subtitleDisabled,
      resumePosition: resumePosition,
      playAfterReady: playAfterReady,
    );
  }
}
