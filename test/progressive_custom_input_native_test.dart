import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_session_bootstrap.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'strm_diagnostics_test.dart' show fileLog, report;
import 'support/progressive_fixture.dart';

// Like strm_custom_input_native_test.dart, these require actual host libmpv and
// STRM_INPUT_LIBRARY. Missing native support is a failure, never a silent skip.
// Only metadata/reporting are mocked. The generated AVI travels over a real
// socket, through the production Dart HTTP adapter and native stream callback.
void main() {
  for (final method in [PlayMethod.directPlay, PlayMethod.directStream]) {
    test(
      '${method.serverValue} bootstrap decodes, resumes and seeks via authenticated native callback',
      () async {
        final fixture = await _NativeProgressiveFixture.create(method);
        final origin = fixture.origin;
        origin.intercept = (request) async {
          if (request.target.contains('fixture-redirect=1')) return null;
          return (
            status: 302,
            headers: {
              'Location':
                  '${origin.origin}${request.target}&fixture-redirect=1',
            },
            body: <int>[],
          );
        };

        await fixture.start(resumePosition: const Duration(seconds: 8));
        final plan = fixture.controller.state.plan!;
        expect(plan.method, method);
        expect(plan.routeKind, PlaybackRouteKind.serverMedia);
        expect(plan.isSourceDirect, isFalse);
        expect(plan.sourceRequest, isNull);
        expect(plan.progressiveRequest, isNotNull);
        expect(plan.progressiveRequest!.allowsNativeFallback, isTrue);
        expect(plan.usesControlledInput, isTrue);
        expect(plan.usesServerAuthentication, isTrue);
        expect(plan.sourceSizeBytes, origin.bytes.length);
        expect(plan.transportKind, PlaybackTransportKind.progressiveHttp);
        expect(plan.progressiveRequest!.rawUrl, plan.uri.toString());
        expect(await fixture.native.getProperty('path'), 'embyinput://1');
        expect(
          await fixture.native.getProperty('http-header-fields'),
          isEmpty,
          reason: 'HTTP authentication belongs to Dart, never native callbacks',
        );
        // Cache configuration and engine open must share one verified preflight.
        expect(
          origin.requests.where(
            (request) =>
                request.target.contains('fixture-redirect=1') &&
                request.headers['range'] == 'bytes=0-262143',
          ),
          hasLength(1),
        );
        await fixture.exercisePlaybackAndSeek();
        fixture.expectAuthenticated(origin.requests);
        expect(
          origin.requests.every(
            (request) =>
                Uri.parse(request.target).path == plan.uri.path &&
                Uri.parse(request.target).queryParameters['MediaSourceId'] ==
                    'source',
          ),
          isTrue,
        );

        // A safety reopen resumes using a fresh callback cookie, while the
        // original server-media reporting cycle and selected source survive.
        final beforeReopen = fixture.controller.state.position;
        await fixture.controller.handleMemoryPressure();
        fixture.expectReady();
        expect(await fixture.native.getProperty('path'), 'embyinput://2');
        expect(fixture.controller.state.plan!.progressiveRequest, isNotNull);
        expect(fixture.controller.state.plan!.method, method);
        expect(
          fixture.controller.state.position.inMilliseconds,
          closeTo(beforeReopen.inMilliseconds, 1500),
        );
        fixture.expectReporting(stopped: false);
        fixture.expectSingleResolution();
        await fixture.shutdownAndVerify();

        final exported = await report(
          fixture.log,
          'native-progressive-${method.name}',
        );
        expect(exported.content, contains('route=server inputMode=stream_cb'));
        expect(
          exported.content,
          contains('stage=native_read outcome=first_read'),
        );
        expect(exported.content, contains('openAttempt=2'));
        expect(exported.content, isNot(contains(_fixtureToken)));
        expect(exported.content.split('scope=playback').length - 1, 1);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '${method.serverValue} native callback strips Emby credentials on cross-origin redirect',
      () async {
        final fixture = await _NativeProgressiveFixture.create(method);
        final destination = await ProgressiveOrigin.start();
        addTearDown(destination.close);
        fixture.origin.intercept = (_) async => (
          status: 302,
          headers: {
            'Location':
                '${destination.origin}/signed%2fvideo?sig=%7e&x=1&x=2'
                '&api_key=$_fixtureToken&X-Emby-Token=$_fixtureToken',
          },
          body: <int>[],
        );

        await fixture.start(resumePosition: const Duration(seconds: 8));
        final request = fixture.controller.state.plan!.progressiveRequest;
        expect(request, isNotNull);
        expect(request!.allowsNativeFallback, isFalse);
        expect(await fixture.native.getProperty('path'), 'embyinput://1');
        await fixture.exercisePlaybackAndSeek();
        fixture.expectAuthenticated(fixture.origin.requests);
        expect(destination.requests, isNotEmpty);
        for (final request in destination.requests) {
          expect(request.target, '/signed%2fvideo?sig=%7e&x=1&x=2');
          for (final header in const [
            'authorization',
            'cookie',
            'x-emby-token',
            'x-emby-authorization',
            'x-mediabrowser-token',
          ]) {
            expect(request.headers, isNot(contains(header)));
          }
        }
        expect(
          destination.requests.any(
            (request) => request.headers['range'] != 'bytes=0-262143',
          ),
          isTrue,
          reason:
              'The actual native reader must read beyond the sniffed prefix',
        );
        fixture.expectSingleResolution();
        await fixture.shutdownAndVerify(additionalOrigin: destination);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '${method.serverValue} unsupported Range falls back to original native URL without new reporting cycle',
      () async {
        final fixture = await _NativeProgressiveFixture.create(method);
        fixture.origin.intercept = (_) async => (
          status: 200,
          headers: {'Content-Type': 'video/x-msvideo'},
          body: fixture.origin.bytes,
        );

        await fixture.start();
        final plan = fixture.controller.state.plan!;
        expect(plan.method, method);
        expect(plan.routeKind, PlaybackRouteKind.serverMedia);
        expect(plan.sourceRequest, isNull);
        expect(plan.progressiveRequest, isNull);
        expect(plan.usesControlledInput, isFalse);
        expect(plan.usesServerAuthentication, isTrue);
        expect(plan.uri.origin, fixture.origin.origin);
        expect(
          plan.uri.path,
          method == PlayMethod.directPlay
              ? '/Videos/item/stream'
              : '/Videos/item/stream.avi',
        );
        expect(await fixture.native.getProperty('path'), plan.uri.toString());
        expect(
          fixture.origin.requests.first.headers['range'],
          'bytes=0-262143',
        );
        expect(
          fixture.origin.requests
              .skip(1)
              .any((request) => request.headers['range'] != 'bytes=0-262143'),
          isTrue,
          reason:
              'libmpv must make the fallback request after rejected preflight',
        );
        fixture.expectAuthenticated(fixture.origin.requests);
        await fixture.playUntil(const Duration(seconds: 2));
        expect(await fixture.native.getProperty('video-params/w'), '32');
        fixture.expectSingleResolution();
        fixture.expectReporting(stopped: false);
        await fixture.shutdownAndVerify();
        final exported = await report(
          fixture.log,
          'native-progressive-fallback-${method.name}',
        );
        expect(
          exported.content,
          isNot(contains('stage=native_read outcome=first_read')),
        );
        expect(exported.content, isNot(contains(_fixtureToken)));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

const _fixtureToken = 'synthetic-progressive-native-token';

class _NativeProgressiveFixture {
  _NativeProgressiveFixture({
    required this.method,
    required this.origin,
    required this.api,
    required this.requests,
    required this.player,
    required this.engine,
    required this.controller,
    required this.cacheRoot,
    required this.log,
    required this.nativeErrors,
    required this.nativeLogs,
    required this.inputClosed,
  });

  final PlayMethod method;
  final ProgressiveOrigin origin;
  final EmbyApi api;
  final List<RequestOptions> requests;
  final Player player;
  final MediaKitPlaybackEngine engine;
  final PlaybackController controller;
  final Directory cacheRoot;
  final DiagnosticLog log;
  final List<String> nativeErrors;
  final List<String> nativeLogs;
  final Future<void> inputClosed;
  NativePlayer get native => player.platform as NativePlayer;

  static Future<_NativeProgressiveFixture> create(PlayMethod method) async {
    MediaKit.ensureInitialized();
    final logs = await fileLog();
    final origin = await ProgressiveOrigin.start();
    addTearDown(origin.close);
    final requests = <RequestOptions>[];
    final source = <String, dynamic>{
      'Id': 'source',
      'Path': '/synthetic/movie.avi',
      'Container': 'avi',
      'Protocol': 'File',
      'RunTimeTicks': 240000000,
      'Size': origin.bytes.length,
      'SupportsDirectPlay': method == PlayMethod.directPlay,
      'SupportsDirectStream': method == PlayMethod.directStream,
      'SupportsTranscoding': false,
      if (method == PlayMethod.directStream)
        'DirectStreamUrl':
            '/Videos/item/stream.avi?MediaSourceId=source&Static=true'
            '&PlaySessionId=cycle',
    };
    final itemJson = <String, dynamic>{
      'Id': 'item',
      'Type': 'Movie',
      'RunTimeTicks': 240000000,
      'MediaSources': [source],
    };
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: options.path.endsWith('/PlaybackInfo')
                    ? {
                        'PlaySessionId': 'cycle',
                        'MediaSources': [source],
                      }
                    : options.path == '/Users/user/Items/item'
                    ? itemJson
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
    final api = EmbyApi(
      EmbySession(
        serverUrl: origin.origin,
        serverName: 'synthetic fixture',
        serverId: 'server',
        userId: 'user',
        username: 'fixture',
        accessToken: _fixtureToken,
        deviceId: 'device',
      ),
      dio: dio,
    );
    addTearDown(api.dispose);
    final cacheRoot = await Directory.systemTemp.createTemp(
      'progressive-native-cache-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    // Decode actual frames without depending on a display or sound server.
    final player = Player(configuration: const PlayerConfiguration(vo: 'null'));
    final engine = MediaKitPlaybackEngine(player);
    addTearDown(engine.dispose);
    final nativeErrors = <String>[];
    final nativeLogs = <String>[];
    final errors = player.stream.error.listen(nativeErrors.add);
    final logsSubscription = player.stream.log.listen(
      (event) => nativeLogs.add(event.toString()),
    );
    addTearDown(errors.cancel);
    addTearDown(logsSubscription.cancel);
    await (player.platform as NativePlayer).setProperty('vid', 'auto');
    await (player.platform as NativePlayer).setProperty('ao', 'null');
    final controller = PlaybackSessionBootstrap.createOnlineController(
      api: api,
      trace: StrmTrace(log: logs.log),
      entry: 'fullscreen',
      item: EmbyItem.fromJson(itemJson),
      engine: engine,
      session: PlaybackItemSession.forTest('native-progressive-${method.name}'),
      settings: const PlaybackSettings(),
      cacheStorage: PlatformPlaybackCacheStorage(
        rootResolver: () async => cacheRoot,
        freeBytesResolver: (_) async => 20 << 30,
      ),
    );
    addTearDown(controller.shutdown);
    return _NativeProgressiveFixture(
      method: method,
      origin: origin,
      api: api,
      requests: requests,
      player: player,
      engine: engine,
      controller: controller,
      cacheRoot: cacheRoot,
      log: logs.log,
      nativeErrors: nativeErrors,
      nativeLogs: nativeLogs,
      inputClosed: engine.sourceFailureStream.drain<void>(),
    );
  }

  Future<void> start({Duration resumePosition = Duration.zero}) async {
    await controller.start(
      resumePosition: resumePosition,
      playAfterReady: false,
      subtitleDisabled: true,
    );
    expectReady();
    expect(controller.state.isPlaying, isFalse);
    expect(controller.state.duration.inSeconds, greaterThanOrEqualTo(23));
    if (resumePosition > Duration.zero) {
      expect(
        controller.state.position.inMilliseconds,
        closeTo(resumePosition.inMilliseconds, 1500),
      );
    }
    expectReporting(stopped: false);
    final start = requests.singleWhere(
      (request) => request.path == '/Sessions/Playing',
    );
    final data = start.data as Map<String, dynamic>;
    expect(data['IsPaused'], isTrue);
    expect(
      data['PositionTicks'],
      closeTo(resumePosition.inMicroseconds * 10, 15000000),
    );
  }

  void expectReady() {
    expect(
      controller.state.phase,
      PlaybackPhase.ready,
      reason:
          '${controller.state.errorMessage}\n${nativeErrors.join('\n')}'
          '\n${nativeLogs.join('\n')}',
    );
  }

  Future<void> playUntil(Duration target) async {
    final reached = player.stream.position
        .firstWhere((position) => position >= target)
        .timeout(const Duration(seconds: 15));
    await controller.play();
    await reached;
    await controller.pause();
    expectReady();
  }

  Future<void> exercisePlaybackAndSeek() async {
    await playUntil(const Duration(seconds: 9));
    expect(await native.getProperty('video-params/w'), '32');
    expect(await native.getProperty('video-params/h'), '24');
    final result = await controller.seekAbsolute(
      const Duration(seconds: 16),
      source: SeekSource.progressBar,
    );
    expect(result.disposition, SeekDisposition.executed);
    expect(result.settled, isTrue);
    expect(controller.state.position.inMilliseconds, closeTo(16000, 1500));
    await playUntil(const Duration(seconds: 17));
    expect(await native.getProperty('video-params/w'), '32');
  }

  void expectAuthenticated(Iterable<FixtureRequest> mediaRequests) {
    expect(mediaRequests, isNotEmpty);
    for (final request in mediaRequests) {
      for (final header in api.playbackHeaders.entries) {
        expect(request.headers[header.key.toLowerCase()], header.value);
      }
    }
  }

  void expectSingleResolution() {
    expect(
      requests.where((request) => request.path.endsWith('/PlaybackInfo')),
      hasLength(1),
    );
    expect(
      requests.where((request) => request.path == '/Users/user/Items/item'),
      hasLength(1),
    );
    expect(
      requests.any(
        (request) =>
            request.path.contains('/Videos/') ||
            request.path.contains('/Download') ||
            request.path.contains('/LiveStreams/'),
      ),
      isFalse,
      reason: 'Only the native media path may fetch the selected video',
    );
  }

  void expectReporting({required bool stopped}) {
    expect(
      requests.where((request) => request.path == '/Sessions/Playing'),
      hasLength(1),
    );
    expect(
      requests.where((request) => request.path == '/Sessions/Playing/Stopped'),
      hasLength(stopped ? 1 : 0),
    );
    for (final request in requests.where(
      (request) => request.path.startsWith('/Sessions/Playing'),
    )) {
      final data = request.data as Map<String, dynamic>;
      expect(data['ItemId'], 'item');
      expect(data['MediaSourceId'], 'source');
      expect(data['PlaySessionId'], 'cycle');
      expect(data['PlayMethod'], method.serverValue);
    }
  }

  Future<void> shutdownAndVerify({ProgressiveOrigin? additionalOrigin}) async {
    await controller.shutdown();
    await inputClosed.timeout(const Duration(seconds: 5));
    expect(await cacheRoot.list().toList(), isEmpty);
    expectReporting(stopped: true);
    final requestCount = origin.requests.length;
    final redirectedCount = additionalOrigin?.requests.length;
    // Idempotent shutdown must not report twice or restart any prefetched work.
    await controller.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(origin.requests, hasLength(requestCount));
    if (additionalOrigin != null) {
      expect(additionalOrigin.requests, hasLength(redirectedCount!));
    }
    expectReporting(stopped: true);
  }
}
