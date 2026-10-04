import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/source_input_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('progressive input retains the original server playback plan', () async {
    final engine = _ControlledEngine();
    final fixture = _Fixture(engine);

    await fixture.controller.start(subtitleDisabled: true);

    final original = fixture.resolver.plans['source-a']!;
    final plan = fixture.controller.state.plan!;
    expect(fixture.controller.state.phase, PlaybackPhase.ready);
    expect(engine.prepared, [original.progressiveRequest]);
    expect(engine.controlledOpens.single.request, original.progressiveRequest);
    expect(engine.nativeOpens, isEmpty);
    expect(plan.usesControlledInput, isTrue);
    expect(plan.controlledInputRequest, original.progressiveRequest);
    expect(plan.isSourceDirect, isFalse);
    expect(plan.sourceRequest, isNull);
    expect(plan.routeKind, PlaybackRouteKind.serverMedia);
    _expectOriginalPlan(plan, original);
    expect(plan.sourceSizeBytes, _verifiedBytes);
    expect(fixture.reporter.plan!.uri, original.uri);
    expect(fixture.reporter.plan!.mediaSourceId, original.mediaSourceId);
    expect(fixture.reporter.plan!.playSessionId, original.playSessionId);
    _expectSingleStart(fixture, original);

    await fixture.controller.shutdown();
    _expectSingleStop(fixture, original);
  });

  for (final code in [
    'range_unsupported',
    'native_unavailable',
    'unsupported_container',
  ]) {
    test('prepare $code falls back to original native URL and auth', () async {
      final engine = _ControlledEngine()
        ..prepareError = SourceInputException(code);
      final fixture = _Fixture(engine);
      final original = fixture.resolver.plans['source-a']!;

      await fixture.controller.start(subtitleDisabled: true);

      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(engine.prepared, [original.progressiveRequest]);
      expect(engine.controlledOpens, isEmpty);
      expect(engine.nativeOpens, hasLength(1));
      expect(engine.nativeOpens.single.uri, original.uri);
      expect(engine.nativeOpens.single.headers, fixture.api.playbackHeaders);
      expect(fixture.resolver.forcedTranscodes, [false]);
      expect(fixture.controller.state.plan!.progressiveRequest, isNull);
      expect(fixture.controller.state.plan!.usesControlledInput, isFalse);
      _expectOriginalPlan(fixture.controller.state.plan!, original);
      _expectSingleStart(fixture, original);
      expect(fixture.reports('/Sessions/Playing/Stopped'), isEmpty);
    });
  }

  for (final code in [
    'destination',
    'tls_certificate',
    'tls_downgrade',
    'redirect_limit',
    'redirect_location',
    'source_changed',
    'invalid_range',
    'source_denied',
  ]) {
    test(
      'prepare $code fails closed without native or transcode bypass',
      () async {
        final engine = _ControlledEngine()
          ..prepareError = SourceInputException(code);
        final fixture = _Fixture(engine);
        await fixture.controller.start(subtitleDisabled: true);
        expect(fixture.controller.state.phase, PlaybackPhase.failed);
        expect(engine.controlledOpens, isEmpty);
        expect(engine.nativeOpens, isEmpty);
        expect(fixture.resolver.forcedTranscodes, [false]);
        expect(fixture.reports('/Sessions/Playing'), isEmpty);
      },
    );
    test(
      'runtime $code fails closed without native or transcode bypass',
      () async {
        final engine = _ControlledEngine();
        final fixture = _Fixture(engine);
        await fixture.controller.start(subtitleDisabled: true);
        engine.failures.add(
          engine.failureFor(engine.controlledOpens.single.request, code: code),
        );
        await _until(
          () => fixture.controller.state.phase == PlaybackPhase.failed,
        );
        expect(engine.controlledOpens, hasLength(1));
        expect(engine.nativeOpens, isEmpty);
        expect(fixture.resolver.forcedTranscodes, [false]);
        expect(fixture.reports('/Sessions/Playing'), hasLength(1));
      },
    );
  }

  test(
    'range unsupported with unauthorized HTTP status cannot bypass denial',
    () async {
      final engine = _ControlledEngine()
        ..prepareError = const SourceInputException(
          'range_unsupported',
          httpStatus: 403,
        );
      final fixture = _Fixture(engine);
      await fixture.controller.start(subtitleDisabled: true);
      expect(fixture.controller.state.phase, PlaybackPhase.failed);
      expect(engine.nativeOpens, isEmpty);
      expect(engine.controlledOpens, isEmpty);
      expect(fixture.resolver.forcedTranscodes, [false]);
    },
  );

  test(
    'range rejection after cross-origin redirect cannot restore server auth',
    () async {
      final engine = _ControlledEngine()
        ..prepareError = const SourceInputException(
          'range_unsupported',
          httpStatus: 200,
        );
      final fixture = _Fixture(engine);
      fixture.resolver.plans['source-a']!.progressiveRequest!
          .markCrossOriginRedirect();
      await fixture.controller.start(subtitleDisabled: true);
      expect(fixture.controller.state.phase, PlaybackPhase.failed);
      expect(engine.nativeOpens, isEmpty);
      expect(engine.controlledOpens, isEmpty);
      expect(fixture.resolver.forcedTranscodes, [false]);
    },
  );

  test(
    'controlled open failure falls back without fetching a transcode',
    () async {
      final engine = _ControlledEngine()
        ..controlledOpenError = const SourceInputException(
          'native_policy_option',
        );
      final fixture = _Fixture(engine);
      final original = fixture.resolver.plans['source-a']!;

      await fixture.controller.start(subtitleDisabled: true);

      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(engine.events, [
        'prepare:source-a',
        'controlled:source-a',
        'native:stream.mkv',
      ]);
      expect(engine.nativeOpens.single.uri, original.uri);
      expect(engine.nativeOpens.single.headers, fixture.api.playbackHeaders);
      expect(fixture.resolver.forcedTranscodes, [false]);
      expect(fixture.controller.state.plan!.progressiveRequest, isNull);
      _expectOriginalPlan(fixture.controller.state.plan!, original);
      _expectSingleStart(fixture, original);
    },
  );

  test(
    'unsettled controlled native open timeout never overlaps fallback',
    () async {
      final gate = Completer<void>();
      final engine = _ControlledEngine()..controlledOpenGate = gate.future;
      final fixture = _Fixture(engine);
      await fixture.controller
          .start(subtitleDisabled: true)
          .timeout(const Duration(seconds: 3));
      expect(fixture.controller.state.phase, PlaybackPhase.failed);
      expect(engine.controlledOpens, hasLength(1));
      expect(engine.nativeOpens, isEmpty);
      expect(fixture.resolver.forcedTranscodes, [false]);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.controller.state.phase, PlaybackPhase.failed);
      expect(engine.nativeOpens, isEmpty);
      expect(fixture.reports('/Sessions/Playing'), isEmpty);
    },
  );

  test(
    'controlled readiness timeout tries the original URL before transcode',
    () async {
      final engine = _ControlledEngine()..controlledReady = false;
      final fixture = _Fixture(engine);

      await fixture.controller.start(subtitleDisabled: true);

      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(engine.controlledOpens, hasLength(1));
      expect(engine.nativeOpens, hasLength(1));
      expect(fixture.resolver.forcedTranscodes, [false]);
      expect(fixture.controller.state.plan!.method, PlayMethod.directPlay);
      expect(fixture.controller.state.plan!.progressiveRequest, isNull);
      expect(fixture.reports('/Sessions/Playing'), hasLength(1));
      expect(fixture.reports('/Sessions/Playing/Stopped'), isEmpty);
    },
  );

  test(
    'transcode is fetched only after the original native fallback fails',
    () async {
      final engine = _ControlledEngine()
        ..controlledOpenError = const SourceInputException(
          'native_policy_option',
        )
        ..nativeError = (uri) => uri.path.endsWith('/stream.mkv')
            ? StateError('Original native input failed')
            : null;
      final fixture = _Fixture(engine);

      await fixture.controller.start(subtitleDisabled: true);

      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(engine.events, [
        'prepare:source-a',
        'controlled:source-a',
        'native:stream.mkv',
        'native:master.m3u8',
      ]);
      expect(fixture.resolver.forcedTranscodes, [false, true]);
      expect(engine.prepared, hasLength(1));
      expect(fixture.controller.state.plan!.method, PlayMethod.transcode);
      expect(fixture.controller.state.plan!.usesControlledInput, isFalse);
      expect(fixture.reports('/Sessions/Playing'), hasLength(1));
      expect(
        fixture.reports('/Sessions/Playing').single.data['PlayMethod'],
        'Transcode',
      );
    },
  );

  for (final engineFactory in <String, _NativeEngine Function()>{
    'neither capability': _NativeEngine.new,
    'preparation only': _PreparationOnlyEngine.new,
    'controlled open only': _OpenOnlyEngine.new,
  }.entries) {
    test(
      'engine with ${engineFactory.key} skips progressive optimization',
      () async {
        final engine = engineFactory.value();
        final fixture = _Fixture(engine);
        final original = fixture.resolver.plans['source-a']!;

        await fixture.controller.start(subtitleDisabled: true);

        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        expect(engine.nativeOpens.single.uri, original.uri);
        expect(engine.nativeOpens.single.headers, fixture.api.playbackHeaders);
        expect(engine.events, ['native:stream.mkv']);
        expect(fixture.controller.state.plan!.usesControlledInput, isFalse);
        expect(fixture.resolver.forcedTranscodes, [false]);
      },
    );
  }

  test(
    'shutdown during preparation prevents late controlled or native open',
    () async {
      final gate = Completer<void>();
      final engine = _ControlledEngine()..prepareGate = gate.future;
      final fixture = _Fixture(engine);
      final start = fixture.controller.start(subtitleDisabled: true);
      await _until(() => engine.prepared.isNotEmpty);

      final shutdown = fixture.controller.shutdown();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([start, shutdown]).timeout(const Duration(seconds: 2));

      expect(engine.controlledOpens, isEmpty);
      expect(engine.nativeOpens, isEmpty);
      expect(fixture.controller.state.phase, PlaybackPhase.idle);
      expect(fixture.reports('/Sessions/Playing'), isEmpty);
      expect(fixture.resolver.forcedTranscodes, [false]);
    },
  );

  test(
    'late preparation error after shutdown cannot trigger native fallback',
    () async {
      final gate = Completer<void>();
      final engine = _ControlledEngine()
        ..prepareGate = gate.future
        ..prepareError = const SourceInputException('range_unsupported');
      final fixture = _Fixture(engine);
      final start = fixture.controller.start(subtitleDisabled: true);
      await _until(() => engine.prepared.isNotEmpty);

      final shutdown = fixture.controller.shutdown();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([start, shutdown]).timeout(const Duration(seconds: 2));

      expect(engine.controlledOpens, isEmpty);
      expect(engine.nativeOpens, isEmpty);
      expect(fixture.controller.state.phase, PlaybackPhase.idle);
      expect(fixture.reports('/Sessions/Playing'), isEmpty);
    },
  );

  for (final paused in [false, true]) {
    test(
      'typed runtime failure resumes original input at current position paused=$paused',
      () async {
        final engine = _ControlledEngine();
        final fixture = _Fixture(engine);
        final original = fixture.resolver.plans['source-a']!;
        await fixture.controller.start(subtitleDisabled: true);
        const position = Duration(minutes: 4, seconds: 12);
        engine.position.add(position);
        if (paused) await fixture.controller.pause();
        final gate = Completer<void>();
        engine.nativeGate = gate.future;
        final failure = engine.failureFor(original.progressiveRequest!);

        engine.failures.add(failure);
        engine.failures.add(failure);
        await _until(() => engine.nativeOpens.isNotEmpty);
        expect(fixture.reports('/Sessions/Playing/Stopped'), isEmpty);
        gate.complete();
        await _until(
          () => fixture.controller.state.phase == PlaybackPhase.ready,
        );

        expect(engine.prepared, hasLength(1));
        expect(engine.controlledOpens, hasLength(1));
        expect(engine.nativeOpens, hasLength(1));
        expect(engine.nativeOpens.single.uri, original.uri);
        expect(engine.nativeOpens.single.headers, fixture.api.playbackHeaders);
        expect(engine.nativeOpens.single.play, isFalse);
        expect(engine.seekPositions.last, position);
        expect(fixture.controller.state.position, position);
        expect(fixture.controller.state.isPlaying, !paused);
        expect(fixture.controller.state.plan!.progressiveRequest, isNull);
        expect(fixture.resolver.forcedTranscodes, [false]);
        _expectOriginalPlan(fixture.controller.state.plan!, original);
        _expectSingleStart(fixture, original);
        expect(fixture.reports('/Sessions/Playing/Stopped'), isEmpty);

        // A delayed callback from the abandoned controlled input cannot restart
        // it, send a second Start, or break the already-ready native fallback.
        engine.failures.add(failure);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.nativeOpens, hasLength(1));
        expect(engine.controlledOpens, hasLength(1));
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        await fixture.controller.shutdown();
        _expectSingleStop(fixture, original, position: position);
      },
    );
  }

  for (final userPaused in [false, true]) {
    test(
      'runtime fallback waits through lifecycle stop userPaused=$userPaused',
      () async {
        final engine = _ControlledEngine();
        final fixture = _Fixture(engine);
        final original = fixture.resolver.plans['source-a']!;
        await fixture.controller.start(subtitleDisabled: true);
        const current = Duration(minutes: 6, seconds: 3);
        engine.position.add(current);
        final stopGate = Completer<void>();
        engine.stopGate = stopGate.future;
        engine.failures.add(engine.failureFor(original.progressiveRequest!));
        await _until(() => engine.stopCalls == 1);

        await fixture.controller.pauseForLifecycle();
        if (userPaused) await fixture.controller.pause();
        stopGate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.nativeOpens, isEmpty);
        expect(fixture.reports('/Sessions/Playing/Stopped'), isEmpty);

        await fixture.controller.resumeForLifecycle();
        await _until(
          () => fixture.controller.state.phase == PlaybackPhase.ready,
        );
        expect(engine.nativeOpens, hasLength(1));
        expect(engine.nativeOpens.single.uri, original.uri);
        expect(engine.seekPositions.last, current);
        expect(engine.prepared, hasLength(1));
        expect(engine.controlledOpens, hasLength(1));
        expect(fixture.controller.state.plan!.progressiveRequest, isNull);
        expect(fixture.controller.state.position, current);
        expect(fixture.controller.state.isPlaying, !userPaused);
        _expectSingleStart(fixture, original);
        await fixture.controller.shutdown();
        _expectSingleStop(fixture, original, position: current);
      },
    );
  }

  for (final whileDeferred in [false, true]) {
    test(
      'cross-origin observation revokes fallback while deferred=$whileDeferred',
      () async {
        final engine = _ControlledEngine();
        final fixture = _Fixture(engine);
        await fixture.controller.start(subtitleDisabled: true);
        final request = engine.controlledOpens.single.request;
        final stopGate = Completer<void>();
        engine.stopGate = stopGate.future;
        engine.failures.add(engine.failureFor(request));
        await _until(() => engine.stopCalls == 1);

        if (whileDeferred) {
          await fixture.controller.pauseForLifecycle();
          stopGate.complete();
          await _until(
            () =>
                fixture.controller.state.phase == PlaybackPhase.recoveryPending,
          );
          request.markCrossOriginRedirect();
          await fixture.controller.resumeForLifecycle();
        } else {
          request.markCrossOriginRedirect();
          stopGate.complete();
        }

        await _until(
          () => fixture.controller.state.phase == PlaybackPhase.failed,
        );
        expect(engine.nativeOpens, isEmpty);
        expect(engine.controlledOpens, hasLength(1));
        expect(engine.prepared, hasLength(1));
        expect(fixture.resolver.forcedTranscodes, [false]);
        expect(fixture.reports('/Sessions/Playing'), hasLength(1));
      },
    );
  }

  test(
    'switching sources prepares new identity and rejects old failure callbacks',
    () async {
      final engine = _ControlledEngine();
      final fixture = _Fixture(engine);
      await fixture.controller.start(
        mediaSourceId: 'source-a',
        subtitleDisabled: true,
      );
      final first = engine.controlledOpens.single.request;
      final staleFailure = engine.failureFor(first);

      await fixture.controller.selectMediaSource('source-b');

      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(engine.prepared.map((r) => r.identity.sourceId), [
        'source-a',
        'source-b',
      ]);
      expect(engine.controlledOpens, hasLength(2));
      final second = engine.controlledOpens.last.request;
      expect(identical(first, second), isFalse);
      expect(first.identity.sameSource(second.identity), isFalse);
      expect(second.identity.sourceId, 'source-b');
      expect(fixture.controller.state.plan!.mediaSourceId, 'source-b');
      expect(fixture.controller.state.plan!.progressiveRequest, second);
      expect(engine.nativeOpens, isEmpty);

      engine.failures.add(staleFailure);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(engine.nativeOpens, isEmpty);
      expect(engine.controlledOpens, hasLength(2));
    },
  );
}

