import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

// Requires actual host libmpv, as do the existing native input tests. Missing
// native support is a failure, never a skip. No external media or ffmpeg needed.
void main() {
  test(
    'actual native Matroska context permits SSA ASS identity and selection',
    () async {
      MediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-codec-native-',
      );
      addTearDown(() async {
        expect(
          directory.absolute.path,
          startsWith(
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
          ),
        );
        await directory.delete(recursive: true);
      });
      final file = File(
        '${directory.path}${Platform.pathSeparator}generated.mkv',
      );
      await file.writeAsBytes(_matroska());
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      final engine = MediaKitPlaybackEngine(player);
      addTearDown(engine.dispose);
      final discovered = engine.subtitleTracksStream
          .firstWhere((tracks) => tracks.any((track) => track.codec == 'ass'))
          .timeout(const Duration(seconds: 10));
      await engine.open(file.uri, headers: const {}, play: false);
      final tracks = await discovered;
      final track = tracks.singleWhere((track) => track.codec == 'ass');
      expect(await native.getProperty('current-demuxer'), 'mkv');
      expect(track.title, 'codec-fixture');
      expect(track.language, 'eng');
      final context = await engine.readSubtitleMappingContext();
      expect(context.isMpvMatroskaEmbedded(track), isTrue);
      const server = PlaybackTrack(
        index: 27,
        type: 'Subtitle',
        title: 'codec-fixture',
        language: 'eng',
        codec: 'ssa',
      );
      const mapper = TrackMapper();
      expect(
        mapper.match(server, tracks).reason,
        TrackMappingReason.metadataConflict,
      );
      final result = mapper.match(server, tracks, context: context);
      expect(result.status, TrackMappingStatus.matched);
      expect(result.engineId, track.id);
      expect(result.engineId, isNot('27'));
      await engine.selectSubtitleTrack(result.engineId);
      expect(await native.getProperty('sid'), track.id);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

// One second of silence plus one ASS cue, built using the Matroska element and
// subtitle specifications. The fixture is wholly synthetic and stays local.
// https://www.matroska.org/technical/elements.html
// https://www.matroska.org/technical/subtitles.html
List<int> _matroska() {
  final header = _element(0x1a45dfa3, [
    ..._uint(0x4286, 1),
    ..._uint(0x42f7, 1),
    ..._uint(0x42f2, 4),
    ..._uint(0x42f3, 8),
    ..._string(0x4282, 'matroska'),
    ..._uint(0x4287, 4),
    ..._uint(0x4285, 2),
  ]);
  final info = _element(0x1549a966, [
    ..._uint(0x2ad7b1, 1000000),
    ..._float(0x4489, 1000),
    ..._string(0x4d80, 'codec-test'),
    ..._string(0x5741, 'codec-test'),
  ]);
  final tracks = _element(0x1654ae6b, [
    ..._element(0xae, [
      ..._uint(0xd7, 1),
      ..._uint(0x73c5, 1),
      ..._uint(0x83, 2),
      ..._uint(0x9c, 0),
      ..._string(0x86, 'A_PCM/INT/LIT'),
      ..._element(0xe1, [
        ..._float(0xb5, 8000),
        ..._uint(0x9f, 1),
        ..._uint(0x6264, 16),
      ]),
    ]),
    ..._element(0xae, [
      ..._uint(0xd7, 2),
      ..._uint(0x73c5, 2),
      ..._uint(0x83, 17),
      ..._uint(0x9c, 0),
      ..._string(0x86, 'S_TEXT/ASS'),
      ..._string(0x536e, 'codec-fixture'),
      ..._string(0x22b59c, 'eng'),
      ..._string(0x63a2, '''[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 240
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
'''),
    ]),
  ]);
  final cluster = _element(0x1f43b675, [
    ..._uint(0xe7, 0),
    ..._element(0xa3, [0x81, 0, 0, 0x80, ...List.filled(16000, 0)]),
    ..._element(0xa0, [
      ..._element(0xa1, [
        0x82,
        0,
        0,
        0,
        ...utf8.encode('0,0,Default,,0,0,0,,Fixture'),
      ]),
      ..._uint(0x9b, 1000),
    ]),
  ]);
  return [
    ...header,
    ..._element(0x18538067, [...info, ...tracks, ...cluster]),
  ];
}

List<int> _bytes(int value) {
  final result = <int>[value & 255];
  while ((value >>= 8) > 0) {
    result.insert(0, value & 255);
  }
  return result;
}

List<int> _element(int id, List<int> body) {
  var width = 1;
  while (body.length >= (1 << (7 * width)) - 1) {
    width++;
  }
  final size = body.length | (1 << (7 * width));
  return [..._bytes(id), ..._bytes(size), ...body];
}

List<int> _uint(int id, int value) => _element(id, _bytes(value));
List<int> _string(int id, String value) => _element(id, utf8.encode(value));
List<int> _float(int id, double value) => _element(
  id,
  (ByteData(8)..setFloat64(0, value, Endian.big)).buffer.asUint8List(),
);
