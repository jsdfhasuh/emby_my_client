import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/ui/widgets/configured_playback_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Uses production SubtitleView and its real raster output. Only the native
// video texture and decoded-cue source are replaced; no platform plugin runs.
void main() {
  testWidgets(
    'size, fill and outline settings repaint the existing subtitle glyphs',
    (tester) async {
      await _prepare(tester);
      final player = _CuePlayer()..emit('SYNTHETIC CUE');
      addTearDown(player.close);
      final controller = _CueController(player);
      final boundary = GlobalKey();
      var settings = const PlaybackSettings(subtitleFontSize: 32);
      await _mount(tester, boundary, controller, settings);
      final viewState = tester.state(find.byType(SubtitleView));
      final small = await _capture(tester, boundary, 'size-small');
      settings = settings.copyWith(subtitleFontSize: 64);
      await _mount(tester, boundary, controller, settings);
      expect(tester.state(find.byType(SubtitleView)), same(viewState));
      final large = await _capture(tester, boundary, 'size-large');
      expect(large.white.count, greaterThan(small.white.count * 2));
      expect(
        large.white.bounds.height,
        greaterThan(small.white.bounds.height * 1.4),
      );
      settings = settings.copyWith(
        subtitleColor: 0xFFFFFF00,
        subtitleOutlineColor: 0xFFFF0000,
      );
      await _mount(tester, boundary, controller, settings);
      final colored = await _capture(tester, boundary, 'color-outline');
      expect(colored.yellow.count, greaterThan(100));
      expect(colored.red.count, greaterThan(20));
      expect(colored.white.count, 0);
      expect(
        colored.yellow.bounds.height,
        closeTo(large.white.bounds.height, 1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('position moves painted glyphs without changing their size', (
    tester,
  ) async {
    await _prepare(tester);
    final player = _CuePlayer()..emit('POSITION CUE');
    addTearDown(player.close);
    final controller = _CueController(player);
    final boundary = GlobalKey();
    const settings = PlaybackSettings(subtitleFontSize: 64);
    await _mount(tester, boundary, controller, settings);
    final bottom = await _capture(tester, boundary, 'position-bottom');
    await _mount(
      tester,
      boundary,
      controller,
      settings.copyWith(subtitlePosition: 75),
    );
    final raised = await _capture(tester, boundary, 'position-raised');
    expect(bottom.white.bounds.top - raised.white.bounds.top, closeTo(135, 1));
    expect(raised.white.bounds.width, closeTo(bottom.white.bounds.width, 1));
    expect(raised.white.bounds.height, closeTo(bottom.white.bounds.height, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'seek and track cue updates retain style and reopening replaces the subtitle subscription',
    (tester) async {
      await _prepare(tester);
      final first = _CuePlayer()..emit('CUE BEFORE SEEK');
      final second = _CuePlayer()..emit('FRESH REOPEN CUE');
      addTearDown(first.close);
      addTearDown(second.close);
      final firstController = _CueController(first);
      final secondController = _CueController(second);
      final boundary = GlobalKey();
      const settings = PlaybackSettings(
        subtitleFontSize: 64,
        subtitleColor: 0xFFFFFF00,
        subtitleOutlineColor: 0xFFFF0000,
        subtitlePosition: 75,
      );
      await _mount(tester, boundary, firstController, const PlaybackSettings());
      await _mount(tester, boundary, firstController, settings);
      final beforeSeek = await _capture(tester, boundary, 'before-seek');
      // A seek clears the active cue before the new timestamp's event arrives.
      first.emit('');
      await tester.pump();
      final cleared = await _capture(tester, boundary, 'seek-cleared');
      expect(cleared.yellow.count, 0);
      first.emit('CUE AFTER SEEK');
      await tester.pump();
      final afterSeek = await _capture(tester, boundary, 'seek-cue');
      expect(afterSeek.yellow.count, greaterThan(100));
      expect(afterSeek.white.count, 0);
      expect(
        afterSeek.yellow.bounds.height,
        closeTo(beforeSeek.yellow.bounds.height, 2),
      );
      expect(
        afterSeek.yellow.bounds.top,
        closeTo(beforeSeek.yellow.bounds.top, 2),
      );
      first.emit('CUE AFTER TRACK');
      await tester.pump();
      expect(find.text('CUE AFTER TRACK'), findsOneWidget);
      final afterTrack = await _capture(tester, boundary, 'track-cue');
      expect(afterTrack.yellow.count, greaterThan(100));
      expect(afterTrack.red.count, greaterThan(20));
      expect(
        afterTrack.yellow.bounds.height,
        closeTo(beforeSeek.yellow.bounds.height, 2),
      );
      expect(
        afterTrack.yellow.bounds.top,
        closeTo(afterSeek.yellow.bounds.top, 2),
      );
      await _mount(tester, boundary, secondController, settings);
      expect(find.text('FRESH REOPEN CUE'), findsOneWidget);
      first.emit('STALE RETIRED CUE');
      second.emit('LIVE REOPEN CUE');
      await tester.pump();
      expect(find.text('LIVE REOPEN CUE'), findsOneWidget);
      expect(find.text('STALE RETIRED CUE'), findsNothing);
      final reopened = await _capture(tester, boundary, 'reopened-cue');
      expect(reopened.yellow.count, greaterThan(100));
      expect(reopened.red.count, greaterThan(20));
      expect(reopened.white.count, 0);
      expect(
        reopened.yellow.bounds.height,
        closeTo(beforeSeek.yellow.bounds.height, 2),
      );
      expect(
        reopened.yellow.bounds.top,
        closeTo(afterTrack.yellow.bounds.top, 2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _prepare(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    for (final path in [
      'C:/Windows/Fonts/arial.ttf',
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    ]) {
      final font = File(path);
      if (await font.exists()) {
        final loader = FontLoader('SubtitlePixels');
        loader.addFont(font.readAsBytes().then(ByteData.sublistView));
        await loader.load();
        break;
      }
    }
  });
}

Future<void> _mount(
  WidgetTester tester,
  GlobalKey key,
  VideoController controller,
  PlaybackSettings settings,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'SubtitlePixels'),
      home: Center(
        child: SizedBox(
          width: 960,
          height: 540,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black,
              child: ConfiguredPlaybackSubtitles(
                controller: controller,
                settings: settings,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<_Frame> _capture(
  WidgetTester tester,
  GlobalKey key,
  String label,
) async {
  late _Frame result;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      result = _Frame(bytes, image.width, image.height);
      final directory = Platform.environment['SUBTITLE_PRESENTATION_EVIDENCE'];
      if (directory != null) {
        await Directory(directory).create(recursive: true);
        await File('$directory/$label.png').writeAsBytes(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
      }
    } finally {
      image.dispose();
    }
  });
  return result;
}

class _Frame {
  _Frame(Uint8List pixels, int width, int height) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = (y * width + x) * 4;
        final r = pixels[at], g = pixels[at + 1], b = pixels[at + 2];
        if (r > 180 && g > 180 && b > 180) white.add(x, y);
        if (r > 180 && g > 180 && b < 80) yellow.add(x, y);
        if (r > 120 && g < 80 && b < 80) red.add(x, y);
      }
    }
  }
  final white = _Ink(), yellow = _Ink(), red = _Ink();
}

class _Ink {
  int count = 0;
  double left = double.infinity, top = double.infinity, right = 0, bottom = 0;
  void add(int x, int y) {
    count++;
    if (x < left) left = x.toDouble();
    if (y < top) top = y.toDouble();
    if (x >= right) right = x + 1;
    if (y >= bottom) bottom = y + 1;
  }

  Rect get bounds => Rect.fromLTRB(left, top, right, bottom);
}

class _CuePlayer extends Fake implements Player {
  final cues = StreamController<List<String>>.broadcast(sync: true);
  PlayerState _state = const PlayerState();
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _CueStream(cues.stream);
  void emit(String cue) {
    _state = _state.copyWith(subtitle: [cue, '']);
    cues.add(_state.subtitle);
  }

  Future<void> close() => cues.close();
}

class _CueStream extends Fake implements PlayerStream {
  _CueStream(this.subtitle);
  @override
  final Stream<List<String>> subtitle;
}

class _CueController extends Fake implements VideoController {
  _CueController(this.player);
  @override
  final Player player;
}