const _verifiedBytes = 128 * 1024 * 1024;
const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'fixture',
  serverId: 'server',
  userId: 'user',
  username: 'fixture',
  accessToken: 'fixture-token',
  deviceId: 'device',
);
final _item = EmbyItem.fromJson({
  'Id': 'item',
  'Name': 'Movie',
  'Type': 'Movie',
});

class _Fixture {
  _Fixture(_NativeEngine engine) {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {},
              ),
            );
          },
        ),
      );
    api = EmbyApi(_session, dio: dio);
    addTearDown(api.dispose);
    resolver = _Resolver(api);
    reporter = PlaybackSessionReporter(
      api: api,
      item: _item,
      trace: resolver.trace,
    );
    controller = PlaybackController(
      item: _item,
      engine: engine,
      resolver: resolver,
      reporter: reporter,
      trace: resolver.trace,
      playbackHeaders: api.playbackHeaders,
      readyTimeout: const Duration(milliseconds: 40),
      sourceReadyIdleTimeout: const Duration(milliseconds: 40),
      sourceReadyTimeout: const Duration(milliseconds: 120),
      openTimeout: const Duration(milliseconds: 300),
      shutdownBarrierTimeout: const Duration(milliseconds: 300),
      resumeVerificationTimeout: const Duration(milliseconds: 50),
      trackWaitTimeout: const Duration(milliseconds: 50),
      progressInterval: const Duration(hours: 1),
    );
    addTearDown(controller.shutdown);
  }

  final requests = <RequestOptions>[];
  late final EmbyApi api;
  late final _Resolver resolver;
  late final PlaybackSessionReporter reporter;
  late final PlaybackController controller;
  List<RequestOptions> reports(String path) =>
      requests.where((r) => r.path == path).toList();
}

