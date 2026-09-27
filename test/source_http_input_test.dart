import 'dart:async';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/progressive_fixture.dart';

PlaybackResourceRequest fixtureRequest(
  String raw, {
  Map<String, String> headers = const {},
}) => PlaybackResourceRequest(
  rawUrl: raw,
  headers: headers,
  embyServer: Uri.parse('https://emby.invalid'),
  identity: PlaybackResourceIdentity(
    scope: const ServerScope(serverId: 's', userId: 'u'),
    apiSession: Object(),
    itemId: 'item',
    sourceId: 'source',
    itemSession: Object(),
    generation: 1,
  ),
);

void main() {
  test(
    'wire preserves opaque signature; Range seek reads exact bytes',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      const target = '/a%2fb.avi?sig=%7e&x=1&x=2&api_key=source&q=a+b&q=a%20b';
      final input = SourceHttpInput(
        fixtureRequest('${server.origin}$target'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(input.close);
      await input.prepare();
      expect(input.format, 'avi');
      expect(server.requests.single.target, target);
      expect(
        await input.read(400000, 5000),
        server.bytes.sublist(400000, 405000),
      );
      expect(server.requests.last.headers['range'], 'bytes=400000-404999');
      expect(await input.read(200, 1000), server.bytes.sublist(200, 1200));
    },
  );

  test(
    'OpenList style redirect chain strips every resource header cross-origin on every Range',
    () async {
      final a = await ProgressiveOrigin.start();
      final b = await ProgressiveOrigin.start();
      addTearDown(a.close);
      addTearDown(b.close);
      a.intercept = (_) async => (
        status: 302,
        headers: {'Location': '${b.origin}/file%2fvideo?sign=%7e'},
        body: <int>[],
      );
      final input = SourceHttpInput(
        fixtureRequest(
          '${a.origin}/d/video',
          headers: {
            'Authorization': 'fixture',
            'Cookie': 'fixture',
            'X-Private': 'fixture',
            'Referer': 'fixture',
          },
        ),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(input.close);
      await input.prepare();
      await input.read(400000, 4096);
      expect(a.requests.length, 2);
      expect(b.requests.length, 2);
      for (final request in b.requests) {
        expect(request.target, '/file%2fvideo?sign=%7e');
        for (final key in [
          'authorization',
          'cookie',
          'x-private',
          'referer',
          'x-emby-token',
        ]) {
          expect(request.headers.containsKey(key), isFalse);
        }
      }
    },
  );

  test(
    'sixth redirect never sent, local destination rejected, cancellation closes read',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      var hops = 0;
      server.intercept = (_) async =>
          (status: 302, headers: {'Location': '/hop/${++hops}'}, body: <int>[]);
      final first = SourceHttpInput(
        fixtureRequest('${server.origin}/hop/0'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(first.close);
      await expectLater(first.prepare(), throwsA(isA<SourceInputException>()));
      expect(server.requests.length, 6);
      server.intercept = (_) async => (
        status: 302,
        headers: {'Location': 'http://127.0.0.1/private'},
        body: <int>[],
      );
      final second = SourceHttpInput(
        fixtureRequest('${server.origin}/redirect'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(second.close);
      await expectLater(second.prepare(), throwsA(isA<SourceInputException>()));
      final gate = Completer<FixtureReply?>();
      server.intercept = (_) => gate.future;
      final third = SourceHttpInput(
        fixtureRequest('${server.origin}/blocked'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      final pending = third.prepare();
      final expectation = expectLater(
        pending,
        throwsA(isA<SourceInputException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      third.close();
      await expectation;
      gate.complete(null);
    },
  );
}
