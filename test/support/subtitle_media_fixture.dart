import 'dart:convert';
import 'dart:typed_data';
import 'progressive_fixture.dart';

/// Self-generated 20s Matroska: 32x24 raw BGR video, PCM silence and three ASS
/// tracks. The first two tracks intentionally have the same title/language.
/// No downloaded media, codec tools, or user data are involved.
Uint8List subtitleMediaFixture() {
  final bitmap = ByteData(40)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, 32, Endian.little)
    ..setInt32(8, 24, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 24, Endian.little)
    ..setUint32(20, 32 * 24 * 3, Endian.little);
  final tracks = _element(0x1654ae6b, [
    ..._element(0xae, [
      ..._uint(0xd7, 1),
      ..._uint(0x73c5, 1),
      ..._uint(0x83, 1),
      ..._string(0x86, 'V_MS/VFW/FOURCC'),
      ..._element(0x63a2, bitmap.buffer.asUint8List()),
      ..._uint(0x23e383, 100000000),
      ..._element(0xe0, [..._uint(0xb0, 32), ..._uint(0xba, 24)]),
    ]),
    ..._element(0xae, [
      ..._uint(0xd7, 2),
      ..._uint(0x73c5, 2),
      ..._uint(0x83, 2),
      ..._string(0x86, 'A_PCM/INT/LIT'),
      ..._element(0xe1, [
        ..._float(0xb5, 8000),
        ..._uint(0x9f, 1),
        ..._uint(0x6264, 16),
      ]),
    ]),
    for (var i = 0; i < 3; i++)
      ..._element(0xae, [
        ..._uint(0xd7, i + 3),
        ..._uint(0x73c5, i + 3),
        ..._uint(0x83, 17),
        ..._uint(0x88, 0),
        ..._string(0x86, 'S_TEXT/ASS'),
        ..._string(0x536e, 'same'),
        ..._string(0x22b59c, i == 2 ? 'jpn' : 'eng'),
        ..._string(0x63a2, _assHeader),
      ]),
  ]);
  final clusters = <int>[];
  for (var second = 0; second < 20; second++) {
    clusters.addAll(
      _element(0x1f43b675, [
        ..._uint(0xe7, second * 1000),
        // Cues precede the video/audio at their presentation time.
        if (second == 0 || second == 10)
          for (var track = 0; track < 3; track++)
            ..._element(0xa0, [
              ..._element(0xa1, [
                0x83 + track,
                0,
                0,
                0,
                ...utf8.encode(
                  '$second,0,Default,,0,0,0,,${subtitleCue(track, second == 10)}',
                ),
              ]),
              ..._uint(0x9b, 10000),
            ]),
        ..._element(0xa3, [0x82, 0, 0, 0x80, ...List.filled(16000, 0)]),
        for (var frame = 0; frame < 10; frame++)
          ..._element(0xa3, [
            0x81,
            (frame * 100) >> 8,
            (frame * 100) & 255,
            0x80,
            for (var pixel = 0; pixel < 32 * 24; pixel++) ...[
              40 + second,
              30 + frame,
              80,
            ],
          ]),
      ]),
    );
  }
  return Uint8List.fromList([
    ..._element(0x1a45dfa3, [
      ..._uint(0x4286, 1),
      ..._uint(0x42f7, 1),
      ..._uint(0x42f2, 4),
      ..._uint(0x42f3, 8),
      ..._string(0x4282, 'matroska'),
      ..._uint(0x4287, 4),
      ..._uint(0x4285, 2),
    ]),
    ..._element(0x18538067, [
      ..._element(0x1549a966, [
        ..._uint(0x2ad7b1, 1000000),
        ..._float(0x4489, 20000),
        ..._string(0x4d80, 'subtitle-fixture'),
        ..._string(0x5741, 'subtitle-fixture'),
      ]),
      ...tracks,
      ...clusters,
    ]),
  ]);
}

String subtitleCue(int track, bool second) =>
    'CUE_${['ALPHA', 'BETA', 'GAMMA'][track]}_${second ? 'SECOND' : 'FIRST'}';

const _assHeader = '''[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 240
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';
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
  return [..._bytes(id), ..._bytes(body.length | (1 << (7 * width))), ...body];
}

List<int> _uint(int id, int value) => _element(id, _bytes(value));
List<int> _string(int id, String value) => _element(id, utf8.encode(value));
List<int> _float(int id, double value) => _element(
  id,
  (ByteData(8)..setFloat64(0, value, Endian.big)).buffer.asUint8List(),
);

// Native libmpv sends open-ended byte ranges, unlike the controlled input
// adapter. Reply with the requested offset and normal 200 responses otherwise.
FixtureReply subtitleVideoReply(FixtureRequest request, Uint8List bytes) {
  final range = RegExp(
    r'^bytes=(\d+)-(\d*)$',
  ).firstMatch(request.headers['range'] ?? '');
  final start = range == null ? 0 : int.parse(range[1]!);
  final end = range == null || range[2]!.isEmpty
      ? bytes.length - 1
      : int.parse(range[2]!).clamp(start, bytes.length - 1);
  if (start >= bytes.length) {
    return (
      status: 416,
      headers: {'Content-Range': 'bytes */${bytes.length}'},
      body: <int>[],
    );
  }
  return (
    status: range == null ? 200 : 206,
    headers: {
      'Content-Type': 'video/x-matroska',
      'Accept-Ranges': 'bytes',
      if (range != null) 'Content-Range': 'bytes $start-$end/${bytes.length}',
    },
    body: bytes.sublist(start, end + 1),
  );
}
