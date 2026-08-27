import 'dart:async';

import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_output_quiescer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('optional mpv property failures do not escape', () async {
    final calls = <String>[];
    final writer = SafeNativePropertyWriter((property, value) async {
      calls.add('$property=$value');
      if (property == 'audio-delay' || property == 'sub-color') {
        throw StateError('unsupported optional property');
      }
    });

    await writer.write('audio-delay', '0.250');
    await writer.write('sub-delay', '-0.125');
    await writer.write('sub-font-size', '34.0');
    await writer.write('sub-color', '#FFFFFFFF');
    await writer.write('sub-border-color', '#FF000000');
    await writer.write('sub-pos', '100');

    expect(calls, [
      'audio-delay=0.250',
      'sub-delay=-0.125',
      'sub-font-size=34.0',
      'sub-color=#FFFFFFFF',
      'sub-border-color=#FF000000',
      'sub-pos=100',
    ]);
  });

  group('MediaKitPlaybackEngine urgent output quiescence', () {
    test(
      'blocked native seek is urgently paused before seek completes',
      () async {
        final platform = _FakePlatformPlayer();
        final seekGate = Completer<void>();
        platform.seekGate = seekGate;
        final output = _FakePlaybackOutputQuiescer();
        final engine = _createEngine(platform, output);
        addTearDown(() async {
          if (!seekGate.isCompleted) seekGate.complete();
          await engine.dispose();
        });

        final seek = engine.seek(const Duration(seconds: 17));
        await platform.seekStarted.future;
        final quiescence = engine.quiesce();

        await output.waitForCalls(1);
        await quiescence;
        expect(seekGate.isCompleted, isFalse);
        expect(platform.pauseCalls, 0);
        expect(output.pauseCalls, 1);

        seekGate.complete();
        await seek;
        expect(output.pauseCalls, 2);
        expect(platform.playCalls, 0);
      },
    );

    test(
      'blocked native play is urgently paused and cannot resume late',
      () async {
        final platform = _FakePlatformPlayer();
        final playGate = Completer<void>();
        platform.playGate = playGate;
        final output = _FakePlaybackOutputQuiescer();
        final engine = _createEngine(platform, output);
        addTearDown(() async {
          if (!playGate.isCompleted) playGate.complete();
          await engine.dispose();
        });

        final play = engine.play();
        await platform.playStarted.future;
        final quiescence = engine.quiesce();

        await output.waitForCalls(1);
        await quiescence;
        expect(playGate.isCompleted, isFalse);
        expect(platform.pauseCalls, 0);
        expect(platform.playCalls, 1);

        playGate.complete();
        await play;
        expect(output.pauseCalls, 2);
        expect(platform.playCalls, 1);
      },
    );

    test(
      'blocked native open is urgently paused and filters late playing',
      () async {
        final platform = _FakePlatformPlayer(
          emitPlayingWhenOpenCompletes: true,
        );
        final openGate = Completer<void>();
        platform.openGate = openGate;
        final output = _FakePlaybackOutputQuiescer();
        final engine = _createEngine(platform, output);
        final playingEvents = <bool>[];
        final subscription = engine.playingStream.listen(playingEvents.add);
        addTearDown(() async {
          if (!openGate.isCompleted) openGate.complete();
          await subscription.cancel();
          await engine.dispose();
        });

        final open = engine.open(
          Uri.parse('https://example.invalid/video.mp4'),
          headers: const {'Authorization': 'token'},
          play: true,
        );
        await platform.openStarted.future;
        final quiescence = engine.quiesce();

        await output.waitForCalls(1);
        await quiescence;
        expect(openGate.isCompleted, isFalse);
        expect(platform.pauseCalls, 0);

        openGate.complete();
        await open;
        await Future<void>.delayed(Duration.zero);
        expect(output.pauseCalls, 2);
        expect(playingEvents, isNot(contains(true)));
      },
    );

    test(
      'urgent pause is single-flight and releases completed reference',
      () async {
        final platform = _FakePlatformPlayer();
        final output = _FakePlaybackOutputQuiescer();
        final firstPauseGate = Completer<void>();
        output.gates[1] = firstPauseGate;
        final engine = _createEngine(platform, output);
        addTearDown(() async {
          if (!firstPauseGate.isCompleted) firstPauseGate.complete();
          await engine.dispose();
        });

        final retirement = engine.quiesce();
        final lifecycleOne = engine.quiesceForLifecycle();
        final lifecycleTwo = engine.quiesceForLifecycle();
        await output.waitForCalls(1);

        expect(output.pauseCalls, 1);
        firstPauseGate.complete();
        await Future.wait([retirement, lifecycleOne, lifecycleTwo]);
        expect(output.pauseCalls, 1);

        await engine.quiesceForLifecycle();
        expect(output.pauseCalls, 2);
      },
    );

    test(
      'urgent pause failure is swallowed and shutdown still completes',
      () async {
        final platform = _FakePlatformPlayer();
        final playGate = Completer<void>();
        platform.playGate = playGate;
        final output = _FakePlaybackOutputQuiescer(
          failure: StateError('urgent native pause failed'),
        );
        final engine = _createEngine(platform, output);
        addTearDown(() async {
          if (!playGate.isCompleted) playGate.complete();
          await engine.dispose();
        });

        final play = engine.play();
        await platform.playStarted.future;

        await expectLater(engine.quiesce(), completes);
        expect(platform.pauseCalls, 0);
        expect(output.pauseCalls, 1);

        final dispose = engine.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(platform.disposeCalls, 0);

        playGate.complete();
        await expectLater(play, completes);
        await expectLater(dispose, completes);
        expect(output.pauseCalls, 2);
        expect(platform.playCalls, 1);
        expect(platform.disposeCalls, 1);
      },
    );

    test(
      'dispose waits for native operation and late urgent re-pause',
      () async {
        final platform = _FakePlatformPlayer();
        final seekGate = Completer<void>();
        platform.seekGate = seekGate;
        final output = _FakePlaybackOutputQuiescer();
        final latePauseGate = Completer<void>();
        output.gates[2] = latePauseGate;
        final engine = _createEngine(platform, output);
        addTearDown(() async {
          if (!seekGate.isCompleted) seekGate.complete();
          if (!latePauseGate.isCompleted) latePauseGate.complete();
          await engine.dispose();
        });

        final seek = engine.seek(const Duration(seconds: 31));
        await platform.seekStarted.future;
        await engine.quiesce();

        final dispose = engine.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(platform.disposeCalls, 0);

        seekGate.complete();
        await output.waitForCalls(2);
        await Future<void>.delayed(Duration.zero);
        expect(platform.disposeCalls, 0);

        latePauseGate.complete();
        await seek;
        await dispose;
        expect(platform.disposeCalls, 1);
        expect(platform.events.last, 'dispose');
      },
    );

    test('non-native output quiescer falls back to Player.pause', () async {
      final platform = _FakePlatformPlayer();
      final player = Player(platformPlayer: platform);
      addTearDown(player.dispose);

      await MediaKitPlaybackOutputQuiescer(player).pauseUrgently();

      expect(platform.pauseCalls, 1);
    });
  });
}

