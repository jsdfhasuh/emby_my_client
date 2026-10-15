// Explicit Android test target; never used by the production main.dart.
import 'dart:convert';
import 'dart:io';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _origin = 'http://127.0.0.1:38765';
final _client = HttpClient();
final _nativeLogs = <String>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  final player = Player(
    configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info),
  );
  player.stream.log.listen(
    (entry) => _nativeLogs.add('${entry.prefix}: ${entry.text}'),
  );
  final engine = MediaKitPlaybackEngine(player);
  final video = VideoController(player);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Builder(
          builder: (context) {
            _videoContext = context;
            return Center(
              child: SizedBox(
                width: 320,
                height: 180,
                child: Video(
                  controller: video,
                  controls: NoVideoControls,
                  fit: BoxFit.fill,
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  try {
    await _run(engine);
    await _report({'stage': 'complete', 'physicalPhone': 'NOT_RUN'});
  } catch (error, stack) {
    await _report({'stage': 'failed', 'error': '$error', 'stack': '$stack'});
  } finally {
    await engine.dispose();
    _client.close(force: true);
  }
}

Future<void> _run(MediaKitPlaybackEngine engine) async {
  final native = engine.player.platform as NativePlayer;
  await native.setProperty('ao', 'null');
  await native.setProperty('cache-on-disk', 'no');
  final directory = await Directory.systemTemp.createTemp(
    'generated-subtitle-',
  );
  try {
    final local = File('${directory.path}/synthetic-pgs.mkv');
    final response = await (await _client.getUrl(
      Uri.parse('$_origin/synthetic-pgs.mkv'),
    )).close();
    await response.pipe(local.openWrite());
    final external = File('${directory.path}/external.srt');
    await external.writeAsString(
      '1\n00:00:00,000 --> 00:00:12,000\nEXTERNAL_CUE\n',
    );
    for (final http in [false, true]) {
      for (var reopen = 0; reopen < 2; reopen++) {
        await engine.open(
          http ? Uri.parse('$_origin/synthetic-pgs.mkv') : local.uri,
          headers: const {},
          play: false,
        );
        await _until(
          () =>
              engine.player.state.tracks.subtitle
                  .where((t) => t.codec != null)
                  .length ==
              3,
        );
        final tracks = engine.player.state.tracks.subtitle;
        final a = tracks.firstWhere((t) => t.title == 'PGS ALPHA');
        final b = tracks.firstWhere((t) => t.title == 'PGS BETA');
        final text = tracks.firstWhere((t) => t.title == 'TEXT');
        final prefix = '${http ? "http" : "file"}-$reopen';
        Future<void> capture(
          String stage,
          String? id,
          String expected,
          int second,
        ) async {
          await engine.selectSubtitleTrack(id);
          await engine.seek(Duration(seconds: second));
          await engine.play();
          await _until(
            () =>
                engine.player.state.position.inMilliseconds >=
                second * 1000 + 150,
          );
          await engine.pause();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final size = MediaQuery.sizeOf(_videoContext!);
          await _report({
            'stage': '$prefix-$stage',
            'expected': expected,
            'screenWidth': size.width,
            'screenHeight': size.height,
            'sid': await native.getProperty('sid'),
            'visibility': await native.getProperty('sub-visibility'),
            'text': engine.player.state.subtitle.first,
            'nativeLogs': List<String>.of(_nativeLogs),
            'currentVo': await native.getProperty('current-vo'),
            'videoParams': await native.getProperty('video-out-params'),
            'position': await native.getProperty('time-pos'),
            'osd': await native.getProperty('osd-dimensions'),
          });
        }

        await capture('a', a.id, 'alpha', 2);
        await capture('b', b.id, 'beta', 4);
        await capture('a2', a.id, 'alpha', 6);
        await capture('off', null, 'off', 7);
        await capture('a3', a.id, 'alpha', 3);
        await capture('ass', text.id, 'text', 3);
        await engine.selectSubtitleTrack(b.id);
        await engine.loadExternalSubtitle(external.uri);
        await engine.seek(const Duration(seconds: 3));
        await engine.play();
        await _until(
          () => engine.player.state.subtitle.first.trim() == 'EXTERNAL_CUE',
        );
        await engine.pause();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _report({
          'stage': '$prefix-srt',
          'expected': 'text',
          'screenWidth': MediaQuery.sizeOf(_videoContext!).width,
          'screenHeight': MediaQuery.sizeOf(_videoContext!).height,
          'sid': await native.getProperty('sid'),
          'visibility': await native.getProperty('sub-visibility'),
          'text': engine.player.state.subtitle.first,
          'nativeLogs': List<String>.of(_nativeLogs),
          'currentVo': await native.getProperty('current-vo'),
          'videoParams': await native.getProperty('video-out-params'),
          'position': await native.getProperty('time-pos'),
          'osd': await native.getProperty('osd-dimensions'),
        });
        await capture('a4', a.id, 'alpha', 2);
        await engine.stop();
      }
    }
  } finally {
    await directory.delete(recursive: true);
  }
}

BuildContext? _videoContext;
Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Native state deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _report(Map<String, Object?> value) async {
  final request = await _client.postUrl(Uri.parse('$_origin/stage'));
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(value));
  final response = await request.close();
  await response.drain<void>();
  if (response.statusCode != 200) throw StateError('Android screenshot failed');
}
