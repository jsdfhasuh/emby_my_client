import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/external_subtitle_loader.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/progressive_fixture.dart';
import 'support/subtitle_media_fixture.dart';

const _externalCue = '1\n00:00:00,000 --> 00:00:20,000\nEXTERNAL_CUE\n';

void main() {
  for (final mode in [
    'file-native',
    'http-native',
    'transcode-external',
    'transcode-embed',
    'offline-external',
  ]) {
    test(
      'real subtitle delivery $mode confirms sid and actual cue text',
      () async {
        // Missing libmpv is a failure, never silently skipped.
        MediaKit.ensureInitialized();
        final bytes = subtitleMediaFixture();
        final directory = await Directory.systemTemp.createTemp(
          'subtitle-media-',
        );
        final media = File('${directory.path}/generated.mkv');
        final external = File('${directory.path}/external.srt');
        await media.writeAsBytes(bytes);
        await external.writeAsString(_externalCue);
        addTearDown(() async {
          await media.delete();
          await external.delete();
          await directory.delete();
        });
        final origin = await ProgressiveOrigin.start(content: bytes);
        addTearDown(origin.close);
        origin.intercept = (request) async =>
            request.target.startsWith('/Videos/')
            ? (
                status: 200,
                headers: <String, String>{'Content-Type': 'text/plain'},
                body: utf8.encode(_externalCue),
              )
            : subtitleVideoReply(request, bytes);
        final api = EmbyApi(
          EmbySession(
            serverUrl: origin.origin,
            serverName: 'fixture',
            serverId: 'fixture',
            userId: 'fixture',
            username: 'fixture',
            accessToken: 'fixture-token',
            deviceId: 'fixture-device',
          ),
        );
        addTearDown(api.dispose);
        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null'),
        );
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        final engine = _ObservedEngine(player);
        final offline = mode == 'file-native' || mode == 'offline-external';
        final isExternal = mode.endsWith('external');
        final embed = mode == 'transcode-embed';
        final transcode = mode.startsWith('transcode');
        final plan = PlaybackPlan(
          uri: offline
              ? media.uri
              : Uri.parse('${origin.origin}/generated.mkv'),
          mediaSourceId: 'source',
          playSessionId: 'fixture-session',
          method: transcode ? PlayMethod.transcode : PlayMethod.directPlay,
          transportKind: offline
              ? PlaybackTransportKind.offlineLocal
              : PlaybackTransportKind.unknown,
          usesServerAuthentication: false,
          subtitleStreamIndex: 42,
          mediaStreams: [
            {
              'Index': 42,
              'Type': 'Subtitle',
              'Title': 'same',
              'Language': embed ? 'jpn' : 'eng',
              'Codec': 'hdmv_pgs_subtitle',
              'IsExternal': mode == 'offline-external',
              if (transcode)
                'DeliveryMethod': isExternal ? 'External' : 'Embed',
              'Format': isExternal ? 'srt' : 'ass',
              if (isExternal)
                'DeliveryUrl': offline
                    ? external.uri.toString()
                    : '/Videos/item/source/Subtitles/42/Stream.srt',
            },
          ],
          transcodingReasons: const [],
          availableMediaSources: const [],
        );
        final reporter = _Reporter();
        final controller = PlaybackController(
          item: EmbyItem.fromJson({
            'Id': 'item',
            'Name': 'fixture',
            'Type': 'Movie',
          }),
          engine: engine,
          resolver: _Resolver(plan),
          reporter: reporter,
          subtitleLoader: offline ? null : ExternalSubtitleLoader(api),
          playbackHeaders: const {},
          readyTimeout: const Duration(seconds: 8),
          trackWaitTimeout: const Duration(seconds: 4),
          progressInterval: const Duration(hours: 1),
        );
        addTearDown(controller.shutdown);
        await controller.start(playAfterReady: false);
        await _until(
          () async =>
              controller.state.subtitleSelectionStatus !=
              SubtitleSelectionStatus.applying,
        );
        if (!isExternal && !embed) {
          expect(
            controller.state.subtitleSelectionStatus,
            SubtitleSelectionStatus.failed,
          );
          final choices = controller.nativeSubtitleChoices;
          expect(choices, hasLength(3));
          expect(choices[0].track.title, choices[1].track.title);
          expect(choices[0].track.language, choices[1].track.language);
          for (final i in [0, 1, 0, 2, 1, 0]) {
            await controller.selectNativeSubtitle(choices[i]);
            expect(await native.getProperty('sid'), choices[i].track.id);
            expect(controller.state.appliedSubtitleStreamIndex, isNull);
            expect(reporter.last!.subtitleStreamIndex, isNull);
            await _expectCue(
              engine,
              native,
              subtitleCue(i, false),
              const Duration(seconds: 1),
            );
            await _expectCue(
              engine,
              native,
              subtitleCue(i, true),
              const Duration(seconds: 11),
            );
          }
        } else {
          expect(
            controller.state.subtitleSelectionStatus,
            isExternal
                ? SubtitleSelectionStatus.appliedExternal
                : SubtitleSelectionStatus.appliedEmbedded,
          );
          expect(await native.getProperty('sid'), isNot('no'));
          await _expectCue(
            engine,
            native,
            isExternal ? 'EXTERNAL_CUE' : subtitleCue(2, false),
            const Duration(seconds: 1),
          );
          if (isExternal) {
            expect(engine.externalUris.single.scheme, 'file');
            expect(
              await File.fromUri(engine.externalUris.single).exists(),
              isTrue,
            );
            if (!offline) {
              final requests = origin.requests
                  .where((request) => request.target.startsWith('/Videos/'))
                  .toList();
              expect(requests, hasLength(1));
              expect(requests.single.headers['x-emby-token'], 'fixture-token');
              await controller.shutdown();
              expect(
                await File.fromUri(engine.externalUris.single).exists(),
                isFalse,
              );
            }
          }
        }
        if (offline) {
          expect(origin.requests, isEmpty);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

Future<void> _expectCue(
  MediaKitPlaybackEngine engine,
  NativePlayer native,
  String cue,
  Duration position,
) async {
  await engine.seek(position);
  await engine.play();
  await _until(
    () async =>
        (await native.getProperty('sub-text')).trim() == cue &&
        engine.player.state.subtitle.first.trim() == cue,
    describe: () async =>
        'expected=$cue native=${await native.getProperty('sub-text')} '
        'overlay=${engine.player.state.subtitle} sid=${await native.getProperty('sid')} '
        'position=${await native.getProperty('time-pos')}',
  );
  // Production uses media_kit_video's Flutter SubtitleView (libass=false).
  // Native sub-visibility is deliberately disabled in this configuration.
  expect(engine.player.platform!.configuration.libass, isFalse);
  await engine.pause();
}

Future<void> _until(
  Future<bool> Function() check, {
  Future<String> Function()? describe,
}) async {
  for (var i = 0; i < 200; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail(
    'Expected subtitle state or decoded cue did not arrive: ${await describe?.call()}',
  );
}

class _ObservedEngine extends MediaKitPlaybackEngine {
  _ObservedEngine(super.player);
  final externalUris = <Uri>[];
  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) {
    externalUris.add(uri);
    return super.loadExternalSubtitle(uri, title: title, language: language);
  }
}

class _Resolver implements PlaybackStreamResolver {
  _Resolver(this.plan);
  final PlaybackPlan plan;
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
  }) async => plan;
}

class _Reporter implements PlaybackReporter {
  PlaybackPlan? last;
  @override
  void activate(PlaybackPlan plan) => last = plan;
  @override
  void updatePlan(PlaybackPlan plan) => last = plan;
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