class _Resolver implements PlaybackStreamResolver {
  _Resolver(EmbyApi api) {
    final itemSession = Object();
    for (final source in ['source-a', 'source-b']) {
      final uri = Uri.parse(
        'https://emby.example.test/Videos/item/stream.mkv?MediaSourceId=$source&Static=true',
      );
      final request = PlaybackResourceRequest.progressive(
        rawUrl: uri.toString(),
        headers: api.playbackHeaders,
        identity: PlaybackResourceIdentity(
          scope: ServerScope.fromSession(_session),
          apiSession: api,
          itemId: _item.id,
          sourceId: source,
          itemSession: itemSession,
          generation: source == 'source-a' ? 1 : 2,
        ),
        embyServer: Uri.parse(_session.serverUrl),
        trace: trace,
      );
      plans[source] = PlaybackPlan(
        uri: uri,
        mediaSourceId: source,
        playSessionId: 'play-$source',
        method: PlayMethod.directPlay,
        usesServerAuthentication: true,
        container: 'mkv',
        sourceProtocol: 'File',
        duration: const Duration(hours: 1),
        transportKind: PlaybackTransportKind.progressiveHttp,
        progressiveRequest: request,
        mediaStreams: const [],
        transcodingReasons: const [],
        availableMediaSources: const [],
      );
    }
  }