MediaKitPlaybackEngine _createEngine(
  _FakePlatformPlayer platform,
  PlaybackOutputQuiescer output,
) => MediaKitPlaybackEngine(
  Player(platformPlayer: platform),
  outputQuiescer: output,
);

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer({this.emitPlayingWhenOpenCompletes = false})
    : super(configuration: const PlayerConfiguration());

  final bool emitPlayingWhenOpenCompletes;
  Completer<void>? openGate;
  Completer<void>? playGate;
  Completer<void>? seekGate;
  final Completer<void> openStarted = Completer<void>();
  final Completer<void> playStarted = Completer<void>();
  final Completer<void> seekStarted = Completer<void>();
  final List<String> events = <String>[];
  int openCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalls++;
    events.add('open:start');
    if (!openStarted.isCompleted) openStarted.complete();
    await openGate?.future;
    events.add('open:end');
    if (play && emitPlayingWhenOpenCompletes) playingController.add(true);
  }

  @override
  Future<void> play() async {
    playCalls++;
    events.add('play:start');
    if (!playStarted.isCompleted) playStarted.complete();
    await playGate?.future;
    events.add('play:end');
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    events.add('pause');
  }

  @override
  Future<void> seek(Duration duration) async {
    seekCalls++;
    events.add('seek:start');
    if (!seekStarted.isCompleted) seekStarted.complete();
    await seekGate?.future;
    events.add('seek:end');
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    events.add('dispose');
    await super.dispose();
  }
}

class _FakePlaybackOutputQuiescer implements PlaybackOutputQuiescer {
  _FakePlaybackOutputQuiescer({this.failure});

  final Object? failure;
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};
  final List<_PauseCallWaiter> _waiters = <_PauseCallWaiter>[];
  int pauseCalls = 0;

  Future<void> waitForCalls(int count) {
    if (pauseCalls >= count) return Future<void>.value();
    final waiter = _PauseCallWaiter(count);
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  @override
  Future<void> pauseUrgently() async {
    pauseCalls++;
    for (final waiter in List<_PauseCallWaiter>.of(_waiters)) {
      if (pauseCalls >= waiter.count) {
        _waiters.remove(waiter);
        waiter.completer.complete();
      }
    }
    await gates[pauseCalls]?.future;
    final error = failure;
    if (error != null) throw error;
  }
}

class _PauseCallWaiter {
  _PauseCallWaiter(this.count);

  final int count;
  final Completer<void> completer = Completer<void>();
}
