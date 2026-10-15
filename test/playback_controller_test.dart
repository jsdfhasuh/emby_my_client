import 'dart:async';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/offline/offline_playback_reporter.dart';
import 'package:emby_my_client/offline/offline_playback_resolver.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/external_subtitle_loader.dart';
import 'package:emby_my_client/playback/media_kit_inline_playback_session.dart';
import 'package:emby_my_client/playback/inline_playback_resource_lease.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_session_bootstrap.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/progressive_fixture.dart';

void main() {
  _deliveryRegressionTests();
  _nativeIdentityRegressionTests();
  _subtitleRegressionTests();
  test(
    'source startup keeps reading past ordinary readiness deadline',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, remoteStrm: true);
      addTearDown(api.dispose);
      final engine = _FakeEngine();
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        readyTimeout: const Duration(milliseconds: 20),
        sourceReadyIdleTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(controller.shutdown);
      final start = controller.start(subtitleDisabled: true);
      await _waitUntil(
        () => controller.state.phase == PlaybackPhase.waitingForReady,
      );
      final request = controller.state.plan!.sourceRequest!;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        request.startupProgress.recordBytes(9000000000 + i * 1048576, 1048576);
        expect(controller.state.phase, PlaybackPhase.waitingForReady);
      }
      engine.durationController.add(const Duration(hours: 1));
      await start;
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(engine.openUris, hasLength(1));
    },
  );

  test(
    'shutdown cancels source readiness without waiting for idle timeout',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, remoteStrm: true);
      addTearDown(api.dispose);
      final controller = _controller(
        api: api,
        engine: _FakeEngine(),
        item: _plainItem,
        sourceReadyIdleTimeout: const Duration(seconds: 15),
      );
      final start = controller.start(subtitleDisabled: true);
      await _waitUntil(
        () => controller.state.phase == PlaybackPhase.waitingForReady,
      );
      await controller.shutdown();
      await start.timeout(const Duration(seconds: 1));
      expect(controller.state.phase, PlaybackPhase.idle);
    },
  );

  test(
    'source runtime seek recovery reuses snapshot and reporting cycle',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, remoteStrm: true);
      addTearDown(api.dispose);
      final engine = _FakeEngine();
      engine.onOpen = (_) =>
          engine.durationController.add(const Duration(hours: 1));
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
      );
      addTearDown(controller.shutdown);
      await controller.start(subtitleDisabled: true);
      expect(controller.state.plan!.isSourceDirect, true);
      await controller.seekAbsolute(
        const Duration(minutes: 4),
        source: SeekSource.progressBar,
      );
      engine.errorController.add('Error reading packet');
      for (
        var i = 0;
        i < 100 &&
            (engine.openUris.length < 2 ||
                controller.state.phase != PlaybackPhase.ready);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.openUris, hasLength(2));
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(
        requests.where((r) => r.path.endsWith('/PlaybackInfo')),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.path == '/Sessions/Playing'),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.path == '/Sessions/Playing/Stopped'),
        isEmpty,
      );
      await controller.shutdown();
      expect(
        requests.where((r) => r.path == '/Sessions/Playing/Stopped'),
        hasLength(1),
      );
    },
  );
  test(
    'B21 new-source preflight clears A indices before the first B request',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (count) {
        engine.durationController.add(const Duration(hours: 1));
        engine.audioTracksController.add([
          EngineTrack(id: '2', language: count == 1 ? 'chi' : 'eng'),
        ]);
        engine.subtitleTracksController.add([
          EngineTrack(id: '3', title: count == 1 ? 'Chinese' : 'English'),
        ]);
      };
      final resolver = _PlanResolver(
        _testPlan(
          mediaStreams: const [
            {'Index': 2, 'Type': 'Audio', 'Language': 'chi'},
            {
              'Index': 3,
              'Type': 'Subtitle',
              'DisplayTitle': 'Chinese',
              'Title': 'Chinese',
            },
          ],
        ),
        sourcePlans: {
          'source-b': _testPlan(
            subtitleStreamIndex: 3,
            mediaStreams: const [
              {'Index': 2, 'Type': 'Audio', 'Language': 'eng'},
              {'Index': 5, 'Type': 'Audio', 'Language': 'chi'},
              {
                'Index': 3,
                'Type': 'Subtitle',
                'DisplayTitle': 'English',
                'Title': 'English',
              },
            ],
          ).copyWith(audioStreamIndex: 2),
        },
      );
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );
      await controller.start(
        mediaSourceId: 'source-1',
        audioStreamIndex: 2,
        subtitleStreamIndex: 3,
      );
      await controller.selectMediaSource('source-b');
      expect(resolver.sourceRequests, ['source-1', 'source-b']);
      expect(resolver.audioStreamRequests, [2, null]);
      expect(resolver.subtitleStreamRequests, [3, null]);
      expect(controller.state.plan?.mediaSourceId, 'source-b');
      expect(controller.state.appliedAudioStreamIndex, 2);
      expect(controller.state.plan?.mediaStreams.first['Language'], 'eng');
      await controller.shutdown();
    },
  );

  test(
    'B22 failed source preflight preserves current engine and selection',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (_) =>
          engine.durationController.add(const Duration(hours: 1));
      final resolver = _PlanResolver(_testPlan());
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );
      await controller.start(mediaSourceId: 'source-1', subtitleDisabled: true);
      resolver.failSource = 'source-b';
      await controller.selectMediaSource('source-b');
      expect(resolver.subtitleDisabledRequests, [true, true]);
      expect(engine.openUris, hasLength(1));
      expect(engine.stopCalls, 0);
      expect(controller.state.plan?.mediaSourceId, 'source-1');
      expect(controller.state.desiredSubtitleSelection.isDisabled, isTrue);
      await controller.shutdown();
    },
  );

  test(
    'B23 controller serializes late native A before the latest disable',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      server.intercept = (_) async => (
        status: 200,
        headers: <String, String>{},
        body: utf8.encode('1\n00:00:00,000 --> 00:00:24,000\nFixture\n'),
      );
      final api = _api([]);
      addTearDown(api.dispose);
      final nativeGate = Completer<void>();
      final engine = _FakeEngine(externalSubtitleOperation: nativeGate.future);
      engine.onOpen = (_) =>
          engine.durationController.add(const Duration(hours: 1));
      final resolver = _PlanResolver(
        _testPlan(
          mediaStreams: [
            {
              'Index': 3,
              'Type': 'Subtitle',
              'IsExternal': true,
              'DeliveryUrl': '${server.origin}/a.srt',
            },
            {
              'Index': 4,
              'Type': 'Subtitle',
              'IsExternal': true,
              'DeliveryUrl': '${server.origin}/b.srt',
            },
          ],
        ),
      );
      final controller = _controller(
        api: api,
        subtitleLoader: ExternalSubtitleLoader(api),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );
      await controller.start(subtitleStreamIndex: 3);
      expect(controller.state.phase, PlaybackPhase.ready);
      await engine.externalSubtitleEntered.future.timeout(
        const Duration(seconds: 3),
      );
      final file = File.fromUri(engine.externalSubtitleUris.single);
      expect(await file.exists(), true);
      final b = controller.selectSubtitleStream(4);
      final off = controller.selectSubtitleStream(null);
      expect(engine.actualSubtitle, isNull);
      nativeGate.complete();
      await Future.wait([b, off]);
      expect(engine.externalSubtitleUris, hasLength(1));
      expect(engine.nativeSubtitleEffects, ['external', 'off']);
      expect(engine.actualSubtitle, isNull);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.disabled,
      );
      await controller.shutdown();
      expect(await file.exists(), false);
    },
  );

  test('completed seek presentation commits only executed results', () {
    const start = Duration(minutes: 2);
    const requested = Duration(minutes: 8);
    expect(
      resolveCompletedSeekDisplayPosition(
        startPosition: start,
        requestedTarget: requested,
        result: const SeekResult(
          disposition: SeekDisposition.executed,
          requestedTarget: requested,
          committedPosition: Duration(minutes: 7, seconds: 59),
          settled: true,
        ),
      ),
      const Duration(minutes: 7, seconds: 59),
    );
    expect(
      resolveCompletedSeekDisplayPosition(
        startPosition: start,
        requestedTarget: requested,
        result: const SeekResult(
          disposition: SeekDisposition.failed,
          requestedTarget: requested,
          settled: false,
          failureKind: SeekFailureKind.engineError,
        ),
      ),
      start,
    );
    expect(
      resolveCompletedSeekDisplayPosition(
        startPosition: start,
        requestedTarget: requested,
        result: null,
      ),
      start,
    );
  });

  test(
    'opens paused, applies the default subtitle, seeks and verifies resume',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, defaultSubtitleStreamIndex: 3);
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engineLater(() {
          engine.subtitleTracksController.add(const [
            EngineTrack(id: '3', title: 'Chinese'),
          ]);
          engine.durationController.add(const Duration(hours: 1));
        });
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _resumeItem,
      );

      await controller.start();

      expect(engine.openPlayValues, [false]);
      expect(engine.openHeaders.single['X-Emby-Token'], _session.accessToken);
      expect(engine.selectedSubtitleTrackIds, ['3']);
      expect(engine.seekValues, [const Duration(minutes: 15)]);
      expect(engine.playCalls, 1);
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(controller.state.position, const Duration(minutes: 15));
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
      final start = requests.singleWhere(
        (request) => request.path == '/Sessions/Playing',
      );
      expect((start.data as Map)['PositionTicks'], 9000000000);

      await controller.shutdown();
    },
  );

  test('explicit resume position overrides the Emby item position', () async {
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _resumeItem,
    );

    await controller.start(resumePosition: const Duration(minutes: 5));

    expect(engine.openPlayValues, [false]);
    expect(engine.seekValues, [const Duration(minutes: 5)]);
    expect(engine.playCalls, 1);
    expect(controller.state.position, const Duration(minutes: 5));
    await controller.shutdown();
  });

  test('playAfterReady false leaves initial playback paused', () async {
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
    );

    await controller.start(playAfterReady: false);

    expect(engine.openPlayValues, [false]);
    expect(engine.playCalls, 0);
    expect(controller.state.phase, PlaybackPhase.ready);
    expect(controller.state.isPlaying, isFalse);
    await controller.shutdown();
  });

  test(
    'paused Start becomes unpaused Progress only after successful play',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final engine = _FakeEngine()..emitPlayingOnPlay = false;
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        resolver: _PlanResolver(_testPlan()),
      );

      await controller.start(playAfterReady: false);

      final starts = requests.where(
        (request) => request.path == '/Sessions/Playing',
      );
      expect(starts, hasLength(1));
      expect((starts.single.data as Map)['IsPaused'], isTrue);
      expect(
        requests.where(
          (request) => request.path == '/Sessions/Playing/Progress',
        ),
        isEmpty,
      );

      await controller.play();

      final progress = requests.where(
        (request) => request.path == '/Sessions/Playing/Progress',
      );
      expect(engine.playCalls, 1);
      expect(controller.state.isPlaying, isFalse);
      expect(progress, hasLength(1));
      expect((progress.single.data as Map)['IsPaused'], isFalse);

      await controller.shutdown();
      expect(
        requests.where(
          (request) => request.path == '/Sessions/Playing/Stopped',
        ),
        hasLength(1),
      );
    },
  );

  test('stale ready generation suppresses Start and cleans encoding', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(
      api: api,
      engine: engine,
      item: _plainItem,
      resolver: _PlanResolver(_testPlan(method: PlayMethod.transcode)),
    );
    var retiredAtReady = false;
    controller.addListener(() {
      if (!retiredAtReady && controller.state.phase == PlaybackPhase.ready) {
        retiredAtReady = true;
        unawaited(controller.quiesce());
      }
    });

    await controller.start();
    await controller.shutdown();

    expect(retiredAtReady, isTrue);
    expect(
      requests.where((request) => request.path == '/Sessions/Playing'),
      isEmpty,
    );
    expect(
      requests.where((request) => request.path == '/Sessions/Playing/Stopped'),
      isEmpty,
    );
    expect(
      requests.where((request) => request.path == '/Videos/ActiveEncodings'),
      hasLength(1),
    );
  });

  test('pause stops a play request before playing state arrives', () async {
    final engine = _FakeEngine()..emitPlayingOnPlay = false;
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
    );
    await controller.start(playAfterReady: false);

    await controller.play();
    expect(controller.state.isPlaying, isFalse);
    await controller.pause();

    expect(engine.playCalls, 1);
    expect(engine.pauseCalls, 1);
    await controller.shutdown();
  });

  test('quiescence starts while native play is blocked', () async {
    final playGate = Completer<void>();
    final engine = _FakeEngine(playOperation: playGate.future);
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
    );
    await controller.start(playAfterReady: false);

    final play = controller.play();
    await _waitUntil(() => engine.playCalls == 1);
    final quiescence = controller.quiesce();
    await _waitUntil(() => engine.quiesceCalls == 1);

    expect(engine.playCalls, 1);
    expect(engine.quiesceCalls, 1);
    expect(controller.state.isPlaying, isFalse);

    playGate.complete();
    await Future.wait([play, quiescence]);
    expect(controller.state.isPlaying, isFalse);
    await controller.shutdown();
  });

  test(
    'quiescence cancels logical seek and shutdown waits native seek',
    () async {
      final seekGate = Completer<void>();
      final engine = _FakeEngine(seekOperation: seekGate.future);
      engine.onOpen = (_) {
        engineLater(
          () => engine.durationController.add(const Duration(hours: 1)),
        );
      };
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
      );
      await controller.start(playAfterReady: false);

      final seek = controller.seekAbsolute(
        const Duration(minutes: 10),
        source: SeekSource.progressBar,
      );
      await _waitUntil(() => engine.seekValues.isNotEmpty);
      await controller.quiesce();

      final result = await seek;
      expect(result.disposition, SeekDisposition.cancelled);
      expect(result.failureKind, SeekFailureKind.higherPriorityOperation);
      expect(engine.quiesceCalls, 1);

      var shutdownCompleted = false;
      final shutdown = controller.shutdown().then(
        (_) => shutdownCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);
      expect(engine.stopCalls, 0);
      expect(engine.disposeCalls, 0);

      seekGate.complete();
      await shutdown;
      expect(shutdownCompleted, isTrue);
      expect(engine.stopCalls, 1);
      expect(engine.disposeCalls, 1);
    },
  );

  test(
    'never-ending play exits logically and cannot revive UI state',
    () async {
      final engine = _FakeEngine(playOperation: Completer<void>().future);
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        playPauseTimeout: const Duration(milliseconds: 10),
        retirementQuiesceTimeout: const Duration(milliseconds: 10),
        shutdownBarrierTimeout: const Duration(milliseconds: 30),
      );
      await controller.start(playAfterReady: false);

      await controller.play().timeout(const Duration(milliseconds: 200));

      expect(engine.playCalls, 1);
      expect(controller.state.isPlaying, isFalse);
      await controller.shutdown().timeout(const Duration(milliseconds: 200));
      expect(controller.retirementState, PlaybackRetirementState.closed);
    },
  );

  test('never-ending pause exits logically during shutdown', () async {
    final engine = _FakeEngine(pauseOperation: Completer<void>().future);
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
      playPauseTimeout: const Duration(milliseconds: 10),
      retirementQuiesceTimeout: const Duration(milliseconds: 10),
      shutdownBarrierTimeout: const Duration(milliseconds: 30),
    );
    await controller.start();

    await controller.pause().timeout(const Duration(milliseconds: 200));
    expect(engine.pauseCalls, 1);
    expect(controller.state.isPlaying, isFalse);

    await controller.shutdown().timeout(const Duration(milliseconds: 200));
    expect(controller.state.phase, PlaybackPhase.idle);
  });

  test('never-ending lifecycle quiesce has a bounded logical exit', () async {
    final engine = _FakeEngine(
      lifecycleQuiesceOperation: Completer<void>().future,
    );
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
      lifecycleQuiesceTimeout: const Duration(milliseconds: 10),
      retirementQuiesceTimeout: const Duration(milliseconds: 10),
      shutdownBarrierTimeout: const Duration(milliseconds: 30),
    );
    await controller.start(playAfterReady: false);

    await expectLater(
      controller.quiesceForLifecycle(),
      throwsA(
        isA<PlaybackNativeOperationTimedOut>().having(
          (error) => error.kind,
          'kind',
          PlaybackNativeOperationKind.lifecycleQuiesce,
        ),
      ),
    );
    expect(controller.state.isPlaying, isFalse);

    await controller.shutdown().timeout(const Duration(milliseconds: 200));
    expect(controller.state.phase, PlaybackPhase.idle);
  });

  test('never-ending seek times out without blocking shutdown', () async {
    final engine = _FakeEngine(seekOperation: Completer<void>().future);
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
      seekCallTimeout: const Duration(milliseconds: 10),
      retirementQuiesceTimeout: const Duration(milliseconds: 10),
      shutdownBarrierTimeout: const Duration(milliseconds: 30),
    );
    await controller.start(playAfterReady: false);

    final result = await controller.seekAbsolute(
      const Duration(minutes: 5),
      source: SeekSource.progressBar,
    );
    expect(result.failureKind, SeekFailureKind.callTimeout);

    await controller.shutdown().timeout(const Duration(milliseconds: 200));
    expect(controller.state.phase, PlaybackPhase.idle);
  });

  test(
    'quiescing rejects new playback, seek, reconfiguration and resume work',
    () async {
      final engine = _FakeEngine(quiesceOperation: Completer<void>().future);
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        retirementQuiesceTimeout: const Duration(milliseconds: 10),
        shutdownBarrierTimeout: const Duration(milliseconds: 30),
      );
      await controller.start(playAfterReady: false);
      final openCount = engine.openPlayValues.length;
      final rateWriteCount = engine.rateValues.length;

      controller.quiesce();
      expect(controller.retirementState, PlaybackRetirementState.quiescing);
      await controller.play();
      final seek = await controller.seekAbsolute(
        const Duration(minutes: 3),
        source: SeekSource.progressBar,
      );
      await controller.setPlaybackRate(1.5);
      await controller.reconfigure(maxStreamingBitrate: 10000000);
      await controller.resumeForLifecycle();

      expect(engine.playCalls, 0);
      expect(engine.seekValues, isEmpty);
      expect(seek.disposition, SeekDisposition.cancelled);
      expect(engine.rateValues, hasLength(rateWriteCount));
      expect(engine.openPlayValues, hasLength(openCount));
      expect(engine.lifecycleQuiescenceResumeCalls, 0);

      await controller.shutdown().timeout(const Duration(milliseconds: 200));
      expect(controller.retirementState, PlaybackRetirementState.quarantined);
    },
  );

  test('shared online bootstrap applies settings and start options', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    const settings = PlaybackSettings(
      maxStreamingBitrate: 20000000,
      playbackRate: 1.5,
      audioDelayMilliseconds: 250,
      subtitleDelayMilliseconds: -500,
      subtitleFontSize: 52,
      subtitleColor: 0xFFFFFF00,
      subtitleOutlineColor: 0xFF404040,
      subtitlePosition: 88,
    );
    final controller = PlaybackSessionBootstrap.createOnlineController(
      api: api,
      item: _plainItem,
      engine: engine,
      session: PlaybackItemSession.forTest('bootstrap-session'),
      settings: settings,
    );

    await PlaybackSessionBootstrap.configureAndStart(
      controller: controller,
      settings: settings,
      resumePosition: const Duration(minutes: 4),
      playAfterReady: false,
    );

    expect(engine.rateValues, isNotEmpty);
    expect(engine.rateValues, everyElement(1.5));
    expect(
      engine.audioDelayValues,
      everyElement(const Duration(milliseconds: 250)),
    );
    expect(
      engine.subtitleDelayValues,
      everyElement(const Duration(milliseconds: -500)),
    );
    expect(engine.subtitleStyleValues, isNotEmpty);
    expect(engine.subtitleStyleValues.last, (52.0, 0xFFFFFF00, 0xFF404040, 88));
    expect(engine.openPlayValues, [false]);
    expect(engine.seekValues, [const Duration(minutes: 4)]);
    expect(engine.playCalls, 0);
    final playbackInfo = requests.singleWhere(
      (request) => request.path.endsWith('/PlaybackInfo'),
    );
    expect((playbackInfo.data as Map)['MaxStreamingBitrate'], 20000000);
    await controller.shutdown();
  });

  test(
    'applies the server-resolved default subtitle during initial DirectPlay',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, defaultSubtitleStreamIndex: 3);
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engineLater(() {
          engine.subtitleTracksController.add(const [
            EngineTrack(id: '3', title: 'Chinese'),
          ]);
          engine.durationController.add(const Duration(hours: 1));
        });
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
      );

      await controller.start();

      expect(engine.selectedSubtitleTrackIds, ['3']);

      await controller.shutdown();
    },
  );

  test(
    'applies the server-resolved default audio during initial DirectPlay',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, defaultAudioStreamIndex: 2);
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.audioTracksController.add(const [
          EngineTrack(id: '2', language: 'eng', codec: 'aac'),
        ]);
        engine.durationController.add(const Duration(hours: 1));
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
      );

      await controller.start();

      expect(engine.selectedAudioTrackIds, ['2']);
      expect(
        controller.state.audioSelectionStatus,
        AudioSelectionStatus.applied,
      );
      expect(controller.state.appliedAudioStreamIndex, 2);
      await controller.shutdown();
    },
  );

  test(
    'applies an embedded subtitle whose track arrives after ready',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, defaultSubtitleStreamIndex: 3);
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
        Timer.run(
          () => engine.subtitleTracksController.add(const [
            EngineTrack(id: '3', title: 'Chinese'),
          ]),
        );
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
      );

      await controller.start();

      expect(engine.selectedSubtitleTrackIds, ['3']);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
      await controller.shutdown();
    },
  );

  test(
    'enters ready while waiting and applies a late embedded subtitle',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final controller = _controller(
        api: _api([], defaultSubtitleStreamIndex: 3),
        engine: engine,
        item: _plainItem,
        trackWaitTimeout: const Duration(milliseconds: 10),
        lateSubtitleTrackWaitTimeout: const Duration(seconds: 1),
      );

      await controller.start();

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.waitingForTracks,
      );
      expect(engine.selectedSubtitleTrackIds, isEmpty);

      engine.subtitleTracksController.add(const [
        EngineTrack(id: '3', title: 'Chinese'),
      ]);
      await _waitUntil(
        () =>
            controller.state.subtitleSelectionStatus ==
            SubtitleSelectionStatus.appliedEmbedded,
      );

      expect(engine.selectedSubtitleTrackIds, ['3']);
      expect(controller.state.appliedSubtitleStreamIndex, 3);
      await controller.shutdown();
    },
  );

  test('disabling subtitles invalidates a stale late-track event', () async {
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(
      api: _api([], defaultSubtitleStreamIndex: 3),
      engine: engine,
      item: _plainItem,
      trackWaitTimeout: const Duration(milliseconds: 10),
      lateSubtitleTrackWaitTimeout: const Duration(seconds: 1),
    );

    await controller.start();
    expect(
      controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.waitingForTracks,
    );

    await controller.selectSubtitleStream(null);
    engine.subtitleTracksController.add(const [
      EngineTrack(id: '3', title: 'Chinese'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(engine.selectedSubtitleTrackIds, [null]);
    expect(
      controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.disabled,
    );
    await controller.shutdown();
  });

  test('does not select a subtitle when the plan has no default', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(api: api, engine: engine, item: _plainItem);

    await controller.start();

    expect(engine.selectedSubtitleTrackIds, isEmpty);
    expect(
      controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.appliedNone,
    );
    await controller.shutdown();
  });

  test(
    'retries a resolved subtitle that was not applied by the engine',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests, defaultSubtitleStreamIndex: 3);
      final diagnostics = <String>[];
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        trackWaitTimeout: const Duration(milliseconds: 10),
        lateSubtitleTrackWaitTimeout: const Duration(milliseconds: 20),
        diagnostics: _diagnostics(diagnostics),
      );

      await controller.start();
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.waitingForTracks,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
      expect(controller.state.phase, PlaybackPhase.ready);
      expect(
        diagnostics,
        contains(
          'event=playback_subtitle_apply_failed '
          'selectionSource=serverDefault subtitleKind=embedded_or_external '
          'streamIndex=3 generation=1 errorType=TimeoutException',
        ),
      );
      expect(
        diagnostics,
        isNot(contains('event=playback_subtitle_mapping_failed')),
      );

      engine.subtitleTracksController.add(const [
        EngineTrack(id: '3', title: 'Chinese'),
      ]);
      await controller.selectSubtitleStream(3);

      expect(engine.selectedSubtitleTrackIds, ['3']);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
      await controller.shutdown();
    },
  );

  test(
    'marks server-applied subtitles for DirectStream and Transcode',
    () async {
      for (final method in [PlayMethod.directStream, PlayMethod.transcode]) {
        final engine = _FakeEngine();
        engine.onOpen = (_) {
          engine.durationController.add(const Duration(hours: 1));
        };
        final resolver = _PlanResolver(
          _testPlan(
            method: method,
            subtitleStreamIndex: 3,
            mediaStreams: const [
              {
                'Index': 3,
                'Type': 'Subtitle',
                'DisplayTitle': 'Chinese',
                'Title': 'Chinese',
                'DeliveryMethod': 'Encode',
              },
            ],
          ),
        );
        final controller = _controller(
          api: _api([]),
          engine: engine,
          item: _plainItem,
          resolver: resolver,
        );

        await controller.start();

        expect(engine.selectedSubtitleTrackIds, isEmpty);
        expect(
          controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.appliedServer,
        );
        expect(controller.state.appliedSubtitleStreamIndex, 3);
        await controller.shutdown();
      }
    },
  );

  test(
    'loads a default external subtitle once and records its applied state',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 4,
          transportKind: PlaybackTransportKind.offlineLocal,
          mediaStreams: const [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'DisplayTitle': 'Chinese',
              'Title': 'Chinese',
              'Language': 'chi',
              'IsExternal': true,
              'DeliveryUrl': 'file:///subtitle-fixture.srt',
            },
          ],
        ),
      );
      final api = _api([]);
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );

      await controller.start();

      expect(engine.externalSubtitleUris, [
        Uri.parse('file:///subtitle-fixture.srt'),
      ]);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedExternal,
      );
      expect(controller.state.appliedSubtitleStreamIndex, 4);
      await controller.shutdown();
    },
  );

  test(
    'enters ready while waiting and applies a late external subtitle once',
    () async {
      final externalLoad = Completer<void>();
      final engine = _FakeEngine(
        externalSubtitleOperation: externalLoad.future,
      );
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 4,
          transportKind: PlaybackTransportKind.offlineLocal,
          mediaStreams: const [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'DisplayTitle': 'Chinese',
              'Title': 'Chinese',
              'Language': 'chi',
              'IsExternal': true,
              'DeliveryUrl': 'file:///subtitle-fixture.srt',
            },
          ],
        ),
      );
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
        trackWaitTimeout: const Duration(milliseconds: 10),
        lateSubtitleTrackWaitTimeout: const Duration(seconds: 1),
      );

      await controller.start();

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.waitingForTracks,
      );
      expect(engine.externalSubtitleUris, [
        Uri.parse('file:///subtitle-fixture.srt'),
      ]);

      externalLoad.complete();
      await _waitUntil(
        () =>
            controller.state.subtitleSelectionStatus ==
            SubtitleSelectionStatus.appliedExternal,
      );

      expect(engine.externalSubtitleUris, [
        Uri.parse('file:///subtitle-fixture.srt'),
      ]);
      expect(controller.state.appliedSubtitleStreamIndex, 4);
      await controller.shutdown();
    },
  );

  test(
    'external subtitle failure keeps video ready and can be retried',
    () async {
      final engine = _FakeEngine()
        ..externalSubtitleError = StateError('load failed');
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 4,
          transportKind: PlaybackTransportKind.offlineLocal,
          mediaStreams: const [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'IsExternal': true,
              'DeliveryUrl': 'file:///subtitle-fixture.srt',
            },
          ],
        ),
      );
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );

      await controller.start();

      expect(controller.state.phase, PlaybackPhase.ready);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
      expect(engine.externalSubtitleUris, [
        Uri.parse('file:///subtitle-fixture.srt'),
      ]);

      engine.externalSubtitleError = null;
      await controller.selectSubtitleStream(4);

      expect(engine.externalSubtitleUris, [
        Uri.parse('file:///subtitle-fixture.srt'),
        Uri.parse('file:///subtitle-fixture.srt'),
      ]);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedExternal,
      );
      await controller.shutdown();
    },
  );

  test(
    'explicitly disabled subtitles persist through bitrate reconfiguration',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
        engine.subtitleTracksController.add(const [
          EngineTrack(id: '3', title: 'Chinese'),
        ]);
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 3,
          mediaStreams: const [
            {
              'Index': 3,
              'Type': 'Subtitle',
              'DisplayTitle': 'Chinese',
              'Title': 'Chinese',
            },
          ],
        ),
      );
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );

      await controller.start();
      await controller.selectSubtitleStream(null);
      await controller.setMaximumBitrate(10000000);

      expect(engine.selectedSubtitleTrackIds, ['3', null, null]);
      expect(engine.selectedSubtitleOpenCounts, [1, 1, 2]);
      expect(resolver.subtitleDisabledRequests, [false, true]);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.disabled,
      );
      await controller.shutdown();
    },
  );

  test(
    'explicit subtitle selection persists through controlled re-open',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 1));
        engine.subtitleTracksController.add(const [
          EngineTrack(id: '3', title: 'Chinese'),
          EngineTrack(id: '4', title: 'Japanese'),
        ]);
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 3,
          mediaStreams: const [
            {
              'Index': 3,
              'Type': 'Subtitle',
              'DisplayTitle': 'Chinese',
              'Title': 'Chinese',
            },
            {
              'Index': 4,
              'Type': 'Subtitle',
              'DisplayTitle': 'Japanese',
              'Title': 'Japanese',
            },
          ],
        ),
      );
      final controller = _controller(
        api: _api([]),
        engine: engine,
        item: _plainItem,
        resolver: resolver,
      );

      await controller.start();
      await controller.selectSubtitleStream(4);
      await controller.setMaximumBitrate(10000000);

      expect(engine.selectedSubtitleTrackIds, ['3', '4', '4']);
      expect(resolver.subtitleStreamRequests, [null, 4]);
      expect(controller.state.appliedSubtitleStreamIndex, 4);
      await controller.shutdown();
    },
  );

  test(
    'a new media controller follows its own default subtitle selection',
    () async {
      final api = _api([]);
      addTearDown(api.dispose);

      final firstEngine = _FakeEngine();
      firstEngine.onOpen = (_) {
        firstEngine.durationController.add(const Duration(hours: 1));
        firstEngine.subtitleTracksController.add(const [
          EngineTrack(id: '3', title: 'Chinese'),
          EngineTrack(id: '4', title: 'Japanese'),
        ]);
      };
      final firstController = _controller(
        api: api,
        engine: firstEngine,
        item: _plainItem,
        resolver: _PlanResolver(
          _testPlan(
            subtitleStreamIndex: 3,
            mediaStreams: const [
              {
                'Index': 3,
                'Type': 'Subtitle',
                'DisplayTitle': 'Chinese',
                'Title': 'Chinese',
              },
              {
                'Index': 4,
                'Type': 'Subtitle',
                'DisplayTitle': 'Japanese',
                'Title': 'Japanese',
              },
            ],
          ),
        ),
      );

      await firstController.start();
      await firstController.selectSubtitleStream(4);
      expect(firstController.state.appliedSubtitleStreamIndex, 4);
      await firstController.shutdown();

      final secondEngine = _FakeEngine();
      secondEngine.onOpen = (_) {
        secondEngine.durationController.add(const Duration(hours: 1));
        secondEngine.subtitleTracksController.add(const [
          EngineTrack(id: '5', title: 'English'),
        ]);
      };
      final secondController = _controller(
        api: api,
        engine: secondEngine,
        item: _nextItem,
        resolver: _PlanResolver(
          _testPlan(
            subtitleStreamIndex: 5,
            mediaStreams: const [
              {
                'Index': 5,
                'Type': 'Subtitle',
                'DisplayTitle': 'English',
                'Title': 'English',
              },
            ],
          ),
        ),
      );

      await secondController.start();

      expect(
        secondController.state.desiredSubtitleSelection,
        const SubtitleSelection.followServerDefault(),
      );
      expect(secondEngine.selectedSubtitleTrackIds, ['5']);
      expect(secondController.state.appliedSubtitleStreamIndex, 5);
      await secondController.shutdown();
    },
  );

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

  test('startup failure cleanup obeys stop and reporter deadlines', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final diagnostics = <String>[];
    final engine = _FakeEngine(stopOperation: Completer<void>().future)
      ..openError = StateError('open failed');
    final reporter = _BlockingReporter();
    final controller = PlaybackController(
      item: _plainItem,
      engine: engine,
      resolver: EmbyStreamResolver(api),
      reporter: reporter,
      playbackHeaders: api.playbackHeaders,
      stopTimeout: const Duration(milliseconds: 10),
      disposeTimeout: const Duration(milliseconds: 10),
      reporterTimeout: const Duration(milliseconds: 10),
      diagnostics: _diagnostics(diagnostics),
      progressInterval: const Duration(hours: 1),
    );

    await controller.start().timeout(const Duration(milliseconds: 300));

    expect(controller.state.phase, PlaybackPhase.failed);
    expect(engine.openPlayValues, hasLength(2));
    expect(engine.stopCalls, 2);
    expect(engine.disposeCalls, 1);
    expect(reporter.stopCalls, 2);
    expect(
      diagnostics,
      contains('event=playback_operation_timeout kind=engine_stop'),
    );
    expect(
      diagnostics,
      contains('event=playback_operation_timeout kind=reporter_stop'),
    );
    await controller.shutdown().timeout(const Duration(milliseconds: 300));
  });

  test(
    'a blocked engine open times out and rejects late engine events',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final diagnostics = <String>[];
      final openGate = Completer<void>();
      final engine = _FakeEngine(openOperation: openGate.future);
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(hours: 3));
        engine.positionController.add(const Duration(minutes: 45));
      };
      final controller = PlaybackController(
        item: _plainItem,
        engine: engine,
        resolver: EmbyStreamResolver(api),
        reporter: PlaybackSessionReporter(api: api, item: _plainItem),
        playbackHeaders: api.playbackHeaders,
        openTimeout: const Duration(milliseconds: 10),
        diagnostics: _diagnostics(diagnostics),
        progressInterval: const Duration(hours: 1),
      );

      await controller.start().timeout(const Duration(milliseconds: 300));

      expect(controller.state.phase, PlaybackPhase.failed);
      expect(engine.openPlayValues, hasLength(1));
      expect(
        diagnostics,
        contains('event=playback_operation_timeout kind=engine_open'),
      );
      openGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.state.duration, Duration.zero);
      expect(controller.state.position, Duration.zero);
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
    'remote strm uses source input and never falls back when readiness fails',
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

      expect(engine.openUris, hasLength(1));
      expect(engine.openUris.single.host, 'upstream.example.test');
      expect(engine.openHeaders.single, isEmpty);
      expect(controller.state.plan?.isSourceDirect, isTrue);
      expect(controller.state.phase, PlaybackPhase.failed);
      final metadata = requests
          .where((r) => r.path.endsWith('/PlaybackInfo'))
          .toList();
      expect(metadata, hasLength(1));
      expect(metadata.single.data['EnableDirectStream'], false);
      expect(metadata.single.data['EnableTranscoding'], false);

      await controller.shutdown();
    },
  );

  test(
    'fatal stream logs fall back immediately and stop failed transcode',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
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
    final diagnostics = <String>[];
    final engine = _FakeEngine();
    final controller = _controller(
      api: api,
      engine: engine,
      item: _plainItem,
      readyTimeout: const Duration(seconds: 1),
      diagnostics: _diagnostics(diagnostics),
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
    expect(
      diagnostics.where(
        (line) => line.contains('event=playback_cache_session_summary'),
      ),
      hasLength(1),
    );
  });

  test('late subtitle tracks after shutdown cannot call the engine', () async {
    final engine = _FakeEngine();
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(hours: 1));
    };
    final controller = _controller(
      api: _api([]),
      engine: engine,
      item: _plainItem,
      trackWaitTimeout: const Duration(seconds: 1),
    );
    final waitingForReady = Completer<void>();
    controller.addListener(() {
      if (controller.state.phase == PlaybackPhase.waitingForReady &&
          !waitingForReady.isCompleted) {
        waitingForReady.complete();
      }
    });

    final startup = controller.start();
    await waitingForReady.future.timeout(const Duration(milliseconds: 300));
    await Future<void>.delayed(Duration.zero);
    final shutdown = controller.shutdown();
    engine.subtitleTracksController.add(const [
      EngineTrack(id: '3', title: 'Chinese'),
    ]);
    await Future.wait([startup, shutdown]);
    engine.subtitleTracksController.add(const [
      EngineTrack(id: '3', title: 'Chinese'),
    ]);

    expect(engine.selectedSubtitleTrackIds, isEmpty);
    expect(controller.state.phase, PlaybackPhase.idle);
    controller.dispose();
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
      final diagnostics = <String>[];
      engine.onOpen = (_) {
        engineLater(
          () => engine.durationController.add(const Duration(hours: 1)),
        );
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        diagnostics: _diagnostics(diagnostics),
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
      final seekLines = diagnostics
          .where((line) => line.contains('event=playback_seek_'))
          .toList();
      expect(seekLines, hasLength(3));
      expect(seekLines, contains('event=playback_seek_requested count=100'));
      expect(seekLines, contains('event=playback_seek_coalesced count=98'));
      expect(seekLines, contains('event=playback_seek_executed count=2'));
    },
  );

  test(
    'shutdown deadlines do not leave the controller route-blocking',
    () async {
      final diagnostics = <String>[];
      var disposalUnconfirmed = 0;
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
        shutdownBarrierTimeout: const Duration(milliseconds: 40),
        reporterTimeout: const Duration(milliseconds: 10),
        diagnostics: _diagnostics(diagnostics),
        onEngineDisposalUnconfirmed: () => disposalUnconfirmed++,
      );

      await controller.shutdown().timeout(const Duration(milliseconds: 200));

      expect(engine.stopCalls, 1);
      expect(engine.disposeCalls, 1);
      expect(reporter.stopCalls, 1);
      expect(controller.state.phase, PlaybackPhase.idle);
      expect(controller.retirementState, PlaybackRetirementState.quarantined);
      expect(disposalUnconfirmed, 1);
      expect(
        diagnostics,
        contains('event=playback_operation_timeout kind=reporter_stop'),
      );
      expect(
        diagnostics,
        contains('event=playback_operation_timeout kind=engine_stop'),
      );
      expect(
        diagnostics,
        contains('event=playback_operation_timeout kind=engine_dispose'),
      );
      controller.dispose();
    },
  );

  test(
    'poisoned inline lease rejects creation before Player allocation',
    () async {
      final lease = InlinePlaybackResourceLease();
      final handle = lease.acquire();
      lease.poison(handle);
      var playerFactoryCalls = 0;
      final api = _api([]);
      addTearDown(api.dispose);

      await expectLater(
        MediaKitInlinePlaybackSession.create(
          api: api,
          item: _plainItem,
          settings: const PlaybackSettings(),
          resourceLease: lease,
          playerFactory: () {
            playerFactoryCalls++;
            throw StateError('Player factory must not run');
          },
        ),
        throwsStateError,
      );

      expect(lease.isPoisoned, isTrue);
      expect(playerFactoryCalls, 0);
    },
  );

  test('automatic open budget exhaustion is fixed and path-free', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final diagnostics = <String>[];
    final session = PlaybackItemSession.forTest('sensitive-session-id');
    for (final reason in AutomaticPlaybackOpenReason.values.take(
      PlaybackItemSession.maximumAutomaticOpenCount,
    )) {
      expect(session.tryReserveAutomaticOpen(reason), isTrue);
    }
    final controller = _controller(
      api: api,
      engine: _FakeEngine(),
      item: _plainItem,
      session: session,
      diagnostics: _diagnostics(diagnostics),
    );

    await expectLater(controller.start(), throwsStateError);

    expect(
      diagnostics,
      contains(
        'event=playback_automatic_open_budget_exhausted '
        'reason=initial automaticOpenCount=5_6',
      ),
    );
    expect(diagnostics.join('\n'), isNot(contains('sensitive-session-id')));
    await controller.shutdown();
  });

  test('shutdown cancels an outstanding seek and logs one aggregate', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final diagnostics = <String>[];
    final seekGate = Completer<void>();
    final engine = _FakeEngine(seekOperation: seekGate.future);
    engine.onOpen = (_) {
      engineLater(
        () => engine.durationController.add(const Duration(hours: 1)),
      );
    };
    final controller = _controller(
      api: api,
      engine: engine,
      item: _plainItem,
      diagnostics: _diagnostics(diagnostics),
    );
    await controller.start();

    final seek = controller.seekAbsolute(
      const Duration(minutes: 30),
      source: SeekSource.remote,
    );
    await Future<void>.delayed(Duration.zero);
    var shutdownCompleted = false;
    final shutdown = controller.shutdown().then(
      (_) => shutdownCompleted = true,
    );
    final result = await seek;

    expect(result.disposition, SeekDisposition.cancelled);
    await Future<void>.delayed(Duration.zero);
    expect(shutdownCompleted, isFalse);
    expect(engine.stopCalls, 0);
    expect(engine.disposeCalls, 0);

    seekGate.complete();
    await shutdown;
    expect(shutdownCompleted, isTrue);
    expect(diagnostics, contains('event=playback_seek_cancelled count=1'));
    expect(
      diagnostics,
      contains(
        allOf(
          contains('event=playback_cache_session_summary'),
          contains('seekRequestedCount=1'),
          contains('seekCancelledCount=1'),
        ),
      ),
    );
    expect(controller.state.phase, PlaybackPhase.idle);
  });

  test(
    'final startup failure writes one terminal summary before shutdown',
    () async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final diagnostics = <String>[];
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engineLater(() => engine.errorController.add('codec decoder failed'));
      };
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        diagnostics: _diagnostics(diagnostics),
        readyTimeout: const Duration(milliseconds: 100),
      );

      await controller.start();
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(engine.disposeCalls, 1);
      expect(
        diagnostics.where(
          (line) => line.contains('event=playback_cache_session_summary'),
        ),
        hasLength(1),
      );

      await controller.shutdown();
      expect(engine.disposeCalls, 1);
      expect(
        diagnostics.where(
          (line) => line.contains('event=playback_cache_session_summary'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'inline media kit session forwards quiescence APIs distinctly',
    () async {
      final controller = _LifecycleSpyPlaybackController();
      final session = MediaKitInlinePlaybackSession.forTesting(
        itemId: _plainItem.id,
        controller: controller,
      );

      await session.quiesce();
      await session.quiesceForLifecycle();
      await session.pauseForLifecycle();
      await session.resumeForLifecycle();
      await session.pause();

      expect(controller.calls, [
        'quiesce',
        'quiesceForLifecycle',
        'pauseForLifecycle',
        'resumeForLifecycle',
        'pause',
      ]);
      await session.shutdown();
      expect(controller.shutdownCalls, 1);
    },
  );
}

void _subtitleRegressionTests() {
  const pseudo = [EngineTrack(id: 'auto'), EngineTrack(id: 'no')];
  const real = [EngineTrack(id: '42', language: 'zho', codec: 'subrip')];
  group('subtitle regression', () {
    test(
      'cached MKV plan and source agreement cannot authorize SSA ASS compatibility',
      () async {
        final fixture = await _offlineSubtitleCase(
          streams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'IsDefault': true,
              'Language': 'chi',
              'Codec': 'ssa',
            },
          ],
          tracks: const [EngineTrack(id: '42', language: 'zho', codec: 'ass')],
        );
        await fixture.controller.start();
        expect(fixture.engine.selectedSubtitleTrackIds, isEmpty);
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        final line = fixture.logs.singleWhere(
          (line) => line.contains('event=playback_subtitle_mapping_failed'),
        );
        expect(line, contains('serverCodec=ssa'));
        expect(line, contains('track0Codec=ass,ssa,ass,strict'));
        expect(line, contains('planSourceFields=language.same,codec.same'));
        expect(
          line,
          contains('planSourceEvidence=metadataSelfConsistencyOnly'),
        );
        expect(line, contains('nativeSourceIdentity=unverified'));
        expect(fixture.requests, isEmpty);
      },
    );

    test(
      'offline SSA default and manual selection require native Matroska evidence',
      () async {
        final fixture = await _offlineSubtitleCase(
          streams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'IsDefault': true,
              'Language': 'chi',
              'Codec': 'ssa',
            },
          ],
          tracks: const [EngineTrack(id: '42', language: 'zho', codec: 'ass')],
        );
        fixture.engine.subtitleMappingContext = SubtitleMappingContext.fromMpv(
          demuxer: 'mkv',
          tracks: [
            {
              'id': 42,
              'type': 'sub',
              'external': false,
              'lang': 'zho',
              'codec': 'ass',
            },
          ],
        );
        await fixture.controller.start();
        expect(fixture.engine.selectedSubtitleTrackIds, ['42']);
        await fixture.controller.selectSubtitleStream(null);
        await fixture.controller.selectSubtitleStream(2);
        expect(fixture.engine.selectedSubtitleTrackIds, ['42', null, '42']);
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        expect(fixture.requests, isEmpty);
      },
    );

    test(
      'disabling while native identity read is pending prevents stale selection',
      () async {
        final fixture = await _offlineSubtitleCase(tracks: real);
        final gate = Completer<SubtitleMappingContext>();
        fixture.engine.subtitleContextOperation = gate.future;
        final start = fixture.controller.start();
        await _waitUntil(() => fixture.engine.subtitleContextReads > 0);
        final disable = fixture.controller.selectSubtitleStream(null);
        gate.complete(const SubtitleMappingContext.unknown());
        await Future.wait([start, disable]);
        expect(fixture.engine.selectedSubtitleTrackIds, [null]);
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.disabled,
        );
      },
    );

    test(
      'offline default and manual selection use metadata, never Emby index',
      () async {
        final fixture = await _offlineSubtitleCase(tracks: real);
        await fixture.controller.start();
        expect(fixture.engine.selectedSubtitleTrackIds, ['42']);
        await fixture.controller.selectSubtitleStream(null);
        await fixture.controller.selectSubtitleStream(2);
        expect(fixture.engine.selectedSubtitleTrackIds, ['42', null, '42']);
        expect(fixture.controller.state.appliedSubtitleStreamIndex, 2);
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        expect(fixture.requests, isEmpty);
      },
    );

    test('auto no do not finish the initial track wait', () async {
      final fixture = await _offlineSubtitleCase(
        tracks: pseudo,
        trackWaitTimeout: const Duration(milliseconds: 200),
      );
      var finished = false;
      final start = fixture.controller.start().then((_) => finished = true);
      await _waitUntil(() => fixture.engine.openUris.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, isFalse);
      fixture.engine.subtitleTracksController.add(real);
      await start;
      expect(fixture.engine.selectedSubtitleTrackIds, ['42']);
    });

    test(
      'real tracks after initial timeout apply once despite repeated events',
      () async {
        final fixture = await _offlineSubtitleCase(tracks: pseudo);
        await fixture.controller.start();
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.waitingForTracks,
        );
        fixture.engine.subtitleTracksController.add(pseudo);
        fixture.engine.subtitleTracksController.add(real);
        fixture.engine.subtitleTracksController.add(real);
        await _waitUntil(
          () =>
              fixture.controller.state.subtitleSelectionStatus ==
              SubtitleSelectionStatus.appliedEmbedded,
        );
        fixture.engine.subtitleTracksController.add(real);
        await Future<void>.delayed(Duration.zero);
        expect(fixture.engine.selectedSubtitleTrackIds, ['42']);
      },
    );

    test(
      'disabled late selection never writes after a real track arrives',
      () async {
        final fixture = await _offlineSubtitleCase(tracks: pseudo);
        await fixture.controller.start();
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.waitingForTracks,
        );
        await fixture.controller.selectSubtitleStream(null);
        fixture.engine.subtitleTracksController.add(real);
        await Future<void>.delayed(Duration.zero);
        expect(fixture.engine.selectedSubtitleTrackIds, [null]);
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.disabled,
        );
      },
    );

    test(
      'shutdown and next media cannot revive the old late selection',
      () async {
        final first = await _offlineSubtitleCase(tracks: pseudo);
        await first.controller.start();
        expect(
          first.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.waitingForTracks,
        );
        await first.controller.shutdown();
        final next = await _offlineSubtitleCase(tracks: real);
        await next.controller.start();
        first.engine.subtitleTracksController.add(real);
        await Future<void>.delayed(Duration.zero);
        expect(first.engine.selectedSubtitleTrackIds, isEmpty);
        expect(next.engine.selectedSubtitleTrackIds, ['42']);
      },
    );

    test(
      'manual selection supersedes pending default without duplicate application',
      () async {
        final fixture = await _offlineSubtitleCase(
          tracks: pseudo,
          streams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'IsDefault': true,
              'Language': 'chi',
              'Codec': 'srt',
            },
            {'Index': 3, 'Type': 'Subtitle', 'Language': 'eng', 'Codec': 'srt'},
          ],
        );
        await fixture.controller.start();
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.waitingForTracks,
        );
        final selection = fixture.controller.selectSubtitleStream(3);
        fixture.engine.subtitleTracksController.add(const [
          ...real,
          EngineTrack(id: '9', language: 'en', codec: 'subrip'),
        ]);
        await selection;
        await Future<void>.delayed(Duration.zero);
        expect(fixture.engine.selectedSubtitleTrackIds, ['9']);
        expect(fixture.controller.state.appliedSubtitleStreamIndex, 3);
      },
    );

    test('ambiguity fails with bounded safe mapping evidence', () async {
      final fixture = await _offlineSubtitleCase(
        tracks: const [
          EngineTrack(id: '2', language: 'chi', codec: 'subrip'),
          EngineTrack(id: '42', language: 'zho', codec: 'srt'),
        ],
      );
      await fixture.controller.start();
      expect(fixture.engine.selectedSubtitleTrackIds, isEmpty);
      expect(
        fixture.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
      final line = fixture.logs.singleWhere(
        (line) => line.contains('event=playback_subtitle_mapping_failed'),
      );
      expect(line, contains('mappingResult=ambiguous'));
      expect(line, contains('realTrackCount=2'));
      expect(line, contains('candidateCount=2'));
      expect(line, contains('mappingReason=multipleCandidates'));
    });

    test(
      'conflicts report field names without raw title language codec or URI',
      () async {
        const privateValue =
            'https://fixture.invalid/private-title?token=fixture-secret';
        final fixture = await _offlineSubtitleCase(
          streams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'IsDefault': true,
              'Title': privateValue,
              'DisplayTitle': 'private-display-label',
              'Language': 'private-language',
              'Codec': 'private-codec',
            },
          ],
          tracks: const [
            EngineTrack(
              id: '42',
              title: 'different',
              language: 'private-language',
              codec: 'private-codec',
            ),
          ],
        );
        await fixture.controller.start();
        expect(fixture.engine.selectedSubtitleTrackIds, isEmpty);
        final line = fixture.logs.singleWhere(
          (line) => line.contains('event=playback_subtitle_mapping_failed'),
        );
        expect(line, contains('mappingResult=unavailable'));
        expect(line, contains('mappingReason=metadataConflict'));
        expect(line, contains('conflictFields=title'));
        expect(
          line,
          contains('serverFields=language,codec,title,displayTitle'),
        );
        expect(line, contains('engineFields=language,codec,title'));
        expect(line, contains('conflictFieldsScope=allTracksUnion'));
        expect(
          line,
          contains(
            'track0=rejected:language.same,codec.same,title.conflict,channels.missingBoth',
          ),
        );
        expect(line, contains('planTransport=offlineLocal'));
        expect(line, contains('planInput=file'));
        expect(line, contains('selectedSourceLookup=unique'));
        expect(line, contains('selectedSourceStreamLookup=unique'));
        expect(
          line,
          contains(
            'planSourceFields=language.same,codec.same,title.same,channels.missingBoth',
          ),
        );
        expect(line, contains('nativeSourceIdentity=unverified'));
        for (final raw in [
          privateValue,
          'private-display-label',
          'private-language',
          'private-codec',
          'fixture-secret',
        ]) {
          expect(fixture.logs.join('\n'), isNot(contains(raw)));
        }
      },
    );

    test('no real track eventually fails with noTracks evidence', () async {
      final fixture = await _offlineSubtitleCase(
        tracks: pseudo,
        lateTimeout: const Duration(milliseconds: 20),
      );
      await fixture.controller.start();
      expect(
        fixture.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.waitingForTracks,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        fixture.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
      expect(
        fixture.logs,
        contains(
          allOf(
            contains('mappingReason=noTracks'),
            contains('realTrackCount=0'),
            contains('candidateCount=0'),
          ),
        ),
      );
    });

    test(
      'external metadata without location never selects embedded track',
      () async {
        final fixture = await _offlineSubtitleCase(
          tracks: const [EngineTrack(id: '42', language: 'chi', codec: 'srt')],
          streams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'IsDefault': true,
              'IsExternal': true,
              'OfflineSubtitleState': 'available',
              'Language': 'chi',
              'Codec': 'srt',
            },
          ],
        );
        await fixture.controller.start();
        expect(fixture.engine.selectedSubtitleTrackIds, isEmpty);
        expect(fixture.engine.externalSubtitleUris, isEmpty);
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.failed,
        );
        expect(
          fixture.logs,
          contains(
            allOf(
              contains('subtitleKind=external'),
              contains('mappingReason=externalLocationMissing'),
            ),
          ),
        );
      },
    );

    test(
      'downloaded external subtitle remains a local file with no online request',
      () async {
        final fixture = await _offlineSubtitleCase(
          tracks: pseudo,
          externalFile: true,
        );
        await fixture.controller.start();
        expect(fixture.engine.externalSubtitleUris, [fixture.subtitleFile.uri]);
        expect(fixture.engine.selectedSubtitleTrackIds, isEmpty);
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.appliedExternal,
        );
        expect(fixture.requests, isEmpty);
      },
    );
  });
}