  final trace = StrmTrace();
  final plans = <String, PlaybackPlan>{};
  final forcedTranscodes = <bool>[];
  @override
  bool get canForceTranscode => true;
  @override
  Uri resolveExternalUrl(String url) => Uri.parse(url);
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
    forcedTranscodes.add(forceTranscode);
    final plan = plans[mediaSourceId ?? 'source-a']!;
    if (forceTranscode) {
      return plan.copyWith(
        clearProgressiveRequest: true,
        uri: Uri.parse('https://emby.example.test/Videos/item/master.m3u8'),
        method: PlayMethod.transcode,
        transportKind: PlaybackTransportKind.segmentedHttp,
        subtitleDisabled: subtitleDisabled,
      );
    }
    return plan.copyWith(subtitleDisabled: subtitleDisabled);
  }
}

void _expectOriginalPlan(PlaybackPlan actual, PlaybackPlan original) {
  expect(actual.uri, original.uri);
  expect(actual.mediaSourceId, original.mediaSourceId);
  expect(actual.playSessionId, original.playSessionId);
  expect(actual.method, original.method);
  expect(actual.usesServerAuthentication, original.usesServerAuthentication);
  expect(actual.duration, original.duration);
  expect(actual.container, original.container);
  expect(actual.mediaStreams, original.mediaStreams);
  expect(actual.isSourceDirect, isFalse);
}

