import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/progressive_fixture.dart';
import 'support/subtitle_media_fixture.dart';

/// Actual host libmpv allocation/disposal coverage. Android texture/pixel and
/// iOS native rendering remain separate platform gates; this is not either.
void main() {
  for (final http in [false, true]) {
    test('fresh native player after disposal has no stale PGS/text selection: '
        '${http ? 'HTTP' : 'file'}', () async {
      MediaKit.ensureInitialized(); // Missing libmpv is a failure, never skip.
      final media = File('test/fixtures/subtitles/synthetic-pgs.mkv').absolute;
      final bytes = await media.readAsBytes();
      final origin = await ProgressiveOrigin.start(content: bytes);
      origin.intercept = (request) async => subtitleVideoReply(request, bytes);
      addTearDown(origin.close);
      final failures = <String>[];
      final retiredEventCounts = <int>[];
      final subscriptions = <StreamSubscription<dynamic>>[];
      MediaKitPlaybackEngine? previous;
      for (var allocation = 0; allocation < 3; allocation++) {
        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null'),
        );
        final engine = MediaKitPlaybackEngine(player);
        expect(identical(engine, previous), isFalse);
        previous = engine;
        final native = player.platform as NativePlayer;
        var events = 0;
        final playing = player.stream.playing.listen((_) => events++);
        final logging = player.stream.log.listen((entry) {
          if (entry.level == 'fatal' || entry.level == 'error') {
            failures.add('${entry.prefix}: ${entry.text}');
          }
        });
        subscriptions.addAll([playing, logging]);
        try {
          await native.setProperty('ao', 'null');
          await native.setProperty('aid', 'no');
          await native.setProperty('vid', 'auto');
          await native.setProperty('demuxer', 'lavf');
          await native.setProperty('cache-on-disk', 'no');
          await engine.open(
            http ? Uri.parse('${origin.origin}/synthetic-pgs.mkv') : media.uri,
            headers: const {},
            play: false,
          );
          expect(await native.getProperty('sub-visibility'), 'no');
          await _until(
            () =>
                player.state.tracks.subtitle
                    .where((t) => t.codec != null)
                    .length ==
                3,
            'fresh native tracks allocation=$allocation',
          );
          expect(
            player.state.tracks.subtitle.where(
              (t) => t.id.contains('external'),
            ),
            isEmpty,
          );
          final a = player.state.tracks.subtitle.firstWhere(
            (t) => t.title == 'PGS ALPHA',
          );
          final b = player.state.tracks.subtitle.firstWhere(
            (t) => t.title == 'PGS BETA',
          );
          final ass = player.state.tracks.subtitle.firstWhere(
            (t) => t.title == 'TEXT',
          );
          for (final track in [a, b, a]) {
            await engine.selectSubtitleTrack(track.id);
            await engine.seek(const Duration(seconds: 2));
            await engine.play();
            await _until(
              () => player.state.position.inMilliseconds >= 2100,
              'PGS clock allocation=$allocation track=${track.title}',
            );
            await engine.pause();
            expect(await native.getProperty('sid'), track.id);
            expect(await native.getProperty('sub-visibility'), 'yes');
            expect(player.state.subtitle.every((s) => s.isEmpty), isTrue);
          }
          await engine.selectSubtitleTrack(ass.id);
          await _cue(engine, 'TEXT_CUE');
          await engine.loadExternalSubtitle(
            File('test/fixtures/subtitles/external.srt').absolute.uri,
          );
          await _cue(engine, 'EXTERNAL_CUE');
          // Lifecycle interruption uses the real engine, including output
          // quiescence; returning must not restore the previous bitmap.
          await engine.play();
          await engine.quiesceForLifecycle();
          expect(await native.getProperty('pause'), 'yes');
          await engine.resumeFromLifecycleQuiescence();
          // Resume releases the barrier; playback still needs explicit intent.
          expect(await native.getProperty('pause'), 'yes');
          await engine.play();
          await _until(() => player.state.playing, 'lifecycle resumed');
          expect(await native.getProperty('sub-visibility'), 'no');
          await engine.selectSubtitleTrack(null);
          expect(await native.getProperty('sid'), 'no');
          expect(await native.getProperty('sub-visibility'), 'no');
          await engine.stop();
        } finally {
          await engine.dispose();
          // Complete destruction before the next allocation. Keep the old
          // observer alive briefly to detect callbacks after disposal.
          final atDisposal = events;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(events, atDisposal, reason: 'retired player emitted playing');
          retiredEventCounts.add(events);
          await playing.cancel();
          await logging.cancel();
          subscriptions.remove(playing);
          subscriptions.remove(logging);
        }
        expect(failures, isEmpty);
      }
      expect(retiredEventCounts, hasLength(3));
      expect(subscriptions, isEmpty);
      if (http) expect(origin.requests, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 90)));
  }
}

Future<void> _cue(MediaKitPlaybackEngine engine, String expected) async {
  await engine.seek(const Duration(seconds: 3));
  await engine.play();
  await _until(
    () => engine.player.state.subtitle.first.trim() == expected,
    'decoded $expected',
  );
  await engine.pause();
  expect(
    await (engine.player.platform as NativePlayer).getProperty(
      'sub-visibility',
    ),
    'no',
  );
}

Future<void> _until(bool Function() predicate, String stage) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native lifecycle timeout: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
