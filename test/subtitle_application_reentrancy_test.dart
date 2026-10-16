import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_problem.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';

void main() {
  for (final native in [true, false]) {
    for (final log in [true, false]) {
      test('${native ? 'native' : 'embedded'} applied notification decoder '
          '${log ? 'log' : 'error'} cannot publish a late success', () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.controller.start();
        fixture.lines.clear();
        fixture.reporter.updates.clear();
        var injected = false;
        fixture.controller.addListener(() {
          if (injected ||
              fixture.controller.state.subtitleSelectionStatus !=
                  SubtitleSelectionStatus.appliedEmbedded) {
            return;
          }
          injected = true;
          (log ? fixture.engine.logs : fixture.engine.errors).add(
            'No decoder found for hdmv_pgs_subtitle',
          );
        });

        await fixture.select(native: native);

        expect(injected, isTrue);
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.failed,
        );
        expect(
          fixture.controller.state.subtitleProblem?.kind,
          SubtitleProblemKind.unsupported,
        );
        expect(
          fixture.lines.where(
            (line) => line.contains('event=playback_subtitle_apply_failed '),
          ),
          hasLength(1),
        );
        expect(
          fixture.lines.where(
            (line) => line.contains('event=playback_subtitle_applied '),
          ),
          isEmpty,
        );
        expect(fixture.reporter.updates, isEmpty);
        expect(fixture.reporter.progress, 0);
      });
    }
  }

  for (final scenario in [
    'native',
    'embedded',
    'disabled',
    'none',
    'encoded',
  ]) {
    test('$scenario applied notification superseded by a new selection '
        'cannot publish the old success', () async {
      final startup = scenario == 'none' || scenario == 'encoded';
      final fixture = _Fixture(
        resolver: _Resolver(
          defaultIndex: scenario == 'none'
              ? null
              : scenario == 'encoded'
              ? 2
              : -1,
          encoded: scenario == 'encoded',
        ),
      );
      addTearDown(fixture.close);
      if (!startup) {
        await fixture.controller.start();
        if (scenario == 'disabled') await fixture.select(native: true);
      }
      fixture.lines.clear();
      fixture.reporter.updates.clear();
      fixture.reporter.progress = 0;
      final interruptedStatus = switch (scenario) {
        'none' => SubtitleSelectionStatus.appliedNone,
        'disabled' => SubtitleSelectionStatus.disabled,
        'encoded' => SubtitleSelectionStatus.appliedServer,
        _ => SubtitleSelectionStatus.appliedEmbedded,
      };
      Future<void>? replacement;
      var superseded = false;
      fixture.controller.addListener(() {
        if (superseded ||
            fixture.controller.state.subtitleSelectionStatus !=
                interruptedStatus) {
          return;
        }
        superseded = true;
        if (startup) {
          fixture.lines.clear();
          fixture.reporter.updates.clear();
        }
        replacement = scenario == 'encoded'
            ? fixture.controller.selectSubtitleStream(null)
            : fixture.controller.selectNativeSubtitle(
                fixture.controller.nativeSubtitleChoices.last,
              );
      });

      if (startup) {
        await fixture.controller.start();
      } else if (scenario == 'disabled') {
        await fixture.controller.selectSubtitleStream(null);
      } else {
        await fixture.select(native: scenario == 'native');
      }
      expect(superseded, isTrue);
      expect(replacement, isNotNull);
      await replacement;

      expect(fixture.controller.state.phase, PlaybackPhase.ready);
      expect(fixture.controller.state.subtitleProblem, isNull);
      final applied = fixture.lines.where(
        (line) => line.contains('event=playback_subtitle_applied '),
      );
      final disabled = fixture.lines.where(
        (line) => line.contains('event=playback_subtitle_disabled '),
      );
      if (scenario == 'encoded') {
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.disabled,
        );
        expect(applied, isEmpty);
        expect(disabled, hasLength(1));
      } else {
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.appliedEmbedded,
        );
        expect(fixture.controller.state.appliedNativeSubtitleId, '2');
        expect(applied, hasLength(1));
        expect(applied.single, contains('subtitleKind=native'));
        expect(applied.single, contains('nativeId=2'));
        expect(disabled, isEmpty);
        if (!startup) {
          expect(fixture.reporter.updates, hasLength(2));
          expect(
            fixture.reporter.updates.every(
              (plan) =>
                  plan.subtitleStreamIndex == null && !plan.subtitleDisabled,
            ),
            isTrue,
          );
          expect(fixture.reporter.progress, 1);
        }
      }
    });
  }
  for (final failDecoder in [true, false]) {
    test(
      'reporting plan notification ${failDecoder ? 'decoder failure' : 'new selection'} '
      'cannot report the superseded result',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.controller.start();
        fixture.lines.clear();
        fixture.reporter.updates.clear();
        var interrupted = false;
        Future<void>? replacement;
        fixture.controller.addListener(() {
          if (interrupted ||
              fixture.controller.state.subtitleSelectionStatus !=
                  SubtitleSelectionStatus.appliedEmbedded ||
              fixture.controller.state.plan?.subtitleStreamIndex != 2) {
            return;
          }
          interrupted = true;
          if (failDecoder) {
            fixture.engine.errors.add('No decoder found for hdmv_pgs_subtitle');
          } else {
            replacement = fixture.controller.selectNativeSubtitle(
              fixture.controller.nativeSubtitleChoices.last,
            );
          }
        });

        await fixture.select(native: false);
        await replacement;

        expect(interrupted, isTrue);
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        expect(
          fixture.reporter.updates.where(
            (plan) => plan.subtitleStreamIndex == 2,
          ),
          isEmpty,
        );
        if (failDecoder) {
          expect(
            fixture.controller.state.subtitleSelectionStatus,
            SubtitleSelectionStatus.failed,
          );
          expect(
            fixture.controller.state.subtitleProblem?.kind,
            SubtitleProblemKind.unsupported,
          );
          expect(fixture.reporter.updates, isEmpty);
          expect(fixture.reporter.progress, 0);
        } else {
          expect(fixture.controller.state.appliedNativeSubtitleId, '2');
          expect(
            fixture.controller.state.subtitleSelectionStatus,
            SubtitleSelectionStatus.appliedEmbedded,
          );
          expect(fixture.reporter.updates, hasLength(2));
          expect(fixture.reporter.progress, 1);
        }
      },
    );
  }
}

