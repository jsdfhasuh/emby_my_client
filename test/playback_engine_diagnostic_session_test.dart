import 'dart:async';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/playback_diagnostic_snapshot.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';

void main() {
  test(
    'terminal engine error remains in the current playback export',
    () async {
      final lines = <String>[];
      final trace = StrmTrace(
        log: DiagnosticLog.forTesting()..setTestSink(lines.add),
      );
      final engine = _Engine();
      final controller = PlaybackController(
        item: const EmbyItem(
          id: 'item',
          name: 'Synthetic',
          type: 'Movie',
          imageTags: {},
          backdropImageTags: [],
          genres: [],
          userData: EmbyUserData(),
        ),
        engine: engine,
        resolver: _Resolver(),
        reporter: _Reporter(),
        playbackHeaders: const {},
        diagnostics: PlaybackDiagnostics(
          trace: trace,
          writer: (_, _, message) => lines.add(message),
        ),
      );
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      await controller.start();
      expect(controller.state.phase, PlaybackPhase.ready);
      // A warning with the same fingerprint must not consume the error budget.
      engine.logs.add('Synthetic prior warning');
      engine.errors.add(
        'Synthetic terminal fault password=synthetic-private-value',
      );
      expect(controller.state.phase, PlaybackPhase.failed);
      final snapshot = PlaybackDiagnosticSnapshot.capture(
        lines.join('\n'),
        playbackTraceId: trace.id,
      );
      expect(
        snapshot.content,
        contains('event=playback_engine_error trace=${trace.id}'),
      );
      expect(snapshot.content, contains('fingerprint=other'));
      expect(snapshot.content, contains('outcome=failed'));
      expect(snapshot.content, isNot(contains('synthetic-private-value')));
      expect(snapshot.content, isNot(contains('Synthetic terminal fault')));
      expect(snapshot.summary.playbackStage, 'native_read');
      final other = PlaybackDiagnosticSnapshot.capture(
        lines.join('\n'),
        playbackTraceId: '0000000000000000',
      );
      expect(other.content, isEmpty);
    },
  );
}

class _Engine extends RoutePlaybackEngine {
  final errors = StreamController<String>.broadcast(sync: true);
  final logs = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Stream<String> get logStream => logs.stream;
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
    uri: Uri.parse('https://fixture.example.test/video'),
    mediaSourceId: 'source',
    playSessionId: null,
    method: PlayMethod.directPlay,
    usesServerAuthentication: false,
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
