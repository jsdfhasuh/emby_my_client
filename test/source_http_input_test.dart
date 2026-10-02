import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/progressive_fixture.dart';

PlaybackResourceRequest fixtureRequest(
  String raw, {
  Map<String, String> headers = const {},
  StrmTrace? trace,
}) => PlaybackResourceRequest(
  rawUrl: raw,
  trace: trace,
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
    'tail index uses 1 MiB fetches for 64 KiB reads and caches seeks',
    () async {
      const mib = 1024 * 1024;
      final content = Uint8List(20 * mib + 137);
      for (var i = 0; i < content.length; i++) {
        content[i] = i % 251;
      }
      content.setRange(0, 12, progressiveVideo().take(12));
      final server = await ProgressiveOrigin.start(content: content);
      addTearDown(server.close);
      final input = SourceHttpInput(
        fixtureRequest('${server.origin}/large.avi'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(input.close);
      await input.prepare();
      for (var offset = 4 * mib; offset < 20 * mib; offset += 65536) {
        expect(
          await input.read(offset, 65536),
          content.sublist(offset, offset + 65536),
        );
      }
      expect(
        server.requests,
        hasLength(17),
      ); // Prefix + 16 MiB, not 256 requests.
      expect(input.readAheadHits, 240);
      expect(
        await input.read(4 * mib + 12, 16),
        content.sublist(4 * mib + 12, 4 * mib + 28),
      );
      expect(await input.read(0, 16), content.sublist(0, 16));
      expect(server.requests, hasLength(17));
      expect(await input.read(20 * mib, 65536), content.sublist(20 * mib));
      expect(
        server.requests.last.headers['range'],
        'bytes=${20 * mib}-${content.length - 1}',
      );
      expect(input.cachedBytes, lessThanOrEqualTo(SourceHttpInput.cacheBudget));
    },
  );

  test(
    'cache evicts old ranges within budget while retaining the prefix',
    () async {
      const mib = 1024 * 1024;
      final content = Uint8List(40 * mib)
        ..setRange(0, 12, progressiveVideo().take(12));
      final server = await ProgressiveOrigin.start(content: content);
      addTearDown(server.close);
      final input = SourceHttpInput(
        fixtureRequest('${server.origin}/large.avi'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(input.close);
      await input.prepare();
      for (var offset = mib; offset <= 35 * mib; offset += mib) {
        await input.read(offset, 16);
        expect(
          input.cachedBytes,
          lessThanOrEqualTo(SourceHttpInput.cacheBudget),
        );
      }
      final count = server.requests.length;
      await input.read(0, 16);
      await input.read(35 * mib, 16);
      expect(server.requests, hasLength(count));
      await input.read(mib, 16);
      expect(server.requests, hasLength(count + 1));
      input.close();
      expect(input.cachedBytes, 0);
      await expectLater(
        input.read(0, 16),
        throwsA(isA<SourceInputException>()),
      );
    },
  );

  test(
    'overlapping concurrent reads share one fetch; close cancels queued reads',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      final input = SourceHttpInput(
        fixtureRequest('${server.origin}/video.avi'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(input.close);
      await input.prepare();
      final values = await Future.wait([
        input.read(300000, 1000),
        input.read(301000, 1000),
      ]);
      expect(values[0], server.bytes.sublist(300000, 301000));
      expect(values[1], server.bytes.sublist(301000, 302000));
      expect(server.requests, hasLength(2));
      final arrived = Completer<void>();
      final gate = Completer<FixtureReply?>();
      server.intercept = (_) {
        arrived.complete();
        return gate.future;
      };
      final pending = expectLater(
        input.read(270000, 1000),
        throwsA(isA<SourceInputException>()),
      );
      final queued = expectLater(
        input.read(280000, 1000),
        throwsA(isA<SourceInputException>()),
      );
      await arrived.future;
      input.close();
      await Future.wait([pending, queued]);
      gate.complete(null);
      expect(server.requests, hasLength(3));
      expect(input.cachedBytes, 0);
    },
  );

  test(
    'prefetch rejects a changed source and does not cache its bytes',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      final input = SourceHttpInput(
        fixtureRequest('${server.origin}/video.avi'),
        embyServer: Uri.parse('https://emby.invalid'),
      );
      addTearDown(input.close);
      await input.prepare();
      server.intercept = (_) async => (
        status: 206,
        headers: {
          'Content-Range': 'bytes 300000-300099/${server.bytes.length}',
          'ETag': '"changed"',
        },
        body: server.bytes.sublist(300000, 300100),
      );
      await expectLater(
        input.read(300000, 100),
        throwsA(
          isA<SourceInputException>().having(
            (e) => e.code,
            'code',
            'source_changed',
          ),
        ),
      );
      expect(input.cachedBytes, 262144);
    },
  );

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
      expect(
        server.requests.last.headers['range'],
        'bytes=400000-${server.bytes.length - 1}',
      );
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
