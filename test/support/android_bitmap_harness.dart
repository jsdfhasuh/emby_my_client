// Explicit Android test target; never used by the production main.dart.
import 'dart:convert';
import 'dart:io';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'harness_seek_barrier.dart';

const _origin = 'http://127.0.0.1:38765';
final _client = HttpClient();
final _nativeLogs = <String>[];
var _nativeErrorCount = 0;
var _verifiedStages = 0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  final player = Player(
    // media_kit's osc:false writes a missing Lua OSC property on Android.
    // osc:true skips that unsupported write; OSD is explicitly disabled below.
    configuration: const PlayerConfiguration(
      osc: true,
      logLevel: MPVLogLevel.info,
    ),
  );
  final logs = player.stream.log.listen((entry) {
    _nativeLogs.add('${entry.prefix}: ${entry.text}');
    if (entry.level == 'fatal' || entry.level == 'error') {
      _nativeErrorCount++;
    }
  });
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
  final directory = await Directory.systemTemp.createTemp(
    'generated-subtitle-',
  );
  Object? failure;
  StackTrace? failureStack;
  final cleanup = {
    'engineDisposed': false,
    'logsCancelled': false,
    'temporaryFilesRemoved': false,
  };
  try {
    await _run(engine, video, directory);
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  } finally {
    // An attached subtitle must outlive its native player. Completion is sent
    // only after every owned resource has actually finished its cleanup.
    try {
      await engine.dispose();
      cleanup['engineDisposed'] = true;
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    try {
      await logs.cancel();
      cleanup['logsCancelled'] = true;
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    try {
      await directory.delete(recursive: true);
      cleanup['temporaryFilesRemoved'] = !await directory.exists();
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
  }
  try {
    await _report({
      'schema': 'emby-android-texture/v2',
      'platform': 'android',
      'scope': 'engine-texture',
      'audioScope': 'SILENT_FIXTURE_AUDIO_QUALITY_NOT_TESTED',
      'fixtureSeekPolicy': 'INDEXLESS_GENERATED_MKV_PREROLL_1S',
      'stage': failure == null ? 'complete' : 'failed',
      'physicalPhone': 'NOT_RUN',
      'verifiedStages': _verifiedStages,
      'nativeErrorCount': _nativeErrorCount,
      'nativeLogs': List<String>.of(_nativeLogs),
      'cleanup': cleanup,
      if (failure != null) 'error': '$failure',
      if (failureStack != null) 'stack': '$failureStack',
    });
  } finally {
    _client.close(force: true);
  }
}

Future<void> _run(
  MediaKitPlaybackEngine engine,
  VideoController video,
  Directory directory,
) async {
  final native = engine.player.platform as NativePlayer;
  await native.setProperty('osd-level', '0');
  // Use Android's normal audio driver with the fixture's generated PCM silence.
  // ao=null reports illegal start/pause transitions; disabling aid also drops
  // this indexless fixture's first PGS cue (native and Flutter screenshots).
  // Neither workaround represents production playback. Audio quality is not
  // scored, but all native errors remain fatal in this subtitle pixel gate.
  await native.setProperty('ao', 'opensles');
  await native.setProperty('aid', 'auto');
  await native.setProperty('cache-on-disk', 'no');
  // Match the existing native pixel probe's generated, indexless MKV policy.
  // PGS packets precede each 2 fps video boundary; decode from one second before
  // the exact seek target so a refresh seek cannot skip that subtitle packet.
  await native.setProperty('framedrop', 'no');
  await native.setProperty('hr-seek-framedrop', 'no');
  await native.setProperty('hr-seek-demuxer-offset', '1');
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
      // Android creates its Surface asynchronously after reading videoParams.
      // A media clock can advance while vo=null and is not a rendered-frame gate.
      await _waitForSurface(video, native);
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
        await _seekAndPaint(
          engine,
          native,
          second,
          expected == 'text' ? 'TEXT_CUE' : null,
        );
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
          'nativeErrorCount': _nativeErrorCount,
          'currentVo': await native.getProperty('current-vo'),
          'audioTrack': await native.getProperty('aid'),
          'audioOutput': await native.getProperty('ao'),
          ..._surfaceEvidence(video),
          'fixtureSeek': await _fixtureSeekEvidence(native),
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
      await _seekAndPaint(engine, native, 3, 'EXTERNAL_CUE');
      await _report({
        'stage': '$prefix-srt',
        'expected': 'text',
        'screenWidth': MediaQuery.sizeOf(_videoContext!).width,
        'screenHeight': MediaQuery.sizeOf(_videoContext!).height,
        'sid': await native.getProperty('sid'),
        'visibility': await native.getProperty('sub-visibility'),
        'text': engine.player.state.subtitle.first,
        'nativeLogs': List<String>.of(_nativeLogs),
        'nativeErrorCount': _nativeErrorCount,
        'currentVo': await native.getProperty('current-vo'),
        'audioTrack': await native.getProperty('aid'),
        'audioOutput': await native.getProperty('ao'),
        ..._surfaceEvidence(video),
        'fixtureSeek': await _fixtureSeekEvidence(native),
        'videoParams': await native.getProperty('video-out-params'),
        'position': await native.getProperty('time-pos'),
        'osd': await native.getProperty('osd-dimensions'),
      });
      await capture('a4', a.id, 'alpha', 2);
      await engine.stop();
    }
  }
}

Future<Map<String, Object?>> _fixtureSeekEvidence(NativePlayer native) async =>
    {
      'framedrop': await native.getProperty('framedrop'),
      'hrSeekFramedrop': await native.getProperty('hr-seek-framedrop'),
      'hrSeekDemuxerOffsetSeconds': double.tryParse(
        await native.getProperty('hr-seek-demuxer-offset'),
      ),
    };

Future<void> _seekAndPaint(
  MediaKitPlaybackEngine engine,
  NativePlayer native,
  int seconds,
  String? cue,
) async {
  await advanceHarnessAfterSeek(
    target: Duration(seconds: seconds),
    pause: engine.pause,
    seek: engine.seek,
    play: engine.play,
    readNative: () async => HarnessSeekSample(
      seeking: await native.getProperty('seeking') != 'no',
      paused: await native.getProperty('pause') == 'yes',
      positionSeconds:
          double.tryParse(await native.getProperty('time-pos')) ?? double.nan,
    ),
  );
  if (cue != null) {
    await _until(() => engine.player.state.subtitle.first.trim() == cue);
  }
  await Future<void>.delayed(const Duration(milliseconds: 350));
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
}

Future<void> _waitForSurface(VideoController video, NativePlayer native) async {
  await video.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 10));
  await _until(
    () =>
        video.id.value != null &&
        video.rect.value?.size == const Size(320, 180),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (await native.getProperty('current-vo') != 'gpu' ||
      await native.getProperty('seeking') != 'no') {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Android video Surface did not become ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  // Let the Video widget consume the texture ID/rect before selecting and seeking.
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
}

Map<String, Object?> _surfaceEvidence(VideoController video) => {
  'textureId': video.id.value,
  'textureWidth': video.rect.value?.width,
  'textureHeight': video.rect.value?.height,
};

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
  if (value.containsKey('expected')) _verifiedStages++;
}
