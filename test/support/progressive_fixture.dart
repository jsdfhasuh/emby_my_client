import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Uint8List progressiveVideo() {
  Uint8List words(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  List<int> chunk(String type, List<int> bytes) => [
    ...ascii.encode(type),
    ...words([bytes.length]),
    ...bytes,
    if (bytes.length.isOdd) 0,
  ];
  const frameSize = 32 * 24 * 3;
  const frames = 240;
  final header = chunk(
    'avih',
    words([
      100000,
      frameSize * 10,
      0,
      16,
      frames,
      0,
      1,
      frameSize,
      32,
      24,
      0,
      0,
      0,
      0,
    ]),
  );
  final streamHeader = <int>[
    ...ascii.encode('vidsDIB '),
    ...words([0, 0, 0, 1, 10, 0, frames, frameSize, 0xffffffff, 0]),
    0,
    0,
    0,
    0,
    32,
    0,
    24,
    0,
  ];
  final bitmap = <int>[
    ...words([40, 32, 24]),
    1,
    0,
    24,
    0,
    ...words([0, frameSize, 0, 0, 0, 0]),
  ];
  final hdrl = chunk('LIST', [
    ...ascii.encode('hdrl'),
    ...header,
    ...chunk('LIST', [
      ...ascii.encode('strl'),
      ...chunk('strh', streamHeader),
      ...chunk('strf', bitmap),
    ]),
  ]);
  final movie = BytesBuilder();
  final index = BytesBuilder();
  for (var f = 0; f < frames; f++) {
    index.add([
      ...ascii.encode('00db'),
      ...words([16, movie.length + 4, frameSize]),
    ]);
    movie.add(
      chunk('00db', List.generate(frameSize, (p) => (p + f * 7) % 256)),
    );
  }
  return Uint8List.fromList(
    chunk('RIFF', [
      ...ascii.encode('AVI '),
      ...hdrl,
      ...chunk('LIST', [...ascii.encode('movi'), ...movie.takeBytes()]),
      ...chunk('idx1', index.takeBytes()),
    ]),
  );
}

typedef FixtureRequest = ({String target, Map<String, String> headers});
typedef FixtureReply = ({
  int status,
  Map<String, String> headers,
  List<int> body,
});

/// Raw socket fixture records the actual request line, before URI parsing.
class ProgressiveOrigin {
  ProgressiveOrigin._(this.server, this.host, this.bytes);
  final ServerSocket server;
  final String host;
  final Uint8List bytes;
  final requests = <FixtureRequest>[];
  final sockets = <Socket>[];
  Future<FixtureReply?> Function(FixtureRequest)? intercept;
  String get origin => 'http://$host:${server.port}';

  static Future<ProgressiveOrigin> start({Uint8List? content}) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final host = interfaces
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.isLoopback)
        .address;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final fixture = ProgressiveOrigin._(
      server,
      host,
      content ?? progressiveVideo(),
    );
    server.listen(fixture._accept);
    return fixture;
  }

  void _accept(Socket socket) {
    sockets.add(socket);
    var pending = '';
    var handled = false;
    socket.listen((bytes) {
      if (handled) return;
      pending += latin1.decode(bytes);
      if (!pending.contains('\r\n\r\n')) return;
      handled = true;
      final lines = pending.split('\r\n');
      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).toLowerCase()] = line
              .substring(colon + 1)
              .trim();
        }
      }
      final request = (target: lines.first.split(' ')[1], headers: headers);
      requests.add(request);
      unawaited(_reply(socket, request));
    }, onError: (_) {});
  }

  Future<void> _reply(Socket socket, FixtureRequest request) async {
    try {
      var reply = await intercept?.call(request);
      if (reply == null) {
        final range = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers['range'] ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end = (range == null ? bytes.length - 1 : int.parse(range[2]!))
            .clamp(0, bytes.length - 1);
        reply = (
          status: 206,
          headers: {
            'Content-Range': 'bytes $start-$end/${bytes.length}',
            'ETag': '"fixture-v1"',
          },
          body: bytes.sublist(start, end + 1),
        );
      }
      socket.add(
        latin1.encode(
          'HTTP/1.1 ${reply.status} Fixture\r\nConnection: close\r\nContent-Length: ${reply.body.length}\r\n${reply.headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}\r\n',
        ),
      );
      socket.add(reply.body);
      await socket.flush();
      await socket.close();
    } catch (_) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    for (final s in sockets) {
      s.destroy();
    }
    await server.close();
  }
}
