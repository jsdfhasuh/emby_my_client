import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';

/// Local-interface miniature Emby contract serving generated test bytes. No real
/// server, account, credentials or media are accepted by this fixture.
class SyntheticPlaybackOrigin {
  SyntheticPlaybackOrigin._(this._server, this.media) {
    _subscription = _server.listen((request) => unawaited(_reply(request)));
  }
  final HttpServer _server;
  final Uint8List media;
  late final StreamSubscription<HttpRequest> _subscription;
  final requests = <String>[];
  final progressBodies = <Map<String, dynamic>>[];
  final _held = <Completer<void>>[];
  int subtitleStatus = 200;
  bool holdSubtitle = false;
  bool holdPlaybackInfo = false;
  int playbackInfoStatus = 200;
  final _heldPlaybackInfo = <Completer<void>>[];
  int activeRequests = 0;
  bool closed = false;
  String get origin => 'http://${_server.address.address}:${_server.port}';

  static Future<SyntheticPlaybackOrigin> start(Uint8List media) async {
    // Exercise the unchanged production destination policy, which rejects
    // loopback media URLs. Bind only the chosen host interface, not all IPs.
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final address = interfaces
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.isLoopback);
    return SyntheticPlaybackOrigin._(await HttpServer.bind(address, 0), media);
  }

  Map<String, dynamic> get source => {
    'Id': 'generated-source',
    'Name': 'Generated subtitles',
    'Path': '/generated/synthetic-pgs.mkv',
    'Protocol': 'File',
    'Container': 'mkv',
    'Size': media.length,
    'RunTimeTicks': 120000000,
    'SupportsDirectPlay': true,
    'SupportsDirectStream': false,
    'SupportsTranscoding': false,
    'DefaultSubtitleStreamIndex': -1,
    'MediaStreams': [
      {
        'Index': 0,
        'Type': 'Video',
        'Codec': 'mjpeg',
        'Width': 320,
        'Height': 180,
      },
      for (final row in [
        (2, 'PGS ALPHA', 'hdmv_pgs_subtitle'),
        (3, 'PGS BETA', 'hdmv_pgs_subtitle'),
        (4, 'TEXT', 'ass'),
      ])
        {
          'Index': row.$1,
          'Type': 'Subtitle',
          'Title': row.$2,
          'DisplayTitle': row.$2,
          'Language': 'eng',
          'Codec': row.$3,
          'IsExternal': false,
        },
      {
        'Index': 5,
        'Type': 'Subtitle',
        'Title': 'External SRT',
        'DisplayTitle': 'External SRT',
        'Language': 'eng',
        'Codec': 'srt',
        'Format': 'srt',
        'IsExternal': true,
        'DeliveryMethod': 'External',
        'DeliveryUrl':
            '/Videos/generated/generated-source/Subtitles/5/Stream.srt',
      },
    ],
  };

  EmbyItem get item => EmbyItem.fromJson({
    'Id': 'generated',
    'Name': 'Generated subtitle fixture',
    'Type': 'Movie',
    'RunTimeTicks': 120000000,
    'MediaSources': [source],
  });

  // Tests use this only in a scoped HttpOverrides zone around a fixture UI
  // interaction. The production loader's destination policy still applies.
  static HttpClient fixtureClient(SecurityContext? context) =>
      _FixtureHttpOverrides().createHttpClient(context)
        ..idleTimeout = Duration.zero;

  EmbyApi createApi() {
    final dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        // Only this fixture client bypasses TestWidgetsFlutterBinding's synthetic
        // HTTP 400 response. The origin serves no external/user resources.
        createHttpClient: () =>
            _FixtureHttpOverrides().createHttpClient(null)
              ..idleTimeout = Duration.zero,
      );
    return EmbyApi(
      EmbySession(
        serverUrl: origin,
        serverName: 'Synthetic local fixture',
        serverId: 'fixture',
        userId: 'fixture',
        username: 'fixture',
        accessToken: 'fixture-token',
        deviceId: 'fixture',
      ),
      dio: dio,
    );
  }

  void releaseSubtitle() {
    for (final gate in _held.toList()) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
    _held.clear();
  }

  void releasePlaybackInfo() {
    holdPlaybackInfo = false;
    for (final gate in _heldPlaybackInfo) {
      if (!gate.isCompleted) gate.complete();
    }
    _heldPlaybackInfo.clear();
  }

  Future<void> _reply(HttpRequest request) async {
    activeRequests++;
    requests.add(request.uri.path);
    // Do not leave keep-alive connection timers in the widget fake clock.
    request.response.persistentConnection = false;
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null ||
          (remote.address != _server.address.address && !remote.isLoopback)) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      if (path.contains('/Subtitles/')) {
        if (holdSubtitle) {
          final gate = Completer<void>();
          _held.add(gate);
          await gate.future;
        }
        if (closed) return;
        request.response.statusCode = subtitleStatus;
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          subtitleStatus == 200
              ? '1\n00:00:00,000 --> 00:00:12,000\nEXTERNAL_CUE\n'
              : 'Synthetic subtitle failure',
        );
      } else if (path.endsWith('/PlaybackInfo')) {
        if (holdPlaybackInfo) {
          final gate = Completer<void>();
          _heldPlaybackInfo.add(gate);
          await gate.future;
        }
        if (closed) return;
        request.response.statusCode = playbackInfoStatus;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'PlaySessionId': 'generated-session',
            'MediaSources': [source],
          }),
        );
      } else if (path.endsWith('/stream') || path == '/synthetic-pgs.mkv') {
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end = range == null || range[2]!.isEmpty
            ? media.length - 1
            : int.parse(range[2]!).clamp(0, media.length - 1);
        if (start > end) {
          request.response.statusCode = 416;
        } else {
          request.response.statusCode = range == null ? 200 : 206;
          request.response.headers.set('Content-Type', 'video/x-matroska');
          request.response.headers.set('Accept-Ranges', 'bytes');
          if (range != null) {
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/${media.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          request.response.add(media.sublist(start, end + 1));
        }
      } else if (path.contains('/Sessions/Playing')) {
        final body = await utf8.decoder.bind(request).join();
        if (body.isNotEmpty) {
          progressBodies.add(jsonDecode(body) as Map<String, dynamic>);
        }
        request.response.statusCode = 204;
      } else if (path.endsWith('/Items/generated')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'Id': 'generated',
            'Name': 'Generated subtitle fixture',
            'Type': 'Movie',
            'RunTimeTicks': 120000000,
            'MediaSources': [source],
          }),
        );
      } else if (path.contains('/ActiveEncodings')) {
        request.response.statusCode = 204;
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    } on HttpException {
      // A deliberately cancelled fixture request closes its socket.
    } on SocketException {
      // Expected when disposal interrupts the pending synthetic response.
    } finally {
      activeRequests--;
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    releaseSubtitle();
    releasePlaybackInfo();
    await _server.close(force: true);
    await _subscription.cancel();
  }
}

class _FixtureHttpOverrides extends HttpOverrides {}