void _expectSingleStart(_Fixture fixture, PlaybackPlan plan) {
  final starts = fixture.reports('/Sessions/Playing');
  expect(starts, hasLength(1));
  expect(starts.single.data['ItemId'], _item.id);
  expect(starts.single.data['MediaSourceId'], plan.mediaSourceId);
  expect(starts.single.data['PlaySessionId'], plan.playSessionId);
  expect(starts.single.data['PlayMethod'], plan.method.serverValue);
}

void _expectSingleStop(
  _Fixture fixture,
  PlaybackPlan plan, {
  Duration position = Duration.zero,
}) {
  final stops = fixture.reports('/Sessions/Playing/Stopped');
  expect(stops, hasLength(1));
  expect(stops.single.data['MediaSourceId'], plan.mediaSourceId);
  expect(stops.single.data['PlaySessionId'], plan.playSessionId);
  expect(stops.single.data['PlayMethod'], plan.method.serverValue);
  expect(stops.single.data['PositionTicks'], position.inMicroseconds * 10);
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(
    done(),
    isTrue,
    reason: 'Timed out waiting for asynchronous playback condition',
  );
}

class _NativeOpen {
  _NativeOpen(this.uri, this.headers, this.play);
  final Uri uri;
  final Map<String, String> headers;
  final bool play;
}