Future<
  ({
    PlaybackController controller,
    _FakeEngine engine,
    List<String> logs,
    List<RequestOptions> requests,
    File subtitleFile,
  })
>
_offlineSubtitleCase({
  required List<EngineTrack> tracks,
  List<Map<String, dynamic>>? streams,
  bool externalFile = false,
  Duration trackWaitTimeout = const Duration(milliseconds: 10),
  Duration lateTimeout = const Duration(seconds: 1),
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'emby-subtitle-regression-',
  );
  addTearDown(() async {
    expect(
      directory.absolute.path,
      startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
      ),
    );
    await directory.delete(recursive: true);
  });
  final video = File('${directory.path}${Platform.pathSeparator}fixture.mkv');
  await video.writeAsBytes([1, 2, 3, 4]);
  final subtitle = File(
    '${directory.path}${Platform.pathSeparator}local subtitle.srt',
  );
  await subtitle.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nfixture\n');
  final offline = OfflineMediaItem(
    scope: const ServerScope(
      serverId: 'fixture-server',
      userId: 'fixture-user',
    ),
    itemId: 'fixture-item',
    mediaSourceId: 'fixture-source',
    metadata: OfflineMediaMetadata(
      name: 'fixture',
      itemType: 'Movie',
      container: 'mkv',
      mediaStreams:
          streams ??
          [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'IsDefault': true,
              'DisplayTitle': 'Chinese - Simplified - Default (SRT)',
              'Language': 'chi',
              'Codec': 'srt',
              if (externalFile) ...{
                'IsExternal': true,
                'DeliveryUrl': subtitle.path,
                'OfflineSubtitleState': 'available',
              },
            },
          ],
    ),
    localMediaPath: video.path,
    completedAt: DateTime.utc(2026, 10, 14),
  );
  final engine = _FakeEngine();
  engine.onOpen = (_) {
    engine.subtitleTracksController.add(tracks);
    engine.durationController.add(const Duration(hours: 1));
  };
  final requests = <RequestOptions>[];
  final api = _api(requests);
  addTearDown(api.dispose);
  final logs = <String>[];
  final controller = _controller(
    api: api,
    engine: engine,
    item: offline.toEmbyItem(),
    resolver: OfflinePlaybackResolver(offline),
    reporter: OfflinePlaybackReporter(
      item: offline,
      writeProgress: (_, _) async {},
    ),
    diagnostics: _diagnostics(logs),
    trackWaitTimeout: trackWaitTimeout,
    lateSubtitleTrackWaitTimeout: lateTimeout,
  );
  addTearDown(controller.shutdown);
  return (
    controller: controller,
    engine: engine,
    logs: logs,
    requests: requests,
    subtitleFile: subtitle,
  );
}

