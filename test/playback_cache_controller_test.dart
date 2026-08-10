import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cache is resolved and applied before open then cleaned after dispose',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(events: events);
      final storage = _CacheStorage(events);
      final controller = _controller(engine: engine, storage: storage);

      await controller.start();

      expect(events.take(4), ['probe', 'prepare', 'configure', 'open']);
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.cacheRuntimeMode, PlaybackCacheRuntimeMode.disk);
      expect(
        controller.state.cacheProfile?.runtimeMode,
        PlaybackCacheRuntimeMode.disk,
      );
      await controller.shutdown();
      expect(events.indexOf('stop'), lessThan(events.indexOf('dispose')));
      expect(events.indexOf('dispose'), lessThan(events.indexOf('cleanup')));
    },
  );

  test(
    'cache creation failure remains nonfatal and confirms memory mode',
    () async {
      final events = <String>[];
      final engine = _CacheEngine(
        events: events,
        snapshot: const PlaybackCacheEngineSnapshot(
          fileCacheBytes: null,
          rawInputRateBytesPerSecond: null,
          seekableRanges: [],
          pausedForCache: false,
          cacheBufferingPercent: null,
          cacheOnDisk: false,
        ),
      );
      final controller = _controller(
        engine: engine,
        storage: _CacheStorage(events),
      );
      await controller.start();

      engine.logController.add('Failed to create file cache');
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.diskCacheFailureObserved, isTrue);
      expect(
        controller.state.cacheRuntimeMode,
        PlaybackCacheRuntimeMode.memoryFallback,
      );
      expect(
        controller.state.cacheFallbackReason,
        PlaybackCacheFallbackReason.mpvCacheCreateFailed,
      );
      await controller.shutdown();
    },
  );

  test('profile recreation preserves the logical item session', () async {
    final events = <String>[];
    final first = _CacheEngine(
      events: events,
      requireRecreationAfterOpen: true,
    );
    final second = _CacheEngine(events: events);
    final storage = _CacheStorage(events);
    final session = PlaybackItemSession.forTest('stable-session');
    final recreatedSessions = <PlaybackItemSessionId>[];
    final controller = _controller(
      engine: first,
      storage: storage,
      session: session,
      engineRecreator: (itemSession) async {
        recreatedSessions.add(itemSession.id);
        return second;
      },
    );
    await controller.start();
    first.positionController.add(const Duration(minutes: 5));
    first.playingController.add(true);

    await controller.setMaximumBitrate(10000000);

    expect(recreatedSessions, [session.id]);
    expect(controller.sessionId, session.id);
    expect(second.openCalls, 1);
    expect(controller.state.phase, PlaybackPhase.ready);
    await controller.shutdown();
  });
}

PlaybackController _controller({
  required _CacheEngine engine,
  required _CacheStorage storage,
  PlaybackItemSession? session,
  PlaybackEngineRecreator? engineRecreator,
}) => PlaybackController(
  item: _item,
  engine: engine,
  resolver: const _Resolver(),
  reporter: _Reporter(),
  playbackHeaders: const {},
  session: session,
  engineRecreator: engineRecreator,
  cacheStorage: storage,
  cacheSettings: const PlaybackCacheSettings(
    mode: PlaybackCacheMode.balanced,
    reservedFreeBytes: 2 << 30,
  ),
  progressInterval: const Duration(hours: 1),
);

class _CacheStorage implements PlaybackCacheStorage {
  _CacheStorage(this.events);

  final List<String> events;
  int prepares = 0;

  @override
  Future<void> cleanupNonActiveMarkedSessions() async {}

  @override
  Future<void> cleanupSession(PlaybackCacheSession session) async {
    events.add('cleanup');
  }

  @override
  Future<int?> freeBytesFor(Directory directory) async => 20 << 30;

  @override
  Future<PlaybackCacheStorageSnapshot> prepareSession() async {
    prepares++;
    events.add('prepare');
    return PlaybackCacheStorageSnapshot.available(
      session: PlaybackCacheSession(
        directory: Directory.systemTemp,
        nonce: '0123456789abcdef0123456789abcdef',
      ),
      freeBytes: 20 << 30,
    );
  }
}

class _CacheEngine implements PlaybackEngine, PlaybackCacheEngine {
  _CacheEngine({
    required this.events,
    this.snapshot,
    this.requireRecreationAfterOpen = false,
  });

