import 'dart:async';
import 'dart:io';
import 'package:emby_my_client/core/diagnostic_log.dart';

import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_problem.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_settings_scope.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/ui/player_playback_backend.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:emby_my_client/ui/player_system_ui.dart';
import 'package:emby_my_client/ui/widgets/playback_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';
import 'support/synthetic_playback_origin.dart';

final _diagnostics = <String>[];

void main() {
  testWidgets(
    'production online player closes and recreates a fresh route twice',
    (tester) async {
      final fixture = await _mount(tester);
      VoidCallback? retiredSelection;
      for (var cycle = 0; cycle < 2; cycle++) {
        final engine = await fixture.open(tester);
        if (retiredSelection != null) {
          retiredSelection();
          await _flush(tester);
          expect(engine.subtitleSelections, [null]);
        }
        await _subtitles(tester);
        expect(
          _diagnostics
              .where((line) => line.contains('event=playback_options'))
              .map((line) => RegExp(r'phase=([a-z_]+)').firstMatch(line)![1])
              .toList()
              .reversed
              .take(3)
              .toList()
              .reversed,
          ['entry', 'push_requested', 'mapping'],
        );
        expect(
          _diagnostics.lastWhere((line) => line.contains('phase=entry')),
          contains('open=false released=false controller=true plan=true'),
        );
        final initialState = tester
            .widget<PlaybackSubtitleOptions>(
              find.byType(PlaybackSubtitleOptions),
            )
            .playbackState;
        expect(initialState.phase, PlaybackPhase.ready);
        expect(
          initialState.subtitleSelectionStatus,
          SubtitleSelectionStatus.disabled,
        );
        expect(initialState.subtitleProblem, isNull);
        final row = find.byKey(const ValueKey('native-subtitle-1'));
        retiredSelection = tester.widget<ListTile>(row).onTap;
        await tester.tap(row);
        await _flush(tester);
        expect(engine.subtitleSelections, [null, '1']);
        expect(
          _diagnostics.lastWhere(
            (line) => line.contains('event=playback_options'),
          ),
          contains('phase=closed reason=none mounted=true open=false'),
        );
        expect(find.byType(PlayerScreen), findsOneWidget);
        expect(engine.disposals, 0);
        await _close(tester);
        expect(find.byType(PlayerScreen), findsNothing);
        expect(engine.stops, 1);
        expect(engine.disposals, 1);
        expect(fixture.systemUi.restores, cycle + 1);
        expect(
          find.byKey(const ValueKey('open-generated-player')),
          findsOneWidget,
        );
      }
      expect(fixture.engines, hasLength(2));
      expect(identical(fixture.engines[0], fixture.engines[1]), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playback options single tap survives resolving plan', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final engine = await fixture.open(tester);
    await _subtitles(tester);
    final controller = _optionsController(tester);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await _flush(tester);
    fixture.origin.holdPlaybackInfo = true;
    final reopening = controller.reconfigure(maxStreamingBitrate: 90000000);
    await _until(
      tester,
      () => controller.state.phase == PlaybackPhase.resolving,
    );
    expect(controller.state.plan, isNull);
    await tester.tap(find.byKey(const ValueKey('player-options')));
    await _flush(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playback-options-loading')),
      findsOneWidget,
    );
    expect(find.byType(PlaybackSubtitleOptions), findsNothing);
    fixture.origin.releasePlaybackInfo();
    await _until(tester, () => controller.state.phase == PlaybackPhase.ready);
    await reopening;
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playback-options-loading')),
      findsNothing,
    );
    await tester.tap(find.text('字幕'));
    await _flush(tester);
    await tester.tap(find.byKey(const ValueKey('native-subtitle-2')));
    await _flush(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(engine.subtitleSelections.last, '2');
    await _close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'playback options refresh epoch without accepting stale callback',
    (tester) async {
      final fixture = await _mount(tester);
      final engine = await fixture.open(tester);
      await _subtitles(tester);
      final controller = _optionsController(tester);
      final oldEpoch = controller.subtitleInputEpoch;
      final stale = tester
          .widget<ListTile>(find.byKey(const ValueKey('native-subtitle-1')))
          .onTap!;
      fixture.origin.holdPlaybackInfo = true;
      final reopening = controller.reconfigure(maxStreamingBitrate: 90000000);
      await _until(
        tester,
        () => controller.state.phase == PlaybackPhase.resolving,
      );
      expect(
        find.byKey(const ValueKey('playback-options-loading')),
        findsOneWidget,
      );
      stale();
      await _flush(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      fixture.origin.releasePlaybackInfo();
      await _until(tester, () => controller.state.phase == PlaybackPhase.ready);
      await reopening;
      expect(controller.subtitleInputEpoch, greaterThan(oldEpoch));
      final selections = engine.subtitleSelections.toList();
      stale();
      await _flush(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(engine.subtitleSelections, selections);
      await tester.tap(find.byKey(const ValueKey('native-subtitle-2')));
      await _flush(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(engine.subtitleSelections.last, '2');
      await _close(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playback options shows unavailable after resolution fails', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await fixture.open(tester);
    await _subtitles(tester);
    final controller = _optionsController(tester);
    fixture.origin.holdPlaybackInfo = true;
    fixture.origin.playbackInfoStatus = 503;
    final reopening = controller.reconfigure(maxStreamingBitrate: 90000000);
    await _until(
      tester,
      () => controller.state.phase == PlaybackPhase.resolving,
    );
    fixture.origin.releasePlaybackInfo();
    await _until(tester, () => controller.state.phase == PlaybackPhase.failed);
    await reopening;
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playback-options-loading')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('playback-options-unavailable')),
      findsOneWidget,
    );
    expect(find.byType(PlaybackSubtitleOptions), findsNothing);
    await _close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale subtitle sheet cannot select against a new input epoch', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final engine = await fixture.open(tester);
    await _subtitles(tester);
    final oldOptions = tester.widget<PlaybackSubtitleOptions>(
      find.byType(PlaybackSubtitleOptions),
    );
    engine.inputEpoch++;
    await HttpOverrides.runZoned(() async {
      oldOptions.onSelect(5);
      await _flush(tester);
    }, createHttpClient: SyntheticPlaybackOrigin.fixtureClient);
    expect(
      fixture.origin.requests.where((p) => p.contains('/Subtitles/')),
      isEmpty,
    );
    expect(engine.externalUris, isEmpty);
    expect(engine.subtitleSelections, [null]);
    expect(find.byType(BottomSheet), findsOneWidget);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await _flush(tester);
    await _subtitles(tester);
    await _external(tester);
    await _until(tester, () => engine.externalUris.length == 1);
    expect(
      fixture.origin.requests.where((p) => p.contains('/Subtitles/')),
      hasLength(1),
    );
    await _close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'production route lifecycle interrupts playback and explicit UI resumes',
    (tester) async {
      final fixture = await _mount(tester);
      final engine = await fixture.open(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      expect(engine.lifecyclePauses, greaterThanOrEqualTo(1));
      expect(engine.isPlaying, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(engine.lifecycleResumes, 1);
      expect(engine.isPlaying, isFalse);
      await tester.tap(find.byKey(const ValueKey('player-play-pause')));
      await _flush(tester);
      expect(engine.isPlaying, isTrue);
      final slider = find.descendant(
        of: find.byType(PlaybackTimeline),
        matching: find.byType(Slider),
      );
      await tester.drag(slider, const Offset(100, 0));
      await _flush(tester);
      expect(engine.seeks, isNotEmpty);
      await _close(tester);
      expect(engine.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delayed external response after exit cannot attach to reopened route',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.origin.holdSubtitle = true;
      final old = await fixture.open(tester);
      await _subtitles(tester);
      await _external(tester);
      await _until(
        tester,
        () => fixture.origin.requests.any((p) => p.contains('/Subtitles/')),
      );
      await _close(tester);
      expect(old.disposals, 1);
      expect(old.externalUris, isEmpty);
      fixture.origin.holdSubtitle = false;
      final current = await fixture.open(tester);
      expect(current.externalUris, isEmpty);
      final oldRequests = fixture.origin.requests
          .where((p) => p.contains('/Subtitles/'))
          .length;
      fixture.origin.releaseSubtitle();
      await _flush(tester);
      expect(old.externalUris, isEmpty);
      expect(current.externalUris, isEmpty);
      expect(current.subtitleSelections, [null]);
      expect(
        fixture.origin.requests.where((p) => p.contains('/Subtitles/')),
        hasLength(oldRequests),
      );
      await _subtitles(tester);
      await _external(tester);
      await _until(tester, () => current.externalUris.isNotEmpty);
      expect(
        fixture.origin.requests.where((p) => p.contains('/Subtitles/')).length,
        greaterThan(oldRequests),
      );
      final file = File.fromUri(current.externalUris.single);
      expect(await tester.runAsync(file.exists), isTrue);
      expect(old.externalUris, isEmpty);
      expect(current.disposals, 0);
      await _close(tester);
      expect(current.disposals, 1);
      expect(await tester.runAsync(file.exists), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'attributed native subtitle decoder failure leaves video and UI usable',
    (tester) async {
      final fixture = await _mount(tester);
      final engine = await fixture.open(tester);
      await _subtitles(tester);
      await tester.tap(find.byKey(const ValueKey('native-subtitle-1')));
      await _flush(tester);
      engine.errors.add('No decoder found for hdmv_pgs_subtitle');
      await _flush(tester);
      await _subtitles(tester);
      final state = tester
          .widget<PlaybackSubtitleOptions>(find.byType(PlaybackSubtitleOptions))
          .playbackState;
      expect(state.phase, PlaybackPhase.ready);
      expect(state.subtitleProblem?.kind, SubtitleProblemKind.unsupported);
      expect(state.subtitleSelectionStatus, SubtitleSelectionStatus.failed);
      expect(engine.isPlaying, isTrue);
      expect(engine.disposals, 0);
      expect(
        find.byKey(const ValueKey('subtitle-export-diagnostics')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('native-subtitle-2')));
      await _flush(tester);
      expect(engine.subtitleSelections.last, '2');
      expect(engine.isPlaying, isTrue);
      await _close(tester);
      expect(engine.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HTTP subtitle failure leaves production route usable for retry',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.origin.subtitleStatus = 503;
      final engine = await fixture.open(tester);
      await _subtitles(tester);
      await _external(tester);
      await _flush(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(engine.isPlaying, isTrue);
      expect(engine.externalUris, isEmpty);
      expect(engine.disposals, 0);
      expect(
        fixture.origin.requests.any((p) => p.contains('/Subtitles/')),
        isTrue,
      );
      expect(_diagnostics.any((line) => line.contains('http=503')), isTrue);
      fixture.origin.subtitleStatus = 200;
      await _subtitles(tester);
      await _external(tester);
      await _until(tester, () => engine.externalUris.length == 1);
      await _close(tester);
      expect(engine.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

PlaybackController _optionsController(WidgetTester tester) => tester
    .widgetList<ListenableBuilder>(find.byType(ListenableBuilder))
    .map((widget) => widget.listenable)
    .whereType<PlaybackController>()
    .first;

Future<void> _subtitles(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-options')));
  await _flush(tester);
  await tester.tap(find.text('字幕'));
  await _flush(tester);
}

Future<void> _external(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('server-subtitle-5-3'));
  final subtitleScrollable = find.descendant(
    of: find.byType(PlaybackSubtitleOptions),
    matching: find.byType(Scrollable),
  );
  expect(subtitleScrollable, findsOneWidget);
  await tester.scrollUntilVisible(row, 200, scrollable: subtitleScrollable);
  await Scrollable.ensureVisible(tester.element(row), alignment: .5);
  await tester.pump();
  expect(row.hitTestable(), findsOneWidget);
  expect(tester.widget<ListTile>(row).onTap, isNotNull);
  // SourceHttpInput creates its own client. Keep real generated-origin I/O
  // confined to this interaction; the widget binding otherwise returns HTTP 400.
  await HttpOverrides.runZoned(() async {
    await tester.tap(row);
    await _flush(tester);
  }, createHttpClient: SyntheticPlaybackOrigin.fixtureClient);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _until(WidgetTester tester, bool Function() check) async {
  for (var i = 0; i < 50; i++) {
    if (check()) return;
    await _flush(tester);
  }
  fail(
    'Synthetic route did not reach expected state; diagnostics=${_diagnostics.reversed.take(15).toList()}',
  );
}

Future<void> _close(WidgetTester tester) async {
  if (find.byType(BottomSheet).evaluate().isNotEmpty) {
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await _flush(tester);
  }
  await tester.tap(find.byKey(const ValueKey('player-back')));
  await _until(tester, () => find.byType(PlayerScreen).evaluate().isEmpty);
}

Future<_Fixture> _mount(WidgetTester tester) async {
  _diagnostics.clear();
  DiagnosticLog.instance.setTestSink(_diagnostics.add);
  await tester.binding.setSurfaceSize(const Size(1000, 700));
  late final _Fixture fixture;
  await tester.runAsync(() async {
    final origin = await SyntheticPlaybackOrigin.start(
      await File('test/fixtures/subtitles/synthetic-pgs.mkv').readAsBytes(),
    );
    fixture = _Fixture(
      origin,
      origin.createApi(),
      await Directory.systemTemp.createTemp('player-route-regression-'),
    );
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.runAsync(() async {
      await fixture.api.dispose();
      await fixture.origin.close();
      await fixture.directory.delete(recursive: true);
    });
    // The repository futures belong to the widget fake zone; await them here,
    // not inside runAsync where that zone cannot deliver their microtasks.
    final settingsDisposed = fixture.settings.dispose();
    await tester.pump();
    await settingsDisposed;
    DiagnosticLog.instance.setTestSink(null);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    PlayerPlaybackBackendScope(
      create: () {
        final engine = _Engine();
        fixture.engines.add(engine);
        return PlayerPlaybackBackend(
          engine: engine,
          buildVideo: (_) => const ColoredBox(color: Colors.black),
        );
      },
      child: PlaybackSettingsRepositoryScope(
        repository: fixture.settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey('open-generated-player'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PlayerScreen(
                        api: fixture.api,
                        item: fixture.origin.item,
                        capabilities: PlatformCapabilities.unsupported,
                        systemControls: _Controls(),
                        systemUiController: fixture.systemUi,
                        cacheStorage: PlatformPlaybackCacheStorage(
                          rootResolver: () async => fixture.directory,
                          freeBytesResolver: (_) async => 1000000000,
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open generated player'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _flush(tester);
  return fixture;
}

class _Fixture {
  _Fixture(this.origin, this.api, this.directory);
  final SyntheticPlaybackOrigin origin;
  final EmbyApi api;
  final Directory directory;
  final engines = <_Engine>[];
  final systemUi = _SystemUi();
  final settings = PlaybackSettingsRepository(storage: _Storage());

  Future<_Engine> open(WidgetTester tester) async {
    final previousRoutes = engines.length;
    await tester.tap(find.byKey(const ValueKey('open-generated-player')));
    await _until(
      tester,
      () =>
          engines.length == previousRoutes + 1 &&
          engines.last.isPlaying &&
          engines.last.subtitleSelections.isNotEmpty,
    );
    await _flush(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(engines.last.subtitleSelections, [null]);
    return engines.last;
  }
}

class _Engine extends RoutePlaybackEngine
    implements PlaybackNativeResourceOwner, SubtitleInputEpochProvider {
  int inputEpoch = 0;
  @override
  int get subtitleInputEpoch => inputEpoch;
  final _nativeReleases = <Future<void> Function()>[];
  final errors = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  void retainUntilNativeDisposal(Future<void> Function() release) {
    _nativeReleases.add(release);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await errors.close();
    for (final release in _nativeReleases) {
      await release();
    }
    _nativeReleases.clear();
  }

  @override
  Future<void> stop() async {
    inputEpoch++;
    await super.stop();
  }

  final externalUris = <Uri>[];
  final seeks = <Duration>[];
  int lifecyclePauses = 0;
  int lifecycleResumes = 0;
  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    inputEpoch++;
    openedUri = uri;
    durations.add(const Duration(seconds: 12));
    subtitles.add(const [
      EngineTrack(
        id: '1',
        title: 'PGS ALPHA',
        language: 'eng',
        codec: 'hdmv_pgs_subtitle',
      ),
      EngineTrack(
        id: '2',
        title: 'PGS BETA',
        language: 'eng',
        codec: 'hdmv_pgs_subtitle',
      ),
      EngineTrack(id: '3', title: 'TEXT', language: 'eng', codec: 'ass'),
    ]);
    if (play) await this.play();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    await super.seek(position);
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {
    externalUris.add(uri);
  }

  @override
  Future<void> quiesceForLifecycle() async {
    lifecyclePauses++;
    await pause();
  }

  @override
  Future<void> resumeFromLifecycleQuiescence() async {
    lifecycleResumes++;
  }
}

class _Storage implements PlaybackSettingsStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _SystemUi implements PlayerSystemUiController {
  int restores = 0;
  @override
  Future<void> enterPlayback() async {}
  @override
  Future<void> restoreAfterPlayback() async {
    restores++;
  }
}

class _Controls implements PlayerSystemControls {
  @override
  Future<double> readBrightness() async => .5;
  @override
  Future<double> readVolume() async => .5;
  @override
  Future<void> setBrightness(double value) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> resetBrightness() async {}
}