class _LifecycleSpyPlaybackController extends PlaybackController {
  _LifecycleSpyPlaybackController()
    : super(
        item: _plainItem,
        engine: _FakeEngine(),
        resolver: _PlanResolver(_testPlan()),
        reporter: _BlockingReporter(),
        playbackHeaders: const {},
      );

  final List<String> calls = [];
  int shutdownCalls = 0;
  bool _shutdown = false;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> quiesce() async => calls.add('quiesce');

  @override
  Future<void> quiesceForLifecycle() async => calls.add('quiesceForLifecycle');

  @override
  Future<void> pauseForLifecycle() async => calls.add('pauseForLifecycle');

  @override
  Future<void> resumeForLifecycle() async => calls.add('resumeForLifecycle');

  @override
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    shutdownCalls++;
  }
}

PlaybackController _controller({
  ExternalSubtitleLoader? subtitleLoader,
  required EmbyApi api,
  required _FakeEngine engine,
  required EmbyItem item,
  Duration readyTimeout = const Duration(seconds: 1),
  Duration? sourceReadyIdleTimeout,
  Duration trackWaitTimeout = const Duration(seconds: 2),
  Duration lateSubtitleTrackWaitTimeout = const Duration(seconds: 8),
  Duration seekCallTimeout = const Duration(seconds: 8),
  Duration playPauseTimeout = const Duration(seconds: 3),
  Duration propertyWriteTimeout = const Duration(seconds: 2),
  Duration lifecycleQuiesceTimeout = const Duration(seconds: 2),
  Duration retirementQuiesceTimeout = const Duration(seconds: 3),
  Duration shutdownBarrierTimeout = const Duration(seconds: 5),
  Duration stopTimeout = const Duration(seconds: 5),
  Duration disposeTimeout = const Duration(seconds: 5),
  PlaybackEngineDisposalUnconfirmed? onEngineDisposalUnconfirmed,
  PlaybackDiagnostics? diagnostics,
  PlaybackItemSession? session,
  PlaybackStreamResolver? resolver,
  PlaybackReporter? reporter,
}) => PlaybackController(
  subtitleLoader: subtitleLoader,
  item: item,
  engine: engine,
  resolver: resolver ?? EmbyStreamResolver(api),
  reporter: reporter ?? PlaybackSessionReporter(api: api, item: item),
  playbackHeaders: api.playbackHeaders,
  readyTimeout: readyTimeout,
  sourceReadyIdleTimeout: sourceReadyIdleTimeout ?? readyTimeout,
  sourceReadyTimeout: const Duration(seconds: 3),
  trackWaitTimeout: trackWaitTimeout,
  lateSubtitleTrackWaitTimeout: lateSubtitleTrackWaitTimeout,
  seekCallTimeout: seekCallTimeout,
  playPauseTimeout: playPauseTimeout,
  propertyWriteTimeout: propertyWriteTimeout,
  lifecycleQuiesceTimeout: lifecycleQuiesceTimeout,
  retirementQuiesceTimeout: retirementQuiesceTimeout,
  shutdownBarrierTimeout: shutdownBarrierTimeout,
  stopTimeout: stopTimeout,
  disposeTimeout: disposeTimeout,
  onEngineDisposalUnconfirmed: onEngineDisposalUnconfirmed,
  diagnostics: diagnostics,
  session: session,
  resumeVerificationTimeout: const Duration(milliseconds: 100),
  progressInterval: const Duration(hours: 1),
);