class _ControlledOpen {
  _ControlledOpen(this.request, this.play);
  final PlaybackResourceRequest request;
  final bool play;
}

class _NativeEngine implements PlaybackEngine {
  final position = StreamController<Duration>.broadcast(sync: true);
  final duration = StreamController<Duration>.broadcast(sync: true);
  final playing = StreamController<bool>.broadcast(sync: true);
  final nativeOpens = <_NativeOpen>[];
  final seekPositions = <Duration>[];
  final events = <String>[];
  Future<void>? nativeGate;
  Future<void>? stopGate;
  Object? Function(Uri)? nativeError;
  bool disposed = false;
  bool retiring = false;
  int stopCalls = 0;
  int playCalls = 0;

  @override
  Stream<Duration> get positionStream => position.stream;
  @override
  Stream<Duration> get durationStream => duration.stream;
  @override
  Stream<Duration> get bufferStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => playing.stream;
  @override
  Stream<bool> get bufferingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Stream<String> get logStream => const Stream.empty();
  @override
  Stream<List<EngineTrack>> get audioTracksStream => const Stream.empty();
  @override
  Stream<List<EngineTrack>> get subtitleTracksStream => const Stream.empty();

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    events.add('native:${uri.pathSegments.last}');
    nativeOpens.add(_NativeOpen(uri, Map.of(headers), play));
    final error = nativeError?.call(uri);
    if (error != null) throw error;
    await nativeGate;
    if (disposed || retiring) return;
    duration.add(const Duration(hours: 1));
    playing.add(play);
  }

  @override
  Future<void> play() async {
    playCalls++;
    if (!disposed && !retiring) playing.add(true);
  }

  @override
  Future<void> pause() async => playing.add(false);
  @override
  Future<void> quiesce() async {
    retiring = true;
    if (!disposed) playing.add(false);
  }

  @override
  Future<void> quiesceForLifecycle() async => playing.add(false);
  @override
  Future<void> resumeFromLifecycleQuiescence() async {}
  @override
  Future<void> seek(Duration value) async {
    seekPositions.add(value);
    if (!disposed && !retiring) position.add(value);
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
    if (!disposed) playing.add(false);
    await stopGate;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await Future.wait([position.close(), duration.close(), playing.close()]);
  }
}

