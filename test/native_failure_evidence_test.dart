import 'dart:async';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'support/route_playback_engine.dart';
import 'package:emby_my_client/core/token_redactor.dart';
import 'package:emby_my_client/playback/native_failure_evidence.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/harness_lifecycle_trace.dart';

void main() {
  test('unsettled probe kind survives the closed artifact schema', () {
    final line = NativeFailureEvidence().record(
      message: const PlaybackCacheProbeUnsettled().toString(),
      fromLog: false,
      generation: 1,
      inputEpoch: 0,
      phase: PlaybackPhase.resolving,
      step: NativeStartupStep.cacheSetup,
      lifecycleSuspended: false,
    )!;
    expect(
      safeHarnessLifecycleEvent(line),
      containsPair('kind', 'cache_probe_unsettled'),
    );
  });

  test(
    'preparation log limit leaves a bounded media startup log allowance',
    () {
      final evidence = NativeFailureEvidence();
      String? record(NativeStartupStep step) => evidence.record(
        message: const PlayerLog(
          prefix: 'file',
          level: 'error',
          text: 'No such file',
        ).toString(),
        fromLog: true,
        generation: 1,
        inputEpoch: 0,
        phase: PlaybackPhase.resolving,
        step: step,
        lifecycleSuspended: false,
      );
      for (final step in [
        NativeStartupStep.cacheSetup,
        NativeStartupStep.engineOpen,
        NativeStartupStep.ready,
        NativeStartupStep.cleanup,
      ]) {
        for (var i = 0; i < 8; i++) {
          expect(record(step), isNotNull);
        }
        expect(record(step), isNull);
      }
    },
  );
  test(
    'setup errors cannot consume media startup or runtime primary evidence',
    () {
      final evidence = NativeFailureEvidence();
      String? record(
        NativeStartupStep step,
        PlaybackPhase phase,
        String message,
      ) => evidence.record(
        message: message,
        fromLog: false,
        generation: 1,
        inputEpoch: 1,
        phase: phase,
        step: step,
        lifecycleSuspended: false,
      );
      expect(
        record(
          NativeStartupStep.cacheSetup,
          PlaybackPhase.resolving,
          'No such file',
        ),
        contains('kind=file_missing'),
      );
      expect(
        record(
          NativeStartupStep.engineOpen,
          PlaybackPhase.opening,
          'Permission denied',
        ),
        contains('kind=permission_denied'),
      );
      expect(
        record(
          NativeStartupStep.waitingReady,
          PlaybackPhase.waitingForReady,
          'secondary',
        ),
        isNull,
      );
      expect(
        record(
          NativeStartupStep.ready,
          PlaybackPhase.ready,
          'Input/output error',
        ),
        contains('kind=io_error'),
      );
      expect(
        record(
          NativeStartupStep.cleanup,
          PlaybackPhase.stopping,
          '[Player] has been disposed',
        ),
        contains('step=cleanup'),
      );
      expect(
        record(
          NativeStartupStep.cleanup,
          PlaybackPhase.stopping,
          'late cleanup',
        ),
        isNull,
      );
    },
  );
  test(
    'controller captures primary native failure before terminal disposal',
    () async {
      final lines = <String>[];
      DiagnosticLog.instance.setTestSink(lines.add);
      addTearDown(() => DiagnosticLog.instance.setTestSink(null));
      final engine = _FailedNativeEngine();
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
      await controller.start(playAfterReady: false);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(engine.disposals, 1);
      final evidence = lines
          .where((line) => line.contains('event=playback_native_failure'))
          .map(safeHarnessLifecycleEvent)
          .toList();
      expect(evidence, hasLength(2));
      expect(evidence[0], containsPair('prefix', 'file'));
      expect(evidence[1], containsPair('channel', 'error'));
      expect(evidence[1], containsPair('kind', 'permission_denied'));
      expect(evidence[1], containsPair('step', 'engineOpen'));
      expect(evidence[1], containsPair('phase', 'opening'));
      expect(evidence.toString(), isNot(contains('PRIVATE')));
      expect(evidence.toString(), isNot(contains('disposed')));
    },
  );

  test(
    'first error survives cleanup and native logs are bounded per generation',
    () {
      final evidence = NativeFailureEvidence();
      String? record(String message, {bool log = false, int generation = 1}) =>
          evidence.record(
            message: message,
            fromLog: log,
            generation: generation,
            inputEpoch: 1,
            phase: PlaybackPhase.opening,
            step: NativeStartupStep.engineOpen,
            lifecycleSuspended: true,
          );
      final first = record('Permission denied: /private/film.mkv')!;
      expect(first, contains('kind=permission_denied'));
      expect(record('[Player] has been disposed'), isNull);
      for (var i = 0; i < 8; i++) {
        expect(
          record(
            'PlayerLog(prefix: file, level: error, text: No such file /secret)',
            log: true,
          ),
          isNotNull,
        );
      }
      expect(
        record('PlayerLog(prefix: file, level: error, text: late)', log: true),
        isNull,
      );
      expect(record('new input', generation: 2), contains('generation=2'));
    },
  );

  test('closed diagnostic schema never exports arbitrary native text', () {
    TokenRedactor.register('REGISTERED_SECRET');
    for (final raw in [
      'Failed to open https://user:password@private.invalid/Film Name.mkv?api_key=QUERY_SECRET',
      r'No such file C:\Private Films\name.mkv',
      'Permission denied /private/My Film.mkv token=FIELD_SECRET Bearer BEARER_SECRET',
      'REGISTERED_SECRET \ncustom=PRIVATE_TITLE',
      'PlayerLog(prefix: /private/secret, level: error, text: secret)',
    ]) {
      final evidence = NativeFailureEvidence();
      final line = evidence.record(
        message: raw,
        fromLog: false,
        generation: 4,
        inputEpoch: 3,
        phase: PlaybackPhase.waitingForReady,
        step: NativeStartupStep.waitingReady,
        lifecycleSuspended: false,
      )!;
      expect(line, isNot(contains('private')));
      expect(line, isNot(contains('SECRET')));
      expect(line, isNot(contains('Film')));
      expect(line, isNot(contains('password')));
      expect(line, isNot(contains('http')));
      expect(safeHarnessLifecycleEvent(line), containsPair('generation', 4));
    }
  });

  test('native log privacy and numeric bounds survive artifact parsing', () {
    final line = NativeFailureEvidence().record(
      message: const PlayerLog(
        prefix: 'https://PRIVATE.invalid/path',
        level: 'error',
        text:
            r'Permission denied C:\PRIVATE\film.mkv /PRIVATE/film api_key=SECRET',
      ).toString(),
      fromLog: true,
      generation: -10,
      inputEpoch: 10000000,
      phase: PlaybackPhase.stopping,
      step: NativeStartupStep.cleanup,
      lifecycleSuspended: true,
    )!;
    final parsed = safeHarnessLifecycleEvent(line)!;
    expect(parsed['generation'], 0);
    expect(parsed['inputEpoch'], 999999);
    expect(parsed['prefix'], 'other');
    expect(line, isNot(contains('PRIVATE')));
    expect(line, isNot(contains('SECRET')));
    expect(
      safeHarnessLifecycleEvent(
        line.replaceFirst('generation=0', 'generation=1000000'),
      ),
      isNull,
    );
    expect(
      safeHarnessLifecycleEvent(
        line.replaceFirst('inputEpoch=999999', 'inputEpoch=-1'),
      ),
      isNull,
    );
  });

  test('prefix and failure category survive while log text does not', () {
    final line = NativeFailureEvidence().record(
      message: const PlayerLog(
        prefix: 'vd',
        level: 'error',
        text: 'Failed to initialize decoder for /private/film',
      ).toString(),
      fromLog: true,
      generation: 1,
      inputEpoch: 2,
      phase: PlaybackPhase.opening,
      step: NativeStartupStep.engineOpen,
      lifecycleSuspended: false,
    )!;
    expect(line, contains('prefix=vd level=error kind=decoder_failed'));
    final parsed = safeHarnessLifecycleEvent(line)!;
    expect(parsed['step'], 'engineOpen');
    expect(parsed['inputEpoch'], 2);
    expect(
      safeHarnessLifecycleEvent(
        line.replaceFirst('prefix=vd', 'prefix=PRIVATE'),
      ),
      isNull,
    );
    expect(
      safeHarnessLifecycleEvent(
        line.replaceFirst('generation=1', 'generation=secret'),
      ),
      isNull,
    );
    expect(
      safeHarnessLifecycleEvent(
        line.replaceFirst('kind=decoder_failed', 'kind=PRIVATE'),
      ),
      isNull,
    );
  });
}

class _FailedNativeEngine extends RoutePlaybackEngine {
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
    const message = 'Permission denied /PRIVATE/film.mkv token=PRIVATE_TOKEN';
    logs.add(
      const PlayerLog(prefix: 'file', level: 'error', text: message).toString(),
    );
    errors.add(message);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await errors.close();
    await logs.close();
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
    uri: Uri.file('/synthetic/fixture.mkv'),
    mediaSourceId: 'fixture',
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