PlaybackDiagnostics _diagnostics(List<String> lines) => PlaybackDiagnostics(
  writer: (_, _, message) => lines.add(message),
  seekFlushInterval: const Duration(hours: 1),
);

class _PlanResolver implements PlaybackStreamResolver {
  _PlanResolver(this.plan, {this.sourcePlans = const {}});

  final PlaybackPlan plan;
  final Map<String, PlaybackPlan> sourcePlans;
  final List<int?> subtitleStreamRequests = [];
  final List<bool> subtitleDisabledRequests = [];
  final List<int?> audioStreamRequests = [];
  final List<String?> sourceRequests = [];
  String? failSource;

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
  }) async {
    subtitleStreamRequests.add(subtitleStreamIndex);
    subtitleDisabledRequests.add(subtitleDisabled);
    audioStreamRequests.add(audioStreamIndex);
    sourceRequests.add(mediaSourceId);
    if (mediaSourceId != null && mediaSourceId == failSource) {
      throw StateError('Synthetic unavailable source');
    }
    final sourcePlan = sourcePlans[mediaSourceId] ?? plan;
    return sourcePlan.copyWith(
      mediaSourceId: mediaSourceId,
      method: forceTranscode ? PlayMethod.transcode : sourcePlan.method,
      audioStreamIndex: audioStreamIndex ?? sourcePlan.audioStreamIndex,
      clearSubtitleStreamIndex: subtitleDisabled,
      subtitleStreamIndex: subtitleDisabled
          ? null
          : subtitleStreamIndex ?? sourcePlan.subtitleStreamIndex,
      subtitleDisabled: subtitleDisabled,
    );
  }

  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
}