  final List<String> events;
  final PlaybackCacheEngineSnapshot? snapshot;
  final bool requireRecreationAfterOpen;
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<String>.broadcast(sync: true);
  final logController = StreamController<String>.broadcast(sync: true);
  final audioController = StreamController<List<EngineTrack>>.broadcast(
    sync: true,
  );
  final subtitleController = StreamController<List<EngineTrack>>.broadcast(
    sync: true,
  );
  int openCalls = 0;

  @override
  Stream<List<EngineTrack>> get audioTracksStream => audioController.stream;
  @override
  Stream<Duration> get bufferStream => bufferController.stream;
  @override
  Stream<bool> get bufferingStream => bufferingController.stream;
  @override
  Stream<bool> get completedStream => completedController.stream;
  @override
  Stream<Duration> get durationStream => durationController.stream;
  @override
  Stream<String> get errorStream => errorController.stream;
  @override
  Stream<String> get logStream => logController.stream;
  @override
  Stream<bool> get playingStream => playingController.stream;
  @override
  Stream<Duration> get positionStream => positionController.stream;
  @override
  Stream<List<EngineTrack>> get subtitleTracksStream =>
      subtitleController.stream;

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) async {
    events.add('configure');
    if (requireRecreationAfterOpen && openCalls > 0) {
      return PlaybackCacheApplyResult(
        requestedMode: profile.runtimeMode,
        actualMode: PlaybackCacheRuntimeMode.unconfirmed,
        fallbackReason: PlaybackCacheFallbackReason.actualModeUnconfirmed,
        requiresPlayerRecreation: true,
        readBack: const {},
      );
    }
    return PlaybackCacheApplyResult(
      requestedMode: profile.runtimeMode,
      actualMode: profile.runtimeMode,
      fallbackReason: profile.fallbackReason,
      requiresPlayerRecreation: false,
      readBack: const {'cache-on-disk': 'yes'},
    );
  }

  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {}

  @override
  Future<void> dispose() async => events.add('dispose');

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {}

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    openCalls++;
    events.add('open');
    durationController.add(const Duration(hours: 1));
  }

  @override
  Future<void> pause() async => playingController.add(false);

  @override
  Future<void> play() async => playingController.add(true);

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() async {
    events.add('probe');
    return _capabilities();
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() async => snapshot;

  @override
  Future<void> seek(Duration position) async =>
      positionController.add(position);

  @override
  Future<void> selectAudioTrack(String trackId) async {}

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {}

  @override
  Future<void> setAudioDelay(Duration delay) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setSubtitleDelay(Duration delay) async {}

  @override
  Future<void> stop() async => events.add('stop');
}

class _Resolver implements PlaybackStreamResolver {
  const _Resolver();

  @override
  bool get canForceTranscode => true;

  @override
  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async => PlaybackPlan(
    uri: Uri.https('media.test', '/video.mp4'),
    mediaSourceId: 'source',
    playSessionId: 'play-session',
    method: forceTranscode ? PlayMethod.transcode : PlayMethod.directPlay,
    usesServerAuthentication: false,
    mediaStreams: const [],
    transcodingReasons: const [],
    availableMediaSources: const [],
    bitrate: 8 * 1000 * 1000,
    duration: const Duration(hours: 1),
    transportKind: PlaybackTransportKind.progressiveHttp,
  );

  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
}

class _Reporter implements PlaybackReporter {
  @override
  void activate(PlaybackPlan plan) {}
  @override
  Future<void> cleanup(PlaybackPlan plan) async {}
  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {}
  @override
  Future<void> reportStart(Duration position) async {}
  @override
  Future<void> stop(Duration position) async {}
  @override
  void updatePlan(PlaybackPlan plan) {}
}

PlaybackCacheEngineCapabilities _capabilities() =>
    PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: 'mpv-test',
      platform: 'test',
      optionSupport: {
        for (final option in playbackCacheOptionNames) option: true,
      },
      propertySupport: {
        for (final property in playbackCachePropertyNames) property: true,
      },
      supportsImmediateUnlink: true,
      profileSwitchStrategy:
          PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      resetValues: const {'demuxer-cache-dir': ''},
    );

const _item = EmbyItem(
  id: 'item',
  name: 'Movie',
  type: 'Movie',
  mediaType: 'Video',
  runTimeTicks: 36000000000,
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
