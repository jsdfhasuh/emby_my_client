import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:emby_my_client/playback/strm_direct_play_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/progressive_fixture.dart';

const _headers = {
  'X-Emby-Token': 'fixture-token',
  'X-Emby-Authorization': 'MediaBrowser fixture-authorization',
  'Authorization': 'Bearer fixture-bearer',
  'Cookie': 'fixture-cookie',
  'X-Private': 'fixture-private',
};
const _query = 'MediaSourceId=source&PlaySessionId=play&Static=true';
const _path = '/emby/Videos/item/stream.avi';

PlaybackResourceRequest _request({
  String origin = 'https://emby.invalid',
  String? raw,
  Map<String, String> headers = _headers,
  bool Function()? active,
}) => PlaybackResourceRequest.progressive(
  rawUrl: raw ?? '$origin$_path?$_query&api_key=fixture-token',
  headers: headers,
  embyServer: Uri.parse('$origin/emby'),
  isSessionActive: active,
  identity: PlaybackResourceIdentity(
    scope: const ServerScope(serverId: 'server', userId: 'user'),
    apiSession: Object(),
    itemId: 'item',
    sourceId: 'source',
    itemSession: Object(),
    generation: 7,
  ),
);

Matcher get _invalid => throwsA(
  isA<PlaybackResolveException>().having(
    (error) => error.failure,
    'failure',
    PlaybackResolveFailure.invalidSourceRequest,
  ),
);

Uint8List _content(int length) {
  final bytes = Uint8List(length);
  for (var index = 0; index < length; index++) {
    bytes[index] = index % 251;
  }
  bytes.setRange(0, 12, progressiveVideo().take(12));
  return bytes;
}