PlaybackPlan _testPlan({
  PlayMethod method = PlayMethod.directPlay,
  PlaybackTransportKind transportKind = PlaybackTransportKind.unknown,
  int? subtitleStreamIndex,
  List<Map<String, dynamic>> mediaStreams = const [],
}) => PlaybackPlan(
  uri: Uri.parse('https://media.example.test/video'),
  transportKind: transportKind,
  mediaSourceId: 'source-1',
  playSessionId: 'play-session',
  method: method,
  usesServerAuthentication: false,
  subtitleStreamIndex: subtitleStreamIndex,
  mediaStreams: mediaStreams,
  transcodingReasons: const [],
  availableMediaSources: const [],
);

EmbyApi _api(
  List<RequestOptions> requests, {
  bool remoteStrm = false,
  int? defaultAudioStreamIndex,
  int? defaultSubtitleStreamIndex,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        if (options.method == 'GET' && options.path.contains('/Users/')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'Id': options.path.split('/').last,
                'MediaSources': [
                  {
                    'Id': 'source-1',
                    'Protocol': 'File',
                    'Path': remoteStrm
                        ? '/media/movie.strm'
                        : '/media/movie.mkv',
                    'Container': remoteStrm ? 'strm' : 'mkv',
                  },
                ],
              },
            ),
          );
          return;
        }
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
                        ? 'https://upstream.example.test/movie.mp4'
                        : null,
                    'Protocol': remoteStrm ? 'Http' : 'File',
                    'Container': remoteStrm ? 'strm' : 'mkv',
                    'SupportsDirectPlay': !remoteStrm,
                    'SupportsDirectStream': false,
                    'SupportsTranscoding': true,
                    'TranscodingUrl': '/Videos/item/master.m3u8',
                    'DefaultAudioStreamIndex': ?defaultAudioStreamIndex,
                    'DefaultSubtitleStreamIndex': ?defaultSubtitleStreamIndex,
                    'MediaStreams': [
                      if (defaultAudioStreamIndex != null)
                        {
                          'Index': defaultAudioStreamIndex,
                          'Type': 'Audio',
                          'DisplayTitle': 'Original',
                          'Title': 'Original',
                          'Language': 'eng',
                          'Codec': 'aac',
                        },
                      if (defaultSubtitleStreamIndex != null)
                        {
                          'Index': defaultSubtitleStreamIndex,
                          'Type': 'Subtitle',
                          'DisplayTitle': 'Chinese',
                          'Title': 'Chinese',
                          'Language': 'chi',
                          'Codec': 'ass',
                        },
                    ],
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

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for asynchronous test condition');
}

