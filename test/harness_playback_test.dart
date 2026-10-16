import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/harness_playback.dart';

void main() {
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
