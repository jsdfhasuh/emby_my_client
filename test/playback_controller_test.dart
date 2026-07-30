import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opens paused, waits for ready, seeks and verifies resume', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(api: api, engine: engine, item: _resumeItem);

    await controller.start();

    expect(engine.openPlayValues, [false]);
    expect(engine.openHeaders.single['X-Emby-Token'], _session.accessToken);
    expect(engine.seekValues, [const Duration(minutes: 15)]);
    expect(engine.playCalls, 1);
    expect(controller.state.phase, PlaybackPhase.ready);
    expect(controller.state.position, const Duration(minutes: 15));
    final start = requests.singleWhere(
      (request) => request.path == '/Sessions/Playing',
    );
    expect((start.data as Map)['PositionTicks'], 9000000000);

    await controller.shutdown();
  });

  test('retries DirectPlay once with Transcode when ready times out', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    engine.onOpen = (count) {
      if (count == 2) {
        engineLater(
          () => engine.durationController.add(const Duration(hours: 1)),
        );
      }
    };
    final controller = _controller(
      api: api,
      engine: engine,
      item: _plainItem,
      readyTimeout: const Duration(milliseconds: 20),
    );

    await controller.start();

    expect(engine.openPlayValues, [true, true]);
    expect(engine.stopCalls, 1);
    expect(controller.state.phase, PlaybackPhase.ready);
    expect(controller.state.plan?.method, PlayMethod.transcode);
    final playbackInfoRequests = requests
        .where((request) => request.path.endsWith('/PlaybackInfo'))
        .toList();
    expect(playbackInfoRequests, hasLength(2));
    expect(
      (playbackInfoRequests.last.data as Map)['EnableDirectPlay'],
      isFalse,
    );

    await controller.shutdown();
  });

  test('shutdown is idempotent and invalidates late startup work', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    final controller = _controller(
      api: api,
      engine: engine,
      item: _plainItem,
      readyTimeout: const Duration(seconds: 1),
    );

    final startup = controller.start();
    await Future<void>.delayed(Duration.zero);
    await Future.wait([controller.shutdown(), controller.shutdown()]);
    await startup;

    expect(engine.disposeCalls, 1);
    expect(
      requests
          .where((request) => request.path == '/Sessions/Playing/Stopped')
          .length,
      lessThanOrEqualTo(1),
    );
  });

  test('serial reconfiguration preserves position and playing state', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(api: api, engine: engine, item: _plainItem);
    await controller.start();
    engine.positionController.add(const Duration(minutes: 5));
    engine.playingController.add(true);

    await controller.setMaximumBitrate(10000000);

    expect(engine.openPlayValues, [true, false]);
    expect(engine.seekValues, [const Duration(minutes: 5)]);
    expect(engine.playCalls, 1);
    expect(controller.state.position, const Duration(minutes: 5));
    expect(controller.state.isPlaying, isTrue);
    final playbackInfoRequests = requests
        .where((request) => request.path.endsWith('/PlaybackInfo'))
        .toList();
    expect(
      (playbackInfoRequests.last.data as Map)['MaxStreamingBitrate'],
      10000000,
    );
    await controller.shutdown();
  });
}

PlaybackController _controller({
  required EmbyApi api,
  required _FakeEngine engine,
  required EmbyItem item,
  Duration readyTimeout = const Duration(seconds: 1),
}) => PlaybackController(
  item: item,
  engine: engine,
  resolver: EmbyStreamResolver(api),
  reporter: PlaybackSessionReporter(api: api, item: item),
  playbackHeaders: api.playbackHeaders,
  readyTimeout: readyTimeout,
  resumeVerificationTimeout: const Duration(milliseconds: 100),
  progressInterval: const Duration(hours: 1),
);

EmbyApi _api(List<RequestOptions> requests) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        if (options.path.endsWith('/PlaybackInfo')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'PlaySessionId': 'play-session',
                'MediaSources': [
                  {
                    'Id': 'source-1',
                    'SupportsDirectPlay': true,
                    'SupportsDirectStream': false,
                    'SupportsTranscoding': true,
                    'TranscodingUrl': '/Videos/item/master.m3u8',
                    'MediaStreams': const [],
                  },
                ],
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: const {},
          ),
        );
      },
    ),
  );
  return EmbyApi(_session, dio: dio);
}

void engineLater(void Function() action) {
  scheduleMicrotask(action);
}

class _FakeEngine implements PlaybackEngine {
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<String>.broadcast(sync: true);
  final logController = StreamController<String>.broadcast(sync: true);
  final audioTracksController = StreamController<List<EngineTrack>>.broadcast(
    sync: true,
  );
  final subtitleTracksController =
      StreamController<List<EngineTrack>>.broadcast(sync: true);

  void Function(int count)? onOpen;
  final List<bool> openPlayValues = [];
  final List<Map<String, String>> openHeaders = [];
  final List<Duration> seekValues = [];
  int playCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<Duration> get positionStream => positionController.stream;

  @override
  Stream<Duration> get durationStream => durationController.stream;

  @override
  Stream<Duration> get bufferStream => bufferController.stream;

  @override
  Stream<bool> get playingStream => playingController.stream;

  @override
  Stream<bool> get bufferingStream => bufferingController.stream;

  @override
  Stream<bool> get completedStream => completedController.stream;

  @override
  Stream<String> get errorStream => errorController.stream;

  @override
  Stream<String> get logStream => logController.stream;

  @override
  Stream<List<EngineTrack>> get audioTracksStream =>
      audioTracksController.stream;

  @override
  Stream<List<EngineTrack>> get subtitleTracksStream =>
      subtitleTracksController.stream;

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    openPlayValues.add(play);
    openHeaders.add(Map<String, String>.from(headers));
    onOpen?.call(openPlayValues.length);
  }

  @override
  Future<void> play() async {
    playCalls++;
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekValues.add(position);
    positionController.add(position);
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {}

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {}

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioDelay(Duration delay) async {}

  @override
  Future<void> setSubtitleDelay(Duration delay) async {}

  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    playingController.add(false);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _plainItem = EmbyItem(
  id: 'item-1',
  name: 'Movie',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _resumeItem = EmbyItem(
  id: 'item-1',
  name: 'Movie',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(playbackPositionTicks: 9000000000),
);