class _FakeEngine
    implements
        PlaybackEngine,
        SourceDirectPlaybackEngine,
        SubtitleMappingContextProvider,
        PlaybackNativeResourceOwner {
  SubtitleMappingContext subtitleMappingContext =
      const SubtitleMappingContext.unknown();
  Future<SubtitleMappingContext>? subtitleContextOperation;
  int subtitleContextReads = 0;
  @override
  Future<SubtitleMappingContext> readSubtitleMappingContext() {
    subtitleContextReads++;
    return subtitleContextOperation ?? Future.value(subtitleMappingContext);
  }

  final externalSubtitleEntered = Completer<void>();
  final List<Future<void> Function()> resources = [];
  @override
  void retainUntilNativeDisposal(Future<void> Function() release) =>
      resources.add(release);
  @override
  Future<void> openSource(
    PlaybackResourceRequest request, {
    required bool play,
  }) => open(Uri.parse(request.rawUrl), headers: request.headers, play: play);
  _FakeEngine({
    this.openOperation,
    this.playOperation,
    this.pauseOperation,
    this.quiesceOperation,
    this.lifecycleQuiesceOperation,
    this.stopOperation,
    this.disposeOperation,
    this.seekOperation,
    this.externalSubtitleOperation,
  });

  final Future<void>? openOperation;
  final Future<void>? playOperation;
  final Future<void>? pauseOperation;
  final Future<void>? quiesceOperation;
  final Future<void>? lifecycleQuiesceOperation;
  final Future<void>? stopOperation;
  final Future<void>? disposeOperation;
  final Future<void>? seekOperation;
  final Future<void>? externalSubtitleOperation;
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
  final List<String> selectedAudioTrackIds = [];
  final List<String?> selectedSubtitleTrackIds = [];
  final List<int> selectedSubtitleOpenCounts = [];
  final List<Uri> externalSubtitleUris = [];
  String? actualSubtitle;
  final List<String> nativeSubtitleEffects = [];
  final List<double> rateValues = [];
  final List<Duration> audioDelayValues = [];
  final List<Duration> subtitleDelayValues = [];
  final List<(double, int, int, int)> subtitleStyleValues = [];
  bool emitPlayingOnPlay = true;
  int playCalls = 0;
  int pauseCalls = 0;
  int quiesceCalls = 0;
  int lifecycleQuiesceCalls = 0;
  int lifecycleQuiescenceResumeCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int _quiescenceEpoch = 0;
  bool _retiring = false;
  bool _lifecycleQuiesced = false;
  Object? openError;
  Object? externalSubtitleError;

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
    await openOperation;
    onOpen?.call(openPlayValues.length);
  }

  @override
  Future<void> play() async {
    playCalls++;
    final epoch = _quiescenceEpoch;
    await playOperation;
    if (_retiring || _lifecycleQuiesced || epoch != _quiescenceEpoch) return;
    if (emitPlayingOnPlay) playingController.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playingController.add(false);
    await pauseOperation;
  }

  @override
  Future<void> quiesce() async {
    quiesceCalls++;
    _retiring = true;
    _quiescenceEpoch++;
    playingController.add(false);
    await quiesceOperation;
  }

  @override
  Future<void> quiesceForLifecycle() async {
    lifecycleQuiesceCalls++;
    _lifecycleQuiesced = true;
    _quiescenceEpoch++;
    playingController.add(false);
    await lifecycleQuiesceOperation;
  }

  @override
  Future<void> resumeFromLifecycleQuiescence() async {
    lifecycleQuiescenceResumeCalls++;
    _lifecycleQuiesced = false;
    _quiescenceEpoch++;
  }

  @override
  Future<void> seek(Duration position) async {
    seekValues.add(position);
    final epoch = _quiescenceEpoch;
    await seekOperation;
    if (_retiring || _lifecycleQuiesced || epoch != _quiescenceEpoch) return;
    positionController.add(position);
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    selectedAudioTrackIds.add(trackId);
  }

  Future<void> Function(String?)? onSubtitleWrite;
  @override
  Future<void> selectSubtitleTrack(String? trackId) async {
    selectedSubtitleTrackIds.add(trackId);
    await onSubtitleWrite?.call(trackId);
    selectedSubtitleOpenCounts.add(openPlayValues.length);
    actualSubtitle = trackId;
    nativeSubtitleEffects.add(trackId ?? 'off');
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {
    externalSubtitleUris.add(uri);
    if (!externalSubtitleEntered.isCompleted) {
      externalSubtitleEntered.complete();
    }
    if (externalSubtitleError != null) throw externalSubtitleError!;
    await externalSubtitleOperation;
    actualSubtitle = uri.toString();
    nativeSubtitleEffects.add('external');
  }

  @override
  Future<void> setRate(double rate) async => rateValues.add(rate);

  @override
  Future<void> setAudioDelay(Duration delay) async =>
      audioDelayValues.add(delay);

  @override
  Future<void> setSubtitleDelay(Duration delay) async =>
      subtitleDelayValues.add(delay);

  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async =>
      subtitleStyleValues.add((fontSize, color, outlineColor, position));

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
    for (final release in resources) {
      await release();
    }
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
  Future<void> reportStart(Duration position, {required bool isPaused}) async {}

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
    bool subtitleDisabled = false,
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

const _nextItem = EmbyItem(
  id: 'item-2',
  name: 'Episode 2',
  type: 'Episode',
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

void _deliveryRegressionTests() {
  for (final (format, codec) in [('vtt', 'webvtt'), ('srt', 'subrip')]) {
    test('declared Embed format $format identifies output codec $codec', () {
      final plan = _testPlan(method: PlayMethod.transcode);
      final track = PlaybackTrack(
        index: 42,
        type: 'Subtitle',
        codec: 'hdmv_pgs_subtitle',
        deliveryMethod: 'Embed',
        format: format,
      );
      final match = const TrackMapper().match(track.mappingTrack(plan), [
        EngineTrack(id: '83', codec: codec),
      ]);
      expect(match.engineId, '83');
      expect(
        const TrackMapper().match(track, [
          EngineTrack(id: '83', codec: codec),
        ]).engineId,
        isNull,
      );
    });
  }
  test(
    'delivery regression Embed matches declared output Format without guessing index',
    () async {
      final engine = _FakeEngine();
      engine.onOpen = (_) {
        engine.durationController.add(const Duration(minutes: 1));
        engine.subtitleTracksController.add(const [
          EngineTrack(id: '83', language: 'eng', codec: 'ass'),
        ]);
      };
      final api = _api([]);
      addTearDown(api.dispose);
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        resolver: _PlanResolver(
          _testPlan(
            method: PlayMethod.transcode,
            subtitleStreamIndex: 42,
            mediaStreams: const [
              {
                'Index': 42,
                'Type': 'Subtitle',
                'Language': 'eng',
                'Codec': 'hdmv_pgs_subtitle',
                'DeliveryMethod': 'Embed',
                'Format': 'ass',
              },
            ],
          ),
        ),
      );
      addTearDown(controller.shutdown);
      await controller.start();
      expect(engine.selectedSubtitleTrackIds, ['83']);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
    },
  );
  for (final mode in ['unauthorized', 'html', 'missing-url', 'offline-http']) {
    test(
      'delivery regression External $mode remains failed with no native load',
      () async {
        final origin = await ProgressiveOrigin.start();
        addTearDown(origin.close);
        origin.intercept = (_) async => (
          status: mode == 'unauthorized' ? 401 : 200,
          headers: <String, String>{},
          body: utf8.encode('<html>not a subtitle</html>'),
        );
        final api = _api([]);
        addTearDown(api.dispose);
        final engine = _FakeEngine();
        engine.onOpen = (_) =>
            engine.durationController.add(const Duration(minutes: 1));
        final controller = _controller(
          api: api,
          engine: engine,
          item: _plainItem,
          subtitleLoader: ExternalSubtitleLoader(api),
          resolver: _PlanResolver(
            _testPlan(
              method: mode == 'offline-http'
                  ? PlayMethod.directPlay
                  : PlayMethod.transcode,
              transportKind: mode == 'offline-http'
                  ? PlaybackTransportKind.offlineLocal
                  : PlaybackTransportKind.unknown,
              subtitleStreamIndex: 42,
              mediaStreams: [
                {
                  'Index': 42,
                  'Type': 'Subtitle',
                  'IsExternal': true,
                  'DeliveryMethod': 'External',
                  if (mode != 'missing-url')
                    'DeliveryUrl': '${origin.origin}/fixture.srt',
                },
              ],
            ),
          ),
        );
        addTearDown(controller.shutdown);
        await controller.start();
        await _waitUntil(
          () =>
              controller.state.subtitleSelectionStatus !=
              SubtitleSelectionStatus.applying,
        );
        expect(controller.state.phase, PlaybackPhase.ready);
        expect(
          controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.failed,
        );
        expect(engine.externalSubtitleUris, isEmpty);
        if (mode == 'offline-http' || mode == 'missing-url') {
          expect(origin.requests, isEmpty);
        }
      },
    );
  }

  for (final delivery in ['Embed', 'Hls', 'unexpected', '']) {
    test(
      'delivery regression transcode $delivery does not imply burned subtitles',
      () async {
        final api = _api([]);
        addTearDown(api.dispose);
        final engine = _FakeEngine();
        engine.onOpen = (_) {
          engine.durationController.add(const Duration(minutes: 1));
          engine.subtitleTracksController.add(const [
            EngineTrack(
              id: '83',
              title: 'fixture-cue',
              language: 'eng',
              codec: 'srt',
            ),
          ]);
        };
        final controller = _controller(
          api: api,
          engine: engine,
          item: _plainItem,
          resolver: _PlanResolver(
            _testPlan(
              method: PlayMethod.transcode,
              subtitleStreamIndex: 2,
              mediaStreams: [
                {
                  'Index': 2,
                  'Type': 'Subtitle',
                  'Title': 'fixture-cue',
                  'Language': 'eng',
                  'Codec': 'srt',
                  'DeliveryMethod': delivery,
                },
              ],
            ),
          ),
        );
        addTearDown(controller.shutdown);
        await controller.start();
        expect(
          controller.state.subtitleSelectionStatus,
          delivery == 'Embed'
              ? SubtitleSelectionStatus.appliedEmbedded
              : SubtitleSelectionStatus.failed,
        );
        expect(
          engine.selectedSubtitleTrackIds,
          delivery == 'Embed' ? ['83'] : isEmpty,
        );
      },
    );
  }
  test(
    'delivery regression transcode External downloads before native load even when embedded source',
    () async {
      final api = _api([]);
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-delivery-test-',
      );
      final file = File('${directory.path}/fixture.srt');
      await file.writeAsString(
        '1\n00:00:00,000 --> 00:00:02,000\nexternal cue\n',
      );
      addTearDown(() async {
        if (await file.exists()) await file.delete();
        if (await directory.exists()) await directory.delete();
      });
      final loader = _DeliveryLoader(api, file);
      final engine = _FakeEngine();
      engine.onOpen = (_) =>
          engine.durationController.add(const Duration(minutes: 1));
      final controller = _controller(
        api: api,
        engine: engine,
        item: _plainItem,
        subtitleLoader: loader,
        resolver: _PlanResolver(
          _testPlan(
            method: PlayMethod.transcode,
            subtitleStreamIndex: 2,
            mediaStreams: const [
              {
                'Index': 2,
                'Type': 'Subtitle',
                'IsExternal': false,
                'DeliveryMethod': 'External',
                'DeliveryUrl': '/Videos/item/source/Subtitles/2/Stream.srt',
                'Format': 'srt',
              },
            ],
          ),
        ),
      );
      addTearDown(controller.shutdown);
      await controller.start();
      await _waitUntil(
        () =>
            controller.state.subtitleSelectionStatus !=
            SubtitleSelectionStatus.applying,
      );
      expect(loader.calls, 1);
      expect(engine.externalSubtitleUris, [file.uri]);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedExternal,
      );
    },
  );
}

