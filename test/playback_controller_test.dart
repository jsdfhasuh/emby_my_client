import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
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

  test(
    'player.open errors remain in the existing playback failure path',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final engine = _FakeEngine()..openError = StateError('open failed');
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
      );

      await controller.start();

      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.state.errorMessage, isNotEmpty);
      await controller.shutdown();
    },
  );

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

  test(
    'remote strm uses authenticated Emby stream and still falls back',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, remoteStrm: true);
      final engine = _FakeEngine();
      engine.onOpen = (count) {
        if (count == 1) {
          engineLater(() => engine.playingController.add(true));
        } else {
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

      expect(engine.openUris.first.origin, _session.serverUrl);
      expect(engine.openUris.first.path, '/Videos/item-1/stream');
      expect(engine.openHeaders.first['X-Emby-Token'], _session.accessToken);
      expect(engine.openUris.last.origin, _session.serverUrl);
      expect(engine.openHeaders.last['X-Emby-Token'], _session.accessToken);
      expect(controller.state.plan?.method, PlayMethod.transcode);

      await controller.shutdown();
    },
  );

  test(
    'fatal stream logs fall back immediately and stop failed transcode',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, remoteStrm: true);
      final engine = _FakeEngine();
      final statuses = <String>[];
      engine.onOpen = (count) {
        if (count == 1) {
          engineLater(
            () => engine.logController.add('http: HTTP error 502 Bad Gateway'),
          );
        } else {
          engineLater(
            () => engine.logController.add(
              'http: inflate return value: -3, incorrect header check',
            ),
          );
        }
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        readyTimeout: const Duration(seconds: 10),
      );
      controller.addListener(() {
        final status = controller.state.statusMessage;
        if (status != null) statuses.add(status);
      });

      await controller.start().timeout(const Duration(milliseconds: 500));

      expect(engine.openUris, hasLength(2));
      expect(engine.stopCalls, 2);
      expect(statuses, contains('直连失败，正在切换到服务器转码…'));
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.state.isBuffering, isFalse);
      expect(controller.state.errorMessage, '直连失败，服务器转码也不可用：服务器返回的转码流格式异常');

      await controller.shutdown();
    },
  );

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

  test(
    'late resolver failure does not stop an already disposed engine',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      addTearDown(api.dispose);
      final engine = _FakeEngine();
      final resolution = Completer<PlaybackPlan>();
      final controller = PlaybackController(
        item: _plainItem,
        engine: engine,
        resolver: _DelayedResolver(resolution.future),
        reporter: PlaybackSessionReporter(api: api, item: _plainItem),
        playbackHeaders: api.playbackHeaders,
        progressInterval: const Duration(hours: 1),
      );

      final startup = controller.start();
      await Future<void>.delayed(Duration.zero);
      await controller.shutdown();
      resolution.completeError(TimeoutException('late PlaybackInfo timeout'));
      await startup;

      expect(engine.stopCalls, 1);
      expect(engine.disposeCalls, 1);
      expect(controller.state.phase, PlaybackPhase.idle);
      controller.dispose();
    },
  );

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

  test(
    'controller exposes latest requested position and merges seeks',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engineLater(
          () => engine.durationController.add(const Duration(hours: 1)),
        );
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
      );
      await controller.start();

      final results = List<Future<SeekResult>>.generate(
        100,
        (index) => controller.seekAbsolute(
          Duration(seconds: index + 1),
          source: SeekSource.progressBar,
        ),
      );
      expect(controller.state.displayPosition, const Duration(seconds: 100));
      final settled = await Future.wait(results);

      expect(engine.seekValues, [
        const Duration(seconds: 1),
        const Duration(seconds: 100),
      ]);
      expect(
        settled.where(
          (result) => result.disposition == SeekDisposition.superseded,
        ),
        hasLength(98),
      );
      expect(controller.state.position, const Duration(seconds: 100));
      expect(controller.state.requestedPosition, isNull);
      await controller.shutdown();
    },
  );

  test(
    'shutdown deadlines do not leave the controller route-blocking',
    () async {
      final engine = _FakeEngine(
        stopOperation: Completer<void>().future,
        disposeOperation: Completer<void>().future,
      );
      final reporter = _BlockingReporter();
      final controller = PlaybackController(
        item: _plainItem,
        engine: engine,
        resolver: _DelayedResolver(Completer<PlaybackPlan>().future),
        reporter: reporter,
        playbackHeaders: const {},
        stopTimeout: const Duration(milliseconds: 10),
        disposeTimeout: const Duration(milliseconds: 10),
        reporterTimeout: const Duration(milliseconds: 10),
      );

      await controller.shutdown().timeout(const Duration(milliseconds: 200));

      expect(engine.stopCalls, 1);
      expect(engine.disposeCalls, 1);
      expect(reporter.stopCalls, 1);
      expect(controller.state.phase, PlaybackPhase.idle);
      controller.dispose();
    },
  );
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

EmbyApi _api(List<RequestOptions> requests, {bool remoteStrm = false}) {
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
                    'Path': remoteStrm
                        ? 'https://upstream.example.test/live.m3u8'
                        : null,
                    'Protocol': remoteStrm ? 'Http' : 'File',
                    'Container': remoteStrm ? 'strm' : 'mkv',
                    'SupportsDirectPlay': !remoteStrm,
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
  _FakeEngine({this.stopOperation, this.disposeOperation});

  final Future<void>? stopOperation;
  final Future<void>? disposeOperation;
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
  final List<Uri> openUris = [];
  final List<Map<String, String>> openHeaders = [];
  final List<Duration> seekValues = [];
  int playCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  Object? openError;

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
    openUris.add(uri);
    openHeaders.add(Map<String, String>.from(headers));
    if (openError != null) throw openError!;
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
    await stopOperation;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await disposeOperation;
  }
}

class _BlockingReporter implements PlaybackReporter {
  int stopCalls = 0;

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
  Future<void> stop(Duration position) {
    stopCalls++;
    return Completer<void>().future;
  }

  @override
  void updatePlan(PlaybackPlan plan) {}
}

class _DelayedResolver implements PlaybackStreamResolver {
  const _DelayedResolver(this.result);

  final Future<PlaybackPlan> result;

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
  }) => result;

  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
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
