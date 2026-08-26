import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/media_kit_inline_playback_session.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_session_bootstrap.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
          engine.subtitleTracksController.add(const [EngineTrack(id: '3')]);
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
          engine.subtitleTracksController.add(const [EngineTrack(id: '3')]);
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
        engine.audioTracksController.add(const [EngineTrack(id: '2')]);
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
          () =>
              engine.subtitleTracksController.add(const [EngineTrack(id: '3')]),
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
        diagnostics: _diagnostics(diagnostics),
      );

      await controller.start();
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

      engine.subtitleTracksController.add(const [EngineTrack(id: '3')]);
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
              {'Index': 3, 'Type': 'Subtitle', 'DisplayTitle': 'Chinese'},
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
          mediaStreams: const [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'DisplayTitle': 'Chinese',
              'Language': 'chi',
              'IsExternal': true,
              'DeliveryUrl': '/subtitles/4.srt',
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

      expect(engine.externalSubtitleUris, [Uri.parse('/subtitles/4.srt')]);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedExternal,
      );
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
          mediaStreams: const [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'IsExternal': true,
              'DeliveryUrl': '/subtitles/4.srt',
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
      expect(engine.externalSubtitleUris, [Uri.parse('/subtitles/4.srt')]);

      engine.externalSubtitleError = null;
      await controller.selectSubtitleStream(4);

      expect(engine.externalSubtitleUris, [
        Uri.parse('/subtitles/4.srt'),
        Uri.parse('/subtitles/4.srt'),
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
        engine.subtitleTracksController.add(const [EngineTrack(id: '3')]);
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 3,
          mediaStreams: const [
            {'Index': 3, 'Type': 'Subtitle', 'DisplayTitle': 'Chinese'},
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
          EngineTrack(id: '3'),
          EngineTrack(id: '4'),
        ]);
      };
      final resolver = _PlanResolver(
        _testPlan(
          subtitleStreamIndex: 3,
          mediaStreams: const [
            {'Index': 3, 'Type': 'Subtitle', 'DisplayTitle': 'Chinese'},
            {'Index': 4, 'Type': 'Subtitle', 'DisplayTitle': 'Japanese'},
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
          EngineTrack(id: '3'),
          EngineTrack(id: '4'),
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
              {'Index': 3, 'Type': 'Subtitle'},
              {'Index': 4, 'Type': 'Subtitle'},
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
        secondEngine.subtitleTracksController.add(const [EngineTrack(id: '5')]);
      };
      final secondController = _controller(
        api: api,
        engine: secondEngine,
        item: _nextItem,
        resolver: _PlanResolver(
          _testPlan(
            subtitleStreamIndex: 5,
            mediaStreams: const [
              {'Index': 5, 'Type': 'Subtitle'},
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
    engine.subtitleTracksController.add(const [EngineTrack(id: '3')]);
    await Future.wait([startup, shutdown]);
    engine.subtitleTracksController.add(const [EngineTrack(id: '3')]);

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
        diagnostics: _diagnostics(diagnostics),
      );

      await controller.shutdown().timeout(const Duration(milliseconds: 200));

      expect(engine.stopCalls, 1);
      expect(engine.disposeCalls, 1);
      expect(reporter.stopCalls, 1);
      expect(controller.state.phase, PlaybackPhase.idle);
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

  test('automatic open budget exhaustion is fixed and path-free', () async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    final diagnostics = <String>[];
    final session = PlaybackItemSession.forTest('sensitive-session-id');
    for (final reason in AutomaticPlaybackOpenReason.values) {
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
    final shutdown = controller.shutdown();
    final result = await seek;
    await shutdown;

    expect(result.disposition, SeekDisposition.cancelled);
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
    seekGate.complete();
    await Future<void>.delayed(Duration.zero);
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

  test('inline media kit session forwards lifecycle APIs distinctly', () async {
    final controller = _LifecycleSpyPlaybackController();
    final session = MediaKitInlinePlaybackSession.forTesting(
      itemId: _plainItem.id,
      controller: controller,
    );

    await session.pauseForLifecycle();
    await session.resumeForLifecycle();
    await session.pause();

    expect(controller.calls, [
      'pauseForLifecycle',
      'resumeForLifecycle',
      'pause',
    ]);
    await session.shutdown();
    expect(controller.shutdownCalls, 1);
  });
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
  required EmbyApi api,
  required _FakeEngine engine,
  required EmbyItem item,
  Duration readyTimeout = const Duration(seconds: 1),
  Duration trackWaitTimeout = const Duration(seconds: 2),
  PlaybackDiagnostics? diagnostics,
  PlaybackItemSession? session,
  PlaybackStreamResolver? resolver,
  PlaybackReporter? reporter,
}) => PlaybackController(
  item: item,
  engine: engine,
  resolver: resolver ?? EmbyStreamResolver(api),
  reporter: reporter ?? PlaybackSessionReporter(api: api, item: item),
  playbackHeaders: api.playbackHeaders,
  readyTimeout: readyTimeout,
  trackWaitTimeout: trackWaitTimeout,
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
  _PlanResolver(this.plan);

  final PlaybackPlan plan;
  final List<int?> subtitleStreamRequests = [];
  final List<bool> subtitleDisabledRequests = [];

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
    return plan.copyWith(
      method: forceTranscode ? PlayMethod.transcode : plan.method,
      audioStreamIndex: audioStreamIndex ?? plan.audioStreamIndex,
      clearSubtitleStreamIndex: subtitleDisabled,
      subtitleStreamIndex: subtitleDisabled
          ? null
          : subtitleStreamIndex ?? plan.subtitleStreamIndex,
      subtitleDisabled: subtitleDisabled,
    );
  }

  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
}

PlaybackPlan _testPlan({
  PlayMethod method = PlayMethod.directPlay,
  int? subtitleStreamIndex,
  List<Map<String, dynamic>> mediaStreams = const [],
}) => PlaybackPlan(
  uri: Uri.parse('https://media.example.test/video'),
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
                    'DefaultAudioStreamIndex': ?defaultAudioStreamIndex,
                    'DefaultSubtitleStreamIndex': ?defaultSubtitleStreamIndex,
                    'MediaStreams': [
                      if (defaultAudioStreamIndex != null)
                        {
                          'Index': defaultAudioStreamIndex,
                          'Type': 'Audio',
                          'DisplayTitle': 'Original',
                          'Language': 'eng',
                          'Codec': 'aac',
                        },
                      if (defaultSubtitleStreamIndex != null)
                        {
                          'Index': defaultSubtitleStreamIndex,
                          'Type': 'Subtitle',
                          'DisplayTitle': 'Chinese',
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

class _FakeEngine implements PlaybackEngine {
  _FakeEngine({
    this.openOperation,
    this.stopOperation,
    this.disposeOperation,
    this.seekOperation,
  });

  final Future<void>? openOperation;
  final Future<void>? stopOperation;
  final Future<void>? disposeOperation;
  final Future<void>? seekOperation;
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
  final List<double> rateValues = [];
  final List<Duration> audioDelayValues = [];
  final List<Duration> subtitleDelayValues = [];
  final List<(double, int, int, int)> subtitleStyleValues = [];
  bool emitPlayingOnPlay = true;
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
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
    if (emitPlayingOnPlay) playingController.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekValues.add(position);
    await seekOperation;
    positionController.add(position);
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    selectedAudioTrackIds.add(trackId);
  }

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {
    selectedSubtitleTrackIds.add(trackId);
    selectedSubtitleOpenCounts.add(openPlayValues.length);
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {
    externalSubtitleUris.add(uri);
    if (externalSubtitleError != null) throw externalSubtitleError!;
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