class _Fixture {
  _Fixture({_Resolver? resolver}) {
    controller = PlaybackController(
      item: const EmbyItem(
        id: 'fixture',
        name: 'Synthetic',
        type: 'Movie',
        imageTags: {},
        backdropImageTags: [],
        genres: [],
        userData: EmbyUserData(),
      ),
      engine: engine,
      resolver: resolver ?? _Resolver(),
      reporter: reporter,
      playbackHeaders: const {},
      diagnostics: PlaybackDiagnostics(writer: (_, _, line) => lines.add(line)),
      progressInterval: const Duration(hours: 1),
    );
  }
  final engine = _Engine();
  final reporter = _Reporter();
  final lines = <String>[];
  late final PlaybackController controller;
  Future<void> select({required bool native}) => native
      ? controller.selectNativeSubtitle(controller.nativeSubtitleChoices.first)
      : controller.selectSubtitleStream(2);
  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
  }
}

class _Engine extends RoutePlaybackEngine {
  final errors = StreamController<String>.broadcast(sync: true);
  final logs = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Stream<String> get logStream => logs.stream;
  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    durations.add(const Duration(minutes: 2));
    subtitles.add(const [
      EngineTrack(
        id: '1',
        title: 'Synthetic PGS',
        language: 'eng',
        codec: 'hdmv_pgs_subtitle',
      ),
      EngineTrack(
        id: '2',
        title: 'Synthetic text',
        language: 'eng',
        codec: 'subrip',
      ),
    ]);
    if (play) await this.play();
  }

  @override
  Future<void> dispose() async {
    await errors.close();
    await logs.close();
    await super.dispose();
  }
}

class _Resolver implements PlaybackStreamResolver {
  _Resolver({this.defaultIndex = -1, this.encoded = false});
  final int? defaultIndex;
  final bool encoded;
  @override
  bool get canForceTranscode => false;
  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
  @override
  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async => PlaybackPlan(
    uri: Uri.parse('https://fixture.invalid/video'),
    mediaSourceId: 'source',
    playSessionId: null,
    method: encoded ? PlayMethod.transcode : PlayMethod.directPlay,
    usesServerAuthentication: false,
    subtitleStreamIndex: subtitleDisabled
        ? null
        : subtitleStreamIndex ?? defaultIndex,
    subtitleDisabled: subtitleDisabled,
    mediaStreams: [
      {
        'Index': 2,
        'Type': 'Subtitle',
        'Title': 'Synthetic PGS',
        'Language': 'eng',
        'Codec': 'hdmv_pgs_subtitle',
        'DeliveryMethod': encoded ? 'Encode' : 'Embed',
      },
    ],
    transcodingReasons: const [],
    availableMediaSources: const [],
  );
}

class _Reporter implements PlaybackReporter {
  final updates = <PlaybackPlan>[];
  int progress = 0;
  @override
  void activate(PlaybackPlan plan) {}
  @override
  void updatePlan(PlaybackPlan plan) => updates.add(plan);
  @override
  Future<void> reportStart(Duration position, {required bool isPaused}) async {}
  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {
    progress++;
  }

  @override
  Future<void> stop(Duration position) async {}
  @override
  Future<void> cleanup(PlaybackPlan plan) async {}
}
