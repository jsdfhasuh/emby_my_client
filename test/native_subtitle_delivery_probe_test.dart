import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_subtitle_delivery_probe.dart';
import 'support/route_playback_engine.dart';

void main() {
  test(
    'terminal failed startup is reported without reading disposed native input',
    () async {
      final engine = _FailingOpenEngine();
      final controller = PlaybackController(
        item: EmbyItem.fromJson({
          'Id': 'fixture',
          'Name': 'fixture',
          'Type': 'Movie',
        }),
        engine: engine,
        resolver: _Resolver(),
        reporter: _Reporter(),
        playbackHeaders: const {},
      );
      addTearDown(controller.shutdown);
      final probe = NativeSubtitleDeliveryProbe(
        mode: 'controlled-start-failure',
        state: () => controller.state,
        disposed: () => engine.disposals != 0,
      );
      DiagnosticLog.instance.setTestSink(probe.diagnostic);
      addTearDown(() => DiagnosticLog.instance.setTestSink(null));
      await controller.start(playAfterReady: false);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(
        controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.applying,
      );
      expect(controller.state.errorMessage, isNotEmpty);
      expect(engine.disposals, 1);
      // This is the old describe() failure, independent of any Linux timing.
      String readDisposedNative() {
        throw StateError('[Player] has been disposed');
      }

      expect(readDisposedNative, throwsStateError);
      var nativeReads = 0;
      await expectLater(
        probe.until(() async {
          nativeReads++;
          readDisposedNative();
          return false;
        }),
        throwsA(
          isA<TestFailure>().having(
            (error) => error.message,
            'first startup state',
            allOf(
              contains('"phase":"failed"'),
              contains('playback_start_failed'),
              contains('StateError'),
              isNot(contains('[Player] has been disposed')),
            ),
          ),
        ),
      );
      expect(nativeReads, 0);
    },
  );

  for (final phase in [PlaybackPhase.opening, PlaybackPhase.waitingForReady]) {
    test('$phase cannot pass the startup readiness guard', () {
      final probe = NativeSubtitleDeliveryProbe(
        mode: 'controlled',
        state: () => PlaybackState(phase: phase),
        disposed: () => false,
      );
      expect(probe.requireReady, throwsA(isA<TestFailure>()));
    });
  }
  test(
    'native predicate exception retains original identity and stack',
    () async {
      final probe = NativeSubtitleDeliveryProbe(
        mode: 'controlled',
        state: () => const PlaybackState(phase: PlaybackPhase.ready),
        disposed: () => false,
      );
      final original = StateError('CONTROLLED_NATIVE_ERROR');
      final stack = StackTrace.fromString('CONTROLLED_NATIVE_STACK');
      try {
        await probe.until(() => Future<bool>.error(original, stack));
        fail('Expected original native error');
      } catch (error, caughtStack) {
        expect(error, same(original));
        expect(caughtStack.toString(), contains('CONTROLLED_NATIVE_STACK'));
      }
    },
  );

  test('ready input still executes the real cue predicate', () async {
    final probe = NativeSubtitleDeliveryProbe(
      mode: 'controlled',
      state: () => const PlaybackState(phase: PlaybackPhase.ready),
      disposed: () => false,
    );
    var checks = 0;
    await probe.until(() async => ++checks == 1);
    expect(checks, 1);
  });
  test(
    'safe diagnostics remove URI paths and credentials and retain first event',
    () {
      final message = NativeSubtitleDeliveryProbe.safeMessage(
        'Failed http://fixture/private?api_key=secret C:\\private\\media.mkv /private/file.mkv token=secret',
      );
      expect(message, isNot(contains('secret')));
      expect(message, isNot(contains('private')));
      final probe = NativeSubtitleDeliveryProbe(
        mode: 'controlled',
        state: () => const PlaybackState(),
        disposed: () => true,
      );
      for (var i = 0; i < 140; i++) {
        probe.record('event-$i');
      }
      expect(probe.events.length, 128);
      expect(probe.events.first['event'], 'event-0');
      expect(probe.droppedEvents, 12);
    },
  );
}

class _FailingOpenEngine extends RoutePlaybackEngine {
  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    throw StateError('CONTROLLED_START_FAILURE');
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
    uri: Uri.parse('https://fixture.invalid/generated.mkv'),
    mediaSourceId: 'fixture',
    playSessionId: 'fixture',
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
