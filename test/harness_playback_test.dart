import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/harness_playback.dart';

void main() {
  test(
    'startup paused input must become ready before actual play and pause',
    () async {
      final ready = Completer<bool>();
      final playAck = Completer<void>();
      final pauseAck = Completer<void>();
      final events = <String>[];
      var complete = false;
      final operation = pauseHarnessStartup(
        waitForReadyPlaying: () => ready.future,
        tapPlayPause: () async => events.add('tap'),
        waitForPlaying: (playing) async {
          events.add('wait-$playing');
          await (playing ? playAck.future : pauseAck.future);
        },
      ).then((_) => complete = true);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(complete, isFalse);
      ready.complete(false);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['tap', 'wait-true']);
      expect(complete, isFalse);
      playAck.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['tap', 'wait-true', 'tap', 'wait-false']);
      expect(complete, isFalse);
      pauseAck.complete();
      await operation;
      expect(complete, isTrue);
    },
  );

  test('startup already playing input uses one actual pause and ack', () async {
    final events = <String>[];
    await pauseHarnessStartup(
      waitForReadyPlaying: () async => true,
      tapPlayPause: () async => events.add('tap'),
      waitForPlaying: (playing) async => events.add('wait-$playing'),
    );
    expect(events, ['tap', 'wait-false']);
  });

  test('startup rejects opening, stale epoch, divergent state and EOF', () {
    final readyPaused = <String, Object?>{
      'playerFound': true,
      'uiPlaying': false,
      'dartPlaying': false,
      'dartCompleted': false,
      'pause': 'yes',
      'eof-reached': 'no',
      'controllerReadyBefore': true,
      'controllerReadyAfter': true,
      'samePlayer': true,
      'epochBefore': 3,
      'epochAfter': 3,
      'dartDurationMs': 12000,
      'duration': '12.000000',
      'seeking': 'no',
    };
    expect(harnessStartupAcknowledged(readyPaused), isTrue);
    for (final invalid in <String, Object?>{
      'controllerReadyBefore': false,
      'controllerReadyAfter': false,
      'samePlayer': false,
      'epochAfter': 4,
      'uiPlaying': true,
      'dartPlaying': true,
      'pause': 'no',
      'dartCompleted': true,
      'eof-reached': 'yes',
      'dartDurationMs': 0,
      'duration': '0',
      'seeking': 'yes',
      'nativeReadError': 'read-failed',
    }.entries) {
      expect(
        harnessStartupAcknowledged({
          ...readyPaused,
          invalid.key: invalid.value,
        }),
        isFalse,
        reason: invalid.key,
      );
    }
  });

  test(
    'old tooltip can finish cue flow before delayed play is acknowledged',
    () async {
      var renderedPlaying = false;
      var nativePlaying = false;
      var taps = 0;
      final playAck = Completer<void>();
      Future<void> tap() async {
        taps++;
        unawaited(
          playAck.future.then((_) {
            nativePlaying = true;
            renderedPlaying = true;
          }),
        );
      }

      // Negative control from the old driver: the seek already painted a cue,
      // while the play event and the matching tooltip update are still pending.
      await tap();
      final alreadyVisibleCue = true;
      expect(alreadyVisibleCue, isTrue);
      if (renderedPlaying) await tap();
      expect(renderedPlaying, isFalse); // Old _pause accepted this stale value.
      playAck.complete();
      await Future<void>.delayed(Duration.zero);
      expect(nativePlaying, isTrue);
      expect(taps, 1);
    },
  );

  test(
    'cue driver awaits play and pause acknowledgements with a stale cue',
    () async {
      final playAck = Completer<void>();
      final pauseAck = Completer<void>();
      final events = <String>[];
      var toggles = 0;
      var completed = false;
      final operation = playHarnessCueAndPause(
        tapPlayPause: () async {
          toggles++;
          events.add('tap-$toggles');
        },
        waitForPlaying: (playing) async {
          events.add('wait-$playing');
          if (playing) await playAck.future;
          if (!playing && toggles > 0) await pauseAck.future;
        },
        waitForCue: () async => events.add('already-visible-cue'),
      ).then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['wait-false', 'tap-1', 'wait-true']);
      expect(completed, isFalse);
      playAck.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        'wait-false',
        'tap-1',
        'wait-true',
        'already-visible-cue',
        'tap-2',
        'wait-false',
      ]);
      expect(completed, isFalse);
      pauseAck.complete();
      await operation;
      expect(toggles, 2);
      expect(completed, isTrue);
    },
  );
}