Future<void> _until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      fail('Fixture condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('ordinary admission is explicit; the STRM default remains strict', () {
    final request = _request();
    expect(request.isProgressive, isTrue);
    expect(request.allowsNativeFallback, isTrue);
    expect(request.headers, _headers);
    expect(request.rawUrl, endsWith('&api_key=fixture-token'));
    expect(request.toString(), 'PlaybackResourceRequest(progressive)');
    expect(() => request.headers.clear(), throwsUnsupportedError);
    final rootRequest = PlaybackResourceRequest.progressive(
      rawUrl: 'https://emby.invalid/videos/item/stream?MediaSourceId=source',
      headers: _headers,
      identity: request.identity,
      embyServer: Uri.parse('https://emby.invalid/'),
    );
    expect(rootRequest.isProgressive, isTrue);
    expect(
      () => PlaybackResourceRequest(
        rawUrl: request.rawUrl,
        headers: const {},
        identity: request.identity,
        embyServer: request.embyServer,
      ),
      _invalid,
    );
    expect(
      () => PlaybackResourceRequest(
        rawUrl: 'https://cdn.invalid/video.avi',
        headers: _headers,
        identity: request.identity,
        embyServer: request.embyServer,
      ),
      _invalid,
    );
    final source = PlaybackResourceRequest(
      rawUrl: 'https://cdn.invalid/video.avi?api_key=upstream',
      headers: const {'Authorization': 'upstream'},
      identity: request.identity,
      embyServer: request.embyServer,
    );
    expect(source.isProgressive, isFalse);
    expect(
      source.redirectTarget(source.rawUrl, credentialsAllowed: false),
      source.rawUrl,
    );
  });

  test('admission binds origin, base path, selected item/source and route', () {
    for (final raw in [
      'https://other.invalid$_path?$_query',
      'http://emby.invalid$_path?$_query',
      'https://emby.invalid:8443$_path?$_query',
      'https://emby.invalid/Videos/item/stream.avi',
      'https://emby.invalid/emby-other/Videos/item/stream.avi',
      'https://emby.invalid/emby/Videos/other/stream.avi',
      'https://emby.invalid/emby/Items/item/Download',
      'https://emby.invalid/emby/Users',
      'https://emby.invalid/emby/Videos/item/master.m3u8',
      'https://emby.invalid/emby/Videos/item/stream.mpd',
      'https://emby.invalid/emby/Videos/item/stream.strm',
      'https://emby.invalid/emby/Videos/item/stream.avi?MediaSourceId=other',
      'https://emby.invalid/emby/Videos/item/stream.avi?MediaSourceId=source&mediasourceid=other',
      'https://emby.invalid/emby/Videos/item/stream.avi?LiveStreamId=live',
      'https://emby.invalid/emby/Videos/item/stream.avi?TranscodingProtocol=hls',
      'https://emby.invalid/emby/Videos/item/../item/stream.avi',
      'https://emby.invalid/emby/Videos/item/%2e%2e/item/stream.avi',
      'https://emby.invalid/emby%2fVideos/item/stream.avi',
      'https://emby.invalid/emby/Videos/item/stream.avi#fragment',
    ]) {
      expect(() => _request(raw: raw), _invalid, reason: raw);
    }
    for (final headers in <Map<String, String>>[
      {'Host': 'other'},
      {'Range': 'bytes=1-'},
      {'Connection': 'close'},
      {'X-Emby-Token': 'one', 'x-emby-token': 'two'},
      {'X-Emby-Token': 'one\r\ntwo'},
    ]) {
      expect(() => _request(headers: headers), _invalid);
    }
  });

  test('redirect destination and resolved-address validation stay scoped', () {
    final request = _request();
    for (final raw in [
      'https://emby.invalid/emby/Users',
      'https://emby.invalid$_path?MediaSourceId=other',
      'https://emby.invalid$_path?MediaSourceId=source&PlaySessionId=other&Static=true',
      'https://emby.invalid$_path?$_query&StartTimeTicks=1',
      'https://emby.invalid$_path',
      'https://cdn.invalid/Videos/item/stream.avi',
      'https://cdn.invalid/Items/item/Download',
      'https://cdn.invalid/a.m3u8',
      'https://cdn.invalid/a.%6d3u8',
      'https://cdn.invalid/a.mpd',
      'https://cdn.invalid/hls/0.ts',
      'http://localhost/video.avi',
      'http://127.0.0.1/video.avi',
      'http://0.0.0.0/video.avi',
      'http://[::1]/video.avi',
      'http://[::ffff:127.0.0.1]/video.avi',
      'http://2130706433/video.avi',
    ]) {
      expect(() => request.validateTarget(raw), _invalid, reason: raw);
    }
    request.validateTarget('https://cdn.invalid/a%2fb.avi?sig=%7e');
    for (final address in [
      '127.0.0.1',
      '0.0.0.0',
      '::1',
      '::',
      '::ffff:127.0.0.1',
    ]) {
      expect(
        () => request.validateResolvedAddress(InternetAddress(address)),
        _invalid,
      );
    }
    request.validateResolvedAddress(InternetAddress('192.168.1.2'));
    expect(
      () => request.redirectTarget(
        'https://cdn.invalid/video.avi?api_key=fixture-token#fragment',
        credentialsAllowed: false,
      ),
      _invalid,
    );
  });

  test(
    'authenticated prepare, parallel reads and seek preserve exact bytes',
    () async {
      const block = 1024 * 1024;
      final server = await ProgressiveOrigin.start(
        content: _content(14 * block),
      );
      addTearDown(server.close);
      final request = _request(origin: server.origin);
      final input = SourceHttpInput(
        request,
        embyServer: request.embyServer,
        rangeBytes: block,
      );
      addTearDown(input.close);
      await input.prepare();
      expect(input.format, 'avi');
      expect(input.size, server.bytes.length);
      expect(
        await input.read(block, 65536),
        server.bytes.sublist(block, block + 65536),
      );
      await _until(() => input.reservedBytes == 0);
      expect(server.requests.length, greaterThan(2));
      expect(input.prefetchConcurrency, 8);
      expect(
        await input.read(11 * block, 65536),
        server.bytes.sublist(11 * block, 11 * block + 65536),
      );
      expect(await input.read(10, 100), server.bytes.sublist(10, 110));
      for (final wire in server.requests) {
        expect(wire.target, '$_path?$_query&api_key=fixture-token');
        expect(wire.headers['x-emby-token'], 'fixture-token');
        expect(
          wire.headers['x-emby-authorization'],
          _headers['X-Emby-Authorization'],
        );
        expect(wire.headers['authorization'], _headers['Authorization']);
        expect(wire.headers['range'], startsWith('bytes='));
      }
      expect(
        input.cachedBytes + input.reservedBytes,
        lessThanOrEqualTo(SourceHttpInput.cacheBudget),
      );
      input.close();
      await _until(() => input.reservedBytes == 0);
      expect(input.cachedBytes, 0);
    },
  );

  test(
    'cross-origin redirects strip credentials and never restore on return',
    () async {
      final a = await ProgressiveOrigin.start();
      final b = await ProgressiveOrigin.start();
      addTearDown(a.close);
      addTearDown(b.close);
      a.intercept = (wire) async => wire.target.contains('returned=1')
          ? null
          : (
              status: 302,
              headers: {
                'Location':
                    '${b.origin}/file%2fvideo.avi?sig=%7e&x=1&x=2&api_key=fixture-token&alias=fixture-token',
              },
              body: <int>[],
            );
      b.intercept = (_) async => (
        status: 302,
        headers: {
          'Location':
              '${a.origin}$_path?$_query&api_key=fixture-token&returned=1',
        },
        body: <int>[],
      );
      final request = _request(origin: a.origin);
      final input = SourceHttpInput(request, embyServer: request.embyServer);
      addTearDown(input.close);
      await input.prepare();
      expect(await input.read(400000, 4096), a.bytes.sublist(400000, 404096));
      expect(a.requests, hasLength(4));
      expect(b.requests, hasLength(2));
      for (final wire in a.requests.where(
        (wire) => !wire.target.contains('returned=1'),
      )) {
        expect(wire.headers['x-emby-token'], 'fixture-token');
        expect(wire.target, contains('api_key=fixture-token'));
      }
      for (final wire in [
        ...b.requests,
        ...a.requests.where((wire) => wire.target.contains('returned=1')),
      ]) {
        for (final name in _headers.keys) {
          expect(wire.headers.containsKey(name.toLowerCase()), isFalse);
        }
        expect(wire.target, isNot(contains('fixture-token')));
        expect(wire.target, isNot(contains('api_key')));
      }
      expect(b.requests.first.target, '/file%2fvideo.avi?sig=%7e&x=1&x=2');
      expect(request.allowsNativeFallback, isFalse);
      input.close();
      a.intercept = (_) async =>
          (status: 200, headers: const {}, body: <int>[]);
      final retry = SourceHttpInput(request, embyServer: request.embyServer);
      addTearDown(retry.close);
      await expectLater(retry.prepare(), throwsA(isA<SourceInputException>()));
      expect(request.allowsNativeFallback, isFalse);
    },
  );

  test(
    'rejected own-server and segmented redirect targets are never contacted',
    () async {
      final server = await ProgressiveOrigin.start();
      final cdn = await ProgressiveOrigin.start();
      addTearDown(server.close);
      addTearDown(cdn.close);
      for (final target in [
        '${server.origin}/emby/Users',
        '${server.origin}/emby/Videos/other/stream.avi',
        '${cdn.origin}/manifest.m3u8',
        'http://127.0.0.1/private',
      ]) {
        server.intercept = (_) async =>
            (status: 302, headers: {'Location': target}, body: <int>[]);
        final before = server.requests.length;
        final request = _request(origin: server.origin);
        // A mismatched adapter argument cannot widen the request's authority.
        final input = SourceHttpInput(
          request,
          embyServer: Uri.parse('https://unrelated.invalid'),
        );
        await expectLater(
          input.prepare(),
          throwsA(isA<SourceInputException>()),
        );
        expect(server.requests, hasLength(before + 1));
        expect(cdn.requests, isEmpty);
        expect(input.cachedBytes, 0);
        if (Uri.parse(target).origin != request.embyServer.origin) {
          expect(request.allowsNativeFallback, isFalse);
        }
        input.close();
      }
    },
  );

  test(
    'malformed authenticated range fails closed without retained bytes',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      server.intercept = (_) async => (
        status: 206,
        headers: {'Content-Range': 'bytes 1-100/1000'},
        body: List<int>.filled(100, 0),
      );
      final request = _request(origin: server.origin);
      final input = SourceHttpInput(request, embyServer: request.embyServer);
      addTearDown(input.close);
      await expectLater(
        input.prepare(),
        throwsA(
          isA<SourceInputException>().having(
            (error) => error.code,
            'code',
            'source_changed',
          ),
        ),
      );
      expect(server.requests.single.headers['x-emby-token'], 'fixture-token');
      expect(input.cachedBytes, 0);
      expect(input.reservedBytes, 0);
    },
  );

  test(
    'a suppressed background authentication rejection permanently vetoes fallback',
    () async {
      const block = 1024 * 1024;
      final server = await ProgressiveOrigin.start(
        content: _content(12 * block),
      );
      addTearDown(server.close);
      final request = _request(origin: server.origin);
      final input = SourceHttpInput(
        request,
        embyServer: request.embyServer,
        rangeBytes: block,
      );
      addTearDown(input.close);
      await input.prepare();
      server.intercept = (wire) async =>
          wire.headers['range']!.startsWith('bytes=${2 * block}-')
          ? (status: 403, headers: const {}, body: <int>[])
          : null;
      expect(
        await input.read(block, 65536),
        server.bytes.sublist(block, block + 65536),
      );
      await _until(() => input.prefetchFailures > 0);
      expect(request.allowsNativeFallback, isFalse);
      expect(input.failures, 0);
      input.close();
      server.intercept = (_) async =>
          (status: 200, headers: const {}, body: <int>[]);
      final retry = SourceHttpInput(request, embyServer: request.embyServer);
      addTearDown(retry.close);
      await expectLater(retry.prepare(), throwsA(isA<SourceInputException>()));
      expect(request.allowsNativeFallback, isFalse);
    },
  );

  for (final textDownload in [false, true]) {
    test(
      'redirect evidence precedes unsettled response cancellation (text=$textDownload)',
      () async {
        final cancellationStarted = Completer<void>();
        final releaseCancellation = Completer<void>();
        final body = StreamController<List<int>>(
          onCancel: () {
            cancellationStarted.complete();
            return releaseCancellation.future;
          },
        );
        final response = _GatedRedirectResponse(body.stream);
        var connections = 0;
        await HttpOverrides.runZoned(
          () async {
            final request = _request();
            final input = SourceHttpInput(
              request,
              embyServer: request.embyServer,
            );
            final failed = expectLater(
              textDownload
                  ? input.downloadText(headers: _headers)
                  : input.prepare(),
              throwsA(isA<SourceInputException>()),
            );
            await cancellationStarted.future;
            // Cancellation is still suspended here. Fallback must already know
            // about the external destination, before stop races the response.
            expect(request.allowsNativeFallback, isFalse);
            input.close();
            releaseCancellation.complete();
            await failed;
            expect(connections, 1);
            expect(request.allowsNativeFallback, isFalse);
          },
          createHttpClient: (_) => _GatedClient(response, () => connections++),
        );
        await body.close();
      },
    );
  }

  test(
    'cancellation releases authenticated demand/prefetch and stale sessions cannot reopen',
    () async {
      const block = 1024 * 1024;
      final server = await ProgressiveOrigin.start(
        content: _content(12 * block),
      );
      addTearDown(server.close);
      var active = true;
      final request = _request(origin: server.origin, active: () => active);
      final input = SourceHttpInput(
        request,
        embyServer: request.embyServer,
        rangeBytes: block,
      );
      addTearDown(input.close);
      await input.prepare();
      final gates = <Completer<FixtureReply?>>[];
      server.intercept = (_) {
        final gate = Completer<FixtureReply?>();
        gates.add(gate);
        return gate.future;
      };
      final reading = expectLater(
        input.read(block, 65536),
        throwsA(isA<SourceInputException>()),
      );
      await _until(() => gates.length == 8);
      expect(
        input.reservedBytes,
        lessThanOrEqualTo(SourceHttpInput.cacheBudget),
      );
      active = false;
      input.close();
      await reading;
      for (final gate in gates) {
        gate.complete(null);
      }
      await _until(() => input.reservedBytes == 0);
      expect(input.cachedBytes, 0);
      final before = server.requests.length;
      await expectLater(
        input.read(0, 16),
        throwsA(isA<SourceInputException>()),
      );
      final stale = SourceHttpInput(request, embyServer: request.embyServer);
      await expectLater(stale.prepare(), throwsA(isA<SourceInputException>()));
      expect(server.requests, hasLength(before));
    },
  );
}

/// Only the response-cancellation race needs a gated client. The other HTTP
/// tests above exercise real sockets and the production DNS/Range transport.
class _GatedClient implements HttpClient {
  _GatedClient(this.response, this.onRequest);
  final HttpClientResponse response;
  final void Function() onRequest;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    onRequest();
    return _GatedRequest(response);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _GatedRequest implements HttpClientRequest {
  _GatedRequest(this.response);
  final HttpClientResponse response;
  @override
  final HttpHeaders headers = _TestHeaders();
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _GatedRedirectResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _GatedRedirectResponse(this.body);
  final Stream<List<int>> body;
  @override
  final HttpHeaders headers = _TestHeaders()
    ..set(HttpHeaders.locationHeader, 'https://cdn.invalid/video.avi');
  @override
  int get statusCode => 302;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestHeaders implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  void forEach(void Function(String, List<String>) action) {
    values.forEach((name, value) => action(name, [value]));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
