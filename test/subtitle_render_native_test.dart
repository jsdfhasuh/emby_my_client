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
          await (player.platform as NativePlayer).setProperty('ao', 'null');
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
          await origin.close();
          await File('${directory.path}/generated.mkv').delete();
          await directory.delete();
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
        for (final index in [0, 1, 0, 2]) {
          final cue = subtitleCue(index, false);
          await tester.runAsync(() async {
            await engine.selectSubtitleTrack(tracks[index].id);
            await engine.seek(const Duration(seconds: 1));
            await engine.play();
            await _until(() => player.state.subtitle.first.trim() == cue);
            await engine.pause();
          });
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
                '$output/${http ? 'http' : 'file'}-$index.png',
              ).writeAsBytes(png);
            }
            frame.dispose();
          });
        }
        await tester.runAsync(() async {
          await engine.selectSubtitleTrack(null);
          await engine.play();
          await _until(
            () => player.state.subtitle.every((line) => line.trim().isEmpty),
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

Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 200; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('Decoded subtitle stream did not reach the expected cue');
}

class _SubtitleController implements VideoController {
  _SubtitleController(this.player);
  @override
  final Player player;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