class _ControlledEngine extends _NativeEngine
    implements
        SourceDirectPreparationEngine,
        SourceDirectPlaybackEngine,
        SourceFailureEmitter {
  final prepared = <PlaybackResourceRequest>[];
  final controlledOpens = <_ControlledOpen>[];
  final failures = StreamController<SourceInputFailure>.broadcast(sync: true);
  Future<void>? prepareGate;
  Object? prepareError;
  Object? controlledOpenError;
  Future<void>? controlledOpenGate;
  bool controlledReady = true;

  @override
  Stream<SourceInputFailure> get sourceFailureStream => failures.stream;
  @override
  Future<VerifiedSourceInput> prepareSource(
    PlaybackResourceRequest request,
  ) async {
    prepared.add(request);
    events.add('prepare:${request.identity.sourceId}');
    request.trace.nextOpen();
    await prepareGate;
    if (prepareError != null) throw prepareError!;
    return VerifiedSourceInput(request: request, sizeBytes: _verifiedBytes);
  }

  @override
  Future<void> openSource(
    PlaybackResourceRequest request, {
    required bool play,
  }) async {
    controlledOpens.add(_ControlledOpen(request, play));
    events.add('controlled:${request.identity.sourceId}');
    await controlledOpenGate;
    if (controlledOpenError != null) throw controlledOpenError!;
    if (controlledReady && !disposed && !retiring) {
      duration.add(const Duration(hours: 1));
      playing.add(play);
    }
  }

  SourceInputFailure failureFor(
    PlaybackResourceRequest request, {
    String code = 'truncated',
  }) => SourceInputFailure(
    error: SourceInputException(code, stage: 'body_read'),
    trace: request.trace,
    openAttempt: request.trace.currentAttempt,
    request: 4,
    stale: false,
  );
  @override
  Future<void> dispose() async {
    if (disposed) return;
    await super.dispose();
    await failures.close();
  }
}

class _PreparationOnlyEngine extends _NativeEngine
    implements SourceDirectPreparationEngine {
  @override
  Future<VerifiedSourceInput> prepareSource(
    PlaybackResourceRequest request,
  ) async {
    events.add('prepare:${request.identity.sourceId}');
    throw StateError('An engine without openSource must not prepare');
  }
}

class _OpenOnlyEngine extends _NativeEngine
    implements SourceDirectPlaybackEngine {
  @override
  Future<void> openSource(
    PlaybackResourceRequest request, {
    required bool play,
  }) async {
    events.add('controlled:${request.identity.sourceId}');
    throw StateError('An engine without prepareSource must not optimize');
  }
}