class _DeliveryLoader extends ExternalSubtitleLoader {
  _DeliveryLoader(super.api, this.file);
  final File file;
  int calls = 0;
  @override
  Future<SubtitleFileLease> load(
    String raw, {
    required String itemId,
    required String sourceId,
  }) async {
    calls++;
    return SubtitleFileLease(file, () {});
  }
}

void _nativeIdentityRegressionTests() {
  Future<({PlaybackController controller, _EpochEngine engine})>
  fixture() async {
    final api = _api([]);
    addTearDown(api.dispose);
    final engine = _EpochEngine();
    engine.onOpen = (_) {
      engine.durationController.add(const Duration(minutes: 1));
      engine.subtitleTracksController.add(const [
        EngineTrack(id: 'auto'),
        EngineTrack(id: 'no'),
        EngineTrack(id: '81', title: 'same', language: 'eng', codec: 'ass'),
        EngineTrack(id: '82', title: 'same', language: 'eng', codec: 'ass'),
      ]);
    };
    final controller = _controller(
      api: api,
      engine: engine,
      item: _plainItem,
      resolver: _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 2,
          mediaStreams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'Codec': 'hdmv_pgs_subtitle',
              'Title': 'same',
              'Language': 'eng',
            },
          ],
        ),
      ),
    );
    addTearDown(controller.shutdown);
    await controller.start();
    expect(
      controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.failed,
    );
    return (controller: controller, engine: engine);
  }

  test(
    'duplicate native IDs are unavailable even through an older row',
    () async {
      final f = await fixture();
      final old = f.controller.nativeSubtitleChoices.first;
      f.engine.subtitleTracksController.add([old.track, old.track]);
      expect(f.controller.nativeSubtitleChoices, isEmpty);
      await f.controller.selectNativeSubtitle(old);
      expect(f.engine.selectedSubtitleTrackIds, isEmpty);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
    },
  );

  test(
    'native input epoch invalidates an in-flight result and prior rows',
    () async {
      final f = await fixture();
      final old = f.controller.nativeSubtitleChoices.first;
      final completion = Completer<void>();
      f.engine.onSubtitleWrite = (_) => completion.future;
      final selecting = f.controller.selectNativeSubtitle(old);
      await _waitUntil(() => f.engine.selectedSubtitleTrackIds.isNotEmpty);
      f.engine.subtitleInputEpoch++;
      completion.complete();
      await selecting;
      expect(f.controller.state.appliedNativeSubtitleId, isNull);
      await f.controller.selectNativeSubtitle(old);
      expect(f.engine.selectedSubtitleTrackIds, ['81']);
      f.engine.onSubtitleWrite = null;
      await f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.last,
      );
      expect(f.engine.selectedSubtitleTrackIds, ['81', '82']);
      expect(f.controller.state.appliedNativeSubtitleId, '82');
    },
  );

  test(
    'native identity selects real ID despite codec conflict and identical labels after reorder',
    () async {
      final f = await fixture();
      final choices = f.controller.nativeSubtitleChoices;
      expect(choices.map((t) => t.track.id), ['81', '82']);
      f.engine.subtitleTracksController.add(
        choices.reversed.map((t) => t.track).toList(),
      );
      await f.controller.selectNativeSubtitle(choices.last);
      expect(f.engine.selectedSubtitleTrackIds, ['82']);
      expect(f.controller.state.appliedNativeSubtitleId, '82');
      expect(f.controller.state.appliedSubtitleStreamIndex, isNull);
      expect(f.controller.state.plan!.subtitleStreamIndex, isNull);
      f.engine.subtitleTracksController.add([choices.first.track]);
      await f.controller.selectNativeSubtitle(choices.last);
      expect(f.engine.selectedSubtitleTrackIds, ['82']);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
    },
  );

  test(
    'native identity from old input or closed session cannot be selected',
    () async {
      final f = await fixture();
      final old = f.controller.nativeSubtitleChoices.first;
      await f.controller.reconfigure(clearSubtitle: true);
      f.engine.selectedSubtitleTrackIds.clear();
      await f.controller.selectNativeSubtitle(old);
      expect(f.engine.selectedSubtitleTrackIds, isEmpty);
      final current = f.controller.nativeSubtitleChoices.last;
      await f.controller.selectNativeSubtitle(current);
      expect(f.engine.selectedSubtitleTrackIds, ['82']);
      await f.controller.shutdown();
      await f.controller.selectNativeSubtitle(current);
      expect(f.engine.selectedSubtitleTrackIds, ['82']);
    },
  );

  test(
    'native A B A revisions ignore old A failure and serialize real completion',
    () async {
      final f = await fixture();
      final choices = f.controller.nativeSubtitleChoices;
      final first = Completer<void>();
      final last = Completer<void>();
      var calls = 0;
      f.engine.onSubtitleWrite = (_) =>
          ++calls == 1 ? first.future : last.future;
      final a1 = f.controller.selectNativeSubtitle(choices.first);
      await _waitUntil(() => calls == 1);
      final b = f.controller.selectNativeSubtitle(choices.last);
      final a2 = f.controller.selectNativeSubtitle(choices.first);
      first.completeError(StateError('old A failure'));
      await _waitUntil(() => calls == 2);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.applying,
      );
      expect(f.engine.selectedSubtitleTrackIds, ['81', '81']);
      last.complete();
      await Future.wait([a1, b, a2]);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
      expect(f.controller.state.appliedNativeSubtitleId, '81');
      expect(f.controller.state.subtitleSelectionError, isNull);
    },
  );

  test(
    'server A B A late metadata failure cannot overwrite newest A',
    () async {
      final f = await fixture();
      f.engine.subtitleTracksController.add(const [
        EngineTrack(
          id: '81',
          title: 'same',
          language: 'eng',
          codec: 'hdmv_pgs_subtitle',
        ),
      ]);
      final old = Completer<SubtitleMappingContext>();
      f.engine.subtitleContextOperation = old.future;
      final reads = f.engine.subtitleContextReads;
      final a1 = f.controller.selectSubtitleStream(2);
      await _waitUntil(() => f.engine.subtitleContextReads > reads);
      await f.controller.selectSubtitleStream(null);
      f.engine.subtitleContextOperation = null;
      await f.controller.selectSubtitleStream(2);
      old.completeError(StateError('old A metadata failed'));
      await a1;
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
      expect(f.controller.state.appliedSubtitleStreamIndex, 2);
      expect(f.controller.state.subtitleSelectionError, isNull);
    },
  );
}

class _EpochEngine extends _FakeEngine implements SubtitleInputEpochProvider {
  @override
  int subtitleInputEpoch = 0;
}
