import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/progressive_fixture.dart';
import 'support/subtitle_media_fixture.dart';

// Uses the same SubtitleView as production Video, with actual decoded media_kit
// subtitle events. Only the unrelated platform video texture is omitted.
void main() {
  for (final http in [false, true]) {
    testWidgets(
      'decoded ${http ? 'HTTP' : 'file'} subtitles paint after A B A and disable',
      (tester) async {
        late Player player;
        late MediaKitPlaybackEngine engine;
        late Directory directory;
        late ProgressiveOrigin origin;
        late List<EngineTrack> tracks;
        late NativePlayer native;
        final nativeErrors = <String>[];
        final observers = <StreamSubscription<dynamic>>[];
        var subtitleRevision = 0;
        await tester.runAsync(() async {
          MediaKit.ensureInitialized();
          directory = await Directory.systemTemp.createTemp('subtitle-paint-');
          final bytes = subtitleMediaFixture();
          final file = File('${directory.path}/generated.mkv');
          await file.writeAsBytes(bytes);
          origin = await ProgressiveOrigin.start(content: bytes);
          origin.intercept = (request) async =>
              subtitleVideoReply(request, bytes);
          player = Player(configuration: const PlayerConfiguration(vo: 'null'));
          engine = MediaKitPlaybackEngine(player);
          native = player.platform as NativePlayer;
          observers.add(
            player.stream.log.listen((entry) {
              if (entry.level == 'error' || entry.level == 'fatal') {
                nativeErrors.add('${entry.prefix}: ${entry.text}');
              }
            }),
          );
          observers.add(
            player.stream.subtitle.listen((_) => subtitleRevision++),
          );
          await native.setProperty('ao', 'null');
          // This SubtitleView test has no VideoController. Use the generated
          // raw-video clock, not the null audio driver's rapid-seek state machine.
          await native.setProperty('aid', 'no');
          await native.setProperty('vid', 'auto');
          // Disk caching is covered separately and needs a host cache directory.
          await native.setProperty('cache-on-disk', 'no');
          final discovered = engine.subtitleTracksStream.firstWhere(
            (value) => value.where(TrackMapper.isRealTrack).length == 3,
          );
          await engine.open(
            http ? Uri.parse('${origin.origin}/generated.mkv') : file.uri,
            headers: const {},
            play: false,
          );
          tracks = (await discovered.timeout(
            const Duration(seconds: 10),
          )).where(TrackMapper.isRealTrack).toList();
          for (final path in [
            'C:/Windows/Fonts/arial.ttf',
            '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
          ]) {
            final font = File(path);
            if (await font.exists()) {
              final loader = FontLoader('SubtitleFixture');
              loader.addFont(
                font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
              );
              await loader.load();
              break;
            }
          }
        });
        addTearDown(() async {
          await engine.dispose();
          for (final observer in observers) {
            await observer.cancel();
          }
          await origin.close();
          await File('${directory.path}/generated.mkv').delete();
          await directory.delete();
          expect(nativeErrors, isEmpty, reason: 'Native subtitle test errors');
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 640,
                height: 360,
                child: RepaintBoundary(
                  key: key,
                  child: ColoredBox(
                    color: Colors.black,
                    child: SubtitleView(
                      controller: _SubtitleController(player),
                      configuration: const SubtitleViewConfiguration(
                        style: TextStyle(
                          fontFamily: 'SubtitleFixture',
                          fontSize: 32,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (final (step, index) in [0, 1, 0, 2].indexed) {
          // Distinct forward/backward targets cannot accept the previous seek's
          // position. All remain inside the real first cue's [0, 10) interval.
          final target = [1, 3, 2, 4][step];
          final stage = '${http ? 'HTTP' : 'file'} step=$step track=$index';
          final beforeSelection = subtitleRevision;
          final cue = subtitleCue(index, false);
          final decoded = await tester.runAsync(() async {
            await engine.selectSubtitleTrack(tracks[index].id);
            await engine.seek(Duration(seconds: target));
            await engine.play();
            await _until(
              () async {
                final state = await _nativeState(native);
                final position = double.tryParse(state['time-pos'] ?? '');
                return subtitleRevision > beforeSelection &&
                    player.state.subtitle.first.trim() == cue &&
                    state['sub-text']?.trim() == cue &&
                    state['sid'] == tracks[index].id &&
                    state['seeking'] == 'no' &&
                    position != null &&
                    position >= target + 0.1 &&
                    position < target + 0.8;
              },
              stage: '$stage expected=$cue target=$target',
              player: player,
              native: native,
              nativeErrors: nativeErrors,
            );
            await engine.pause();
            expect(nativeErrors, isEmpty, reason: stage);
            expect(await native.getProperty('sid'), tracks[index].id);
            expect(await native.getProperty('sub-text'), cue);
            expect(await native.getProperty('aid'), 'no');
            expect(await native.getProperty('vid'), '1');
            expect(await native.getProperty('cache-on-disk'), 'no');
            return true;
          });
          expect(decoded, isTrue, reason: stage);
          await tester.pump();
          expect(find.text(cue), findsOneWidget);
          expect(tester.getSize(find.text(cue)).height, greaterThan(0));
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final frame = await boundary.toImage();
            final rgba = (await frame.toByteData())!.buffer.asUint8List();
            var bright = 0;
            for (var i = 0; i < rgba.length; i += 4) {
              if (rgba[i] > 180 && rgba[i + 1] > 180 && rgba[i + 2] > 180) {
                bright++;
              }
            }
            expect(
              bright,
              greaterThan(50),
              reason: 'Decoded cue must paint visible glyphs',
            );
            final output = Platform.environment['SUBTITLE_RENDER_EVIDENCE'];
            if (output != null) {
              final png = (await frame.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List();
              await File(
                '$output/${http ? 'http' : 'file'}-$step-track-$index.png',
              ).writeAsBytes(png);
            }
            frame.dispose();
          });
        }
        await tester.runAsync(() async {
          await engine.selectSubtitleTrack(null);
          await engine.play();
          await _until(
            () async =>
                player.state.subtitle.every((line) => line.trim().isEmpty) &&
                await native.getProperty('sid') == 'no',
            stage: '${http ? 'HTTP' : 'file'} disabled',
            player: player,
            native: native,
            nativeErrors: nativeErrors,
          );
          await engine.pause();
        });
        await tester.pump();
        for (var index = 0; index < 3; index++) {
          expect(find.text(subtitleCue(index, false)), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

Future<Map<String, String>> _nativeState(NativePlayer native) async {
  final result = <String, String>{};
  for (final property in [
    'sid',
    'time-pos',
    'seeking',
    'pause',
    'sub-text',
    'sub-start',
    'sub-end',
    'aid',
    'vid',
  ]) {
    result[property] = await native.getProperty(property);
  }
  return result;
}

Future<void> _until(
  Future<bool> Function() check, {
  required String stage,
  required Player player,
  required NativePlayer native,
  required List<String> nativeErrors,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (nativeErrors.isNotEmpty) break;
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail(
    'Decoded subtitle did not reach $stage: ${jsonEncode({'native': await _nativeState(native), 'subtitle': player.state.subtitle, 'positionMs': player.state.position.inMilliseconds, 'nativeErrors': nativeErrors})}',
  );
}

class _SubtitleController implements VideoController {
  _SubtitleController(this.player);
  @override
  final Player player;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
