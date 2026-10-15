import 'dart:convert';
import 'dart:io';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'support/progressive_fixture.dart';
import 'support/subtitle_media_fixture.dart';

void main() {
  for (final http in [false, true]) {
    test('PGS and text rendering survive ${http ? 'HTTP' : 'file'} '
        'A B A, disable, seek and stop/reopen', () async {
      MediaKit.ensureInitialized();
      final file = File('test/fixtures/subtitles/synthetic-pgs.mkv').absolute;
      final bytes = await file.readAsBytes();
      final origin = await ProgressiveOrigin.start(content: bytes);
      origin.intercept = (request) async => subtitleVideoReply(request, bytes);
      addTearDown(origin.close);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final engine = MediaKitPlaybackEngine(player);
      addTearDown(engine.dispose);
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      // This video/subtitle fixture must not exercise the null audio device
      // state machine during rapid paused seeks on older libmpv builds.
      await native.setProperty('aid', 'no');
      // No VideoController is attached in this host test; enable its video clock.
      await native.setProperty('vid', 'auto');
      // mpv 0.37's native MKV demuxer classifies every MJPEG track as a
      // still image. Use FFmpeg for this generated video clock fixture.
      await native.setProperty('demuxer', 'lavf');
      await native.setProperty('cache-on-disk', 'no');
      final failures = <String>[];
      final logs = player.stream.log.listen((entry) {
        if (entry.level == 'fatal' || entry.level == 'error') {
          failures.add('${entry.prefix}: ${entry.text}');
        }
      });
      addTearDown(logs.cancel);
      Future<void> until(String stage, bool Function() predicate) => _until(
        predicate,
        stage: stage,
        player: player,
        native: native,
        failures: failures,
      );
      final uri = http
          ? Uri.parse('${origin.origin}/synthetic-pgs.mkv')
          : file.uri;
      for (var cycle = 0; cycle < 2; cycle++) {
        final oldEpoch = engine.subtitleInputEpoch;
        await engine.open(uri, headers: const {}, play: false);
        expect(engine.subtitleInputEpoch, greaterThan(oldEpoch));
        expect(await native.getProperty('sub-visibility'), 'no');
        expect(await native.getProperty('aid'), 'no');
        await until(
          'cycle=$cycle tracks',
          () =>
              player.state.tracks.subtitle
                  .where((track) => track.codec != null)
                  .length ==
              3,
        );
        expect(await native.getProperty('demuxer'), 'lavf');
        final nativeTracks =
            jsonDecode(await native.getProperty('track-list')) as List<dynamic>;
        final video = nativeTracks.cast<Map<String, dynamic>>().singleWhere(
          (track) => track['type'] == 'video',
        );
        expect(
          video['image'],
          isFalse,
          reason: 'The fixture needs a video clock',
        );
        final a = player.state.tracks.subtitle.firstWhere(
          (track) => track.title == 'PGS ALPHA',
        );
        final b = player.state.tracks.subtitle.firstWhere(
          (track) => track.title == 'PGS BETA',
        );
        final text = player.state.tracks.subtitle.firstWhere(
          (track) => track.title == 'TEXT',
        );
        expect(a.codec, 'hdmv_pgs_subtitle');
        for (final track in [a, b, a]) {
          await engine.selectSubtitleTrack(track.id);
          expect(await native.getProperty('sid'), track.id);
          expect(await native.getProperty('sub-visibility'), 'yes');
          await engine.seek(const Duration(seconds: 2));
          await engine.play();
          await until(
            'cycle=$cycle PGS=${track.title} clock',
            () => player.state.position.inMilliseconds >= 2100,
          );
          await engine.pause();
          // PGS has no text representation. Native pixel verification is
          // separately required by the actual-APK Android rendering gate.
          expect(player.state.subtitle.every((line) => line.isEmpty), isTrue);
        }
        await engine.selectSubtitleTrack(null);
        await engine.seek(const Duration(seconds: 4));
        expect(await native.getProperty('sid'), 'no');
        expect(await native.getProperty('sub-visibility'), 'no');
        expect(await native.getProperty('aid'), 'no');

        await engine.selectSubtitleTrack(text.id);
        await engine.seek(const Duration(seconds: 3));
        await engine.play();
        await until(
          'cycle=$cycle embedded text',
          () => player.state.subtitle.first.trim() == 'TEXT_CUE',
        );
        await engine.pause();
        expect(await native.getProperty('sub-visibility'), 'no');
        expect(await native.getProperty('aid'), 'no');

        await engine.selectSubtitleTrack(b.id);
        expect(await native.getProperty('sub-visibility'), 'yes');
        await engine.loadExternalSubtitle(
          File('test/fixtures/subtitles/external.srt').absolute.uri,
        );
        await engine.seek(const Duration(seconds: 3));
        await engine.play();
        await until(
          'cycle=$cycle external text',
          () => player.state.subtitle.first.trim() == 'EXTERNAL_CUE',
        );
        await engine.pause();
        expect(await native.getProperty('sub-visibility'), 'no');
        expect(await native.getProperty('aid'), 'no');

        await engine.selectSubtitleTrack(a.id);
        expect(await native.getProperty('sub-visibility'), 'yes');
        await engine.stop();
      }
      expect(failures, isEmpty);
      expect(native.configuration.libass, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}

Future<void> _until(
  bool Function() predicate, {
  required String stage,
  required Player player,
  required NativePlayer native,
  required List<String> failures,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      final properties = <String, String>{};
      for (final name in [
        'time-pos',
        'pause',
        'vid',
        'aid',
        'sid',
        'current-vo',
        'sub-text',
        'eof-reached',
        'demuxer',
        'track-list',
      ]) {
        try {
          properties[name] = await native.getProperty(name);
        } catch (error) {
          properties[name] = '$error';
        }
      }
      fail(
        'Native subtitle timeout: $stage; properties=$properties; '
        'position=${player.state.position}; '
        'subtitle=${player.state.subtitle}; '
        'tracks=${player.state.tracks.subtitle}; errors=$failures',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
