import 'dart:async';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'strm_diagnostics_test.dart' show fileLog, report;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/mpv_source_input.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_session_bootstrap.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'source_http_input_test.dart' show fixtureRequest;
import 'support/progressive_fixture.dart';

void main() {
  test(
    'actual bridge retains truncated HTTP failure before native error',
    () async {
      MediaKit.ensureInitialized();
      final logs = await fileLog();
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      var count = 0;
      origin.intercept = (request) async {
        if (++count == 1) return null;
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(request.headers['range']!)![1]!,
        );
        return (
          status: 206,
          headers: {
            'Content-Range':
                'bytes $start-${start + 99}/${origin.bytes.length}',
            'ETag': '"fixture-v1"',
          },
          body: origin.bytes.sublist(start, start + 10),
        );
      };
      final resource = fixtureRequest(
        '${origin.origin}/private?sig=private-secret',
        trace: StrmTrace(log: logs.log),
      );
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      final failure = Completer<SourceInputFailure>();
      final adapter = await MpvSourceInput.create(
        native,
        onReadFailure: (value) {
          if (!failure.isCompleted) failure.complete(value);
        },
      );
      addTearDown(() async {
        adapter.releaseAll();
        await player.dispose();
        adapter.afterNativeDisposal();
      });
      final prepared = await adapter.prepare(resource);
      await native.setProperty('demuxer', 'lavf');
      await native.setProperty('demuxer-lavf-format', prepared.format);
      await native.setProperty('demuxer-lavf-o', 'protocol_whitelist=none');
      Media(prepared.uri.toString(), httpHeaders: const {});
      await native.command(['loadfile', prepared.uri.toString(), 'replace']);
      final actual = await failure.future.timeout(const Duration(seconds: 15));
      expect(actual.error.reason, 'truncated');
      expect(actual.error.safeHttp, 206);
      expect(actual.error.safeStage, 'body_read');
      expect(actual.request, greaterThan(1));
      expect(actual.openAttempt, 1);
      expect(actual.trace, same(resource.trace));
      expect(actual.error.allowsSeekRecovery, true);
      final exported = await report(logs.log, 'native-truncated');
      expect(exported.content.split('event=strm_failure').length - 1, 1);
    },
  );

  test(
    'Bootstrap STRM resolves strict metadata and actually plays/resumes without Emby video',
    () async {
      MediaKit.ensureInitialized();
      final logFixture = await fileLog();
      final trace = StrmTrace(log: logFixture.log);
      final source = await ProgressiveOrigin.start();
      addTearDown(source.close);
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: options.path.endsWith('/PlaybackInfo')
                      ? {
                          'PlaySessionId': 'cycle',
                          'MediaSources': [
                            {
                              'Id': 'source',
                              'Path':
                                  '${source.origin}/d/video%2fsource?sig=%7e',
                              'Container': 'avi',
                              'Protocol': 'Http',
                              'RunTimeTicks': 240000000,
                              'RequiredHttpHeaders': {
                                'Authorization': 'Bearer source-fixture',
                              },
                            },
                          ],
                        }
                      : {},
                ),
              );
            },
          ),
        );
      final api = EmbyApi(
        const EmbySession(
          serverUrl: 'https://emby.invalid',
          serverName: 'fixture',
          serverId: 'server',
          userId: 'user',
          username: 'fixture',
          accessToken: 'emby-fixture',
          deviceId: 'device',
        ),
        dio: dio,
      );
      addTearDown(api.dispose);
      final item = EmbyItem.fromJson({
        'Id': 'item',
        'MediaSources': [
          {'Id': 'source', 'Container': 'strm', 'Path': '/disk/movie.strm'},
        ],
      });
      // Decode real frames without depending on a display or sound server.
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final nativeErrors = <String>[];
      final nativeLogs = <String>[];
      final errorSubscription = player.stream.error.listen(nativeErrors.add);
      final logSubscription = player.stream.log.listen(
        (event) => nativeLogs.add(event.toString()),
      );
      addTearDown(errorSubscription.cancel);
      addTearDown(logSubscription.cancel);
      await (player.platform as NativePlayer).setProperty('vid', 'auto');
      await (player.platform as NativePlayer).setProperty('ao', 'null');
      final engine = MediaKitPlaybackEngine(player);
      final controller = PlaybackSessionBootstrap.createOnlineController(
        api: api,
        trace: trace,
        entry: 'fullscreen',
        item: item,
        engine: engine,
        session: PlaybackItemSession.forTest('native-source'),
        settings: const PlaybackSettings(),
      );
      addTearDown(controller.shutdown);
      await controller.start(
        resumePosition: const Duration(seconds: 8),
        playAfterReady: false,
        subtitleDisabled: true,
      );
      expect(
        controller.state.phase,
        PlaybackPhase.ready,
        reason:
            '${controller.state.errorMessage}\n${nativeErrors.join('\n')}\n${nativeLogs.join('\n')}',
      );
      expect(controller.state.plan!.isSourceDirect, isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'strm-native-sub-test-',
      );
      final subtitle = File('${directory.path}/fixture.srt');
      await subtitle.writeAsString(
        '1\n00:00:00,000 --> 00:00:24,000\nNative subtitle fixture\n',
      );
      addTearDown(() async {
        await subtitle.delete();
        await directory.delete();
      });
      await engine.loadExternalSubtitle(subtitle.uri);
      expect(
        await (player.platform as NativePlayer).getProperty('sid'),
        isNot('no'),
      );
      await engine.selectSubtitleTrack(null);
      expect(await (player.platform as NativePlayer).getProperty('sid'), 'no');
      await controller.handleMemoryPressure();
      expect(
        controller.state.phase,
        PlaybackPhase.ready,
        reason: controller.state.errorMessage,
      );
      expect(
        await (player.platform as NativePlayer).getProperty('path'),
        'embyinput://2',
      );
      expect(
        requests.where((r) => r.path == '/Sessions/Playing'),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.path == '/Sessions/Playing/Stopped'),
        isEmpty,
      );
      expect(
        (await (player.platform as NativePlayer).getProperty('time-pos')),
        isNotEmpty,
      );
      expect(source.requests, isNotEmpty);
      expect(
        source.requests.every(
          (r) =>
              r.headers['authorization'] == 'Bearer source-fixture' &&
              !r.headers.containsKey('x-emby-token'),
        ),
        isTrue,
      );
      final playback = requests
          .where((r) => r.path.endsWith('/PlaybackInfo'))
          .single;
      expect(playback.data['EnableTranscoding'], false);
      expect(playback.data['EnableDirectStream'], false);
      expect(
        requests.any(
          (r) => r.path.contains('/Videos/') || r.path.contains('/Download'),
        ),
        isFalse,
      );
      await controller.shutdown();
      expect(
        requests.where((r) => r.path == '/Sessions/Playing'),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.path == '/Sessions/Playing/Stopped'),
        hasLength(1),
      );
      final exported = await report(logFixture.log, 'native-bootstrap');
      expect(
        exported.content,
        contains('route=source_direct inputMode=stream_cb'),
      );
      expect(
        exported.content,
        contains('stage=native_read outcome=first_read'),
      );
      expect(exported.content, contains('openAttempt=2'));
      expect(exported.content.split('scope=playback').length - 1, 1);
      expect(
        exported.content.split('operation=start outcome=started').length - 1,
        1,
      );
      expect(
        exported.content.split('operation=stopped outcome=succeeded').length -
            1,
        1,
      );
      expect(
        RegExp(
          r'trace=([0-9a-f]{16})',
        ).allMatches(exported.content).map((m) => m[1]).toSet(),
        {trace.id},
      );
      expect(exported.content, isNot(contains('source-fixture')));
      expect(exported.content, contains('sig=%7e'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'actual libmpv custom input decodes progressive video, seeks and resumes across redirect',
    () async {
      MediaKit.ensureInitialized();
      final a = await ProgressiveOrigin.start();
      final b = await ProgressiveOrigin.start();
      addTearDown(a.close);
      addTearDown(b.close);
      a.intercept = (_) async => (
        status: 302,
        headers: {'Location': '${b.origin}/signed%2fvideo?x=1&x=2'},
        body: <int>[],
      );
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('vid', 'auto');
      await native.setProperty('ao', 'null');
      await native.setProperty('cache-on-disk', 'no');
      final adapter = await MpvSourceInput.create(native);
      addTearDown(() async {
        adapter.releaseAll();
        await player.dispose();
        adapter.afterNativeDisposal();
      });
      final input = await adapter.prepare(
        fixtureRequest(
          '${a.origin}/d/video',
          headers: {'Authorization': 'fixture-only'},
        ),
      );
      await native.setProperty('demuxer', 'lavf');
      await native.setProperty('demuxer-lavf-format', input.format);
      await native.setProperty('demuxer-lavf-o', 'protocol_whitelist=none');
      native.onLoadHooks.add(
        () => native.setProperty('file-local-options/access-references', 'no'),
      );
      final duration = player.stream.duration
          .firstWhere((d) => d.inSeconds >= 23)
          .timeout(const Duration(seconds: 15));
      await player.stop();
      await player.pause();
      Media(input.uri.toString(), httpHeaders: const {});
      await native.command(['loadfile', input.uri.toString(), 'replace']);
      await duration;
      await player.stream.width
          .firstWhere((w) => w == 32)
          .timeout(const Duration(seconds: 15));
      final ready = player.stream.position
          .firstWhere((p) => p.inSeconds >= 15)
          .timeout(const Duration(seconds: 15));
      await player.seek(const Duration(seconds: 16));
      await player.play();
      await ready;
      expect(await native.getProperty('video-params/w'), '32');
      await player.pause();
      expect(
        b.requests.any((r) => r.headers['range'] != 'bytes=0-262143'),
        isTrue,
      );
      expect(
        b.requests.every((r) => !r.headers.containsKey('authorization')),
        isTrue,
      );
      // A new engine-open attempt resumes the same source through a fresh cookie.
      adapter.releaseAll();
      await player.stop();
      final resumed = await adapter.prepare(
        fixtureRequest('${a.origin}/d/video'),
      );
      final newDuration = player.stream.duration
          .firstWhere((d) => d.inSeconds >= 23)
          .timeout(const Duration(seconds: 15));
      await player.pause();
      Media(resumed.uri.toString(), httpHeaders: const {});
      await native.command(['loadfile', resumed.uri.toString(), 'replace']);
      await newDuration;
      await player.stream.width
          .firstWhere((w) => w == 32)
          .timeout(const Duration(seconds: 15));
      await player.seek(const Duration(seconds: 12));
      final resumedPosition = player.stream.position
          .firstWhere((p) => p.inSeconds >= 11)
          .timeout(const Duration(seconds: 15));
      await player.play();
      await resumedPosition;
      expect(await native.getProperty('video-params/w'), '32');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
