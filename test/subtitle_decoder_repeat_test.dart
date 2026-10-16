import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';

const _decoderError = 'No decoder found for hdmv_pgs_subtitle';

void main() {
  for (final firstIsLog in [true, false]) {
    test(
      'attributed decoder ${firstIsLog ? "log" : "error"} followed by duplicate errors stays recoverable',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.start();
        (firstIsLog ? fixture.engine.logs : fixture.engine.errors).add(
          _decoderError,
        );
        expect(
          fixture.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.failed,
        );
        fixture.engine.errors.add(_decoderError);
        fixture.engine.logs.add(_decoderError);
        fixture.engine.errors.add(_decoderError);
        expect(fixture.controller.state.phase, PlaybackPhase.ready);
        expect(fixture.failures, 1);
      },
    );
  }
  test(
    'failed subtitle fingerprint does not suppress unrelated video failure',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();
      fixture.engine.errors.add(_decoderError);
      fixture.engine.errors.add('No decoder found for h264');
      expect(fixture.controller.state.phase, PlaybackPhase.failed);
    },
  );
  test(
    'retry is a new request and its same-codec failure is independently handled',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();
      fixture.engine.errors.add(_decoderError);
      final firstRevision =
          fixture.controller.state.desiredSubtitleSelection.requestRevision;
      await fixture.controller.selectNativeSubtitle(
        fixture.controller.nativeSubtitleChoices.single,
      );
      expect(
        fixture.controller.state.desiredSubtitleSelection.requestRevision,
        greaterThan(firstRevision),
      );
      expect(
        fixture.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedEmbedded,
      );
      fixture.engine.errors.add(_decoderError);
      expect(
        fixture.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
      expect(fixture.failures, 2);
      expect(fixture.controller.state.phase, PlaybackPhase.ready);
    },
  );
  test(
    'old attributed failure cannot suppress an error from a new native input epoch',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();
      fixture.engine.errors.add(_decoderError);
      fixture.engine.epoch++;
      fixture.engine.errors.add(_decoderError);
      expect(fixture.controller.state.phase, PlaybackPhase.failed);
    },
  );
}

class _Fixture {
  _Fixture() {
    controller = PlaybackController(
      item: EmbyItem.fromJson({
        'Id': 'generated',
        'Name': 'Synthetic',
        'Type': 'Movie',
      }),
      engine: engine,
      resolver: _Resolver(),
      reporter: _Reporter(),
      playbackHeaders: const {},
      diagnostics: PlaybackDiagnostics(writer: (_, _, line) => lines.add(line)),
      progressInterval: const Duration(hours: 1),
    );
  }
  final engine = _Engine();
  final lines = <String>[];
  late final PlaybackController controller;
  int get failures => lines
      .where((line) => line.contains('event=playback_subtitle_apply_failed '))
      .length;
  Future<void> start() async {
    await controller.start();
    await controller.selectNativeSubtitle(
      controller.nativeSubtitleChoices.single,
    );
    expect(controller.state.phase, PlaybackPhase.ready);
    expect(
      controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.appliedEmbedded,
    );
    lines.clear();
  }

  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
  }
}

class _Engine extends RoutePlaybackEngine
    implements SubtitleInputEpochProvider {
  final errors = StreamController<String>.broadcast(sync: true);
  final logs = StreamController<String>.broadcast(sync: true);
  int epoch = 0;
  @override
  int get subtitleInputEpoch => epoch;
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
    epoch++;
    durations.add(const Duration(minutes: 2));
    subtitles.add(const [
      EngineTrack(
        id: '1',
        title: 'Generated PGS',
        language: 'eng',
        codec: 'hdmv_pgs_subtitle',
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
    uri: Uri.parse('https://fixture.invalid/generated'),
    mediaSourceId: 'generated-source',
    playSessionId: null,
    method: PlayMethod.directPlay,
    usesServerAuthentication: false,
    subtitleStreamIndex: -1,
    mediaStreams: const [],
    transcodingReasons: const [],
    availableMediaSources: const [],
  );
}

class _Reporter implements PlaybackReporter {
  @override
  void activate(PlaybackPlan plan) {}
  @override
  void updatePlan(PlaybackPlan plan) {}
  @override
  Future<void> reportStart(Duration position, {required bool isPaused}) async {}
  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {}
  @override
  Future<void> stop(Duration position) async {}
  @override
  Future<void> cleanup(PlaybackPlan plan) async {}
}
