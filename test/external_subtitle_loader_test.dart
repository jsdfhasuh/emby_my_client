import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/external_subtitle_loader.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/progressive_fixture.dart';

const _srt = '1\n00:00:00,000 --> 00:00:24,000\nFixture\n';
EmbyApi subtitleApi(String origin) => EmbyApi(
  EmbySession(
    serverUrl: origin,
    serverName: 'fixture',
    serverId: 'server',
    userId: 'user',
    username: 'fixture',
    accessToken: 'emby-fixture',
    deviceId: 'device',
  ),
);

void main() {
  test(
    'Emby subtitle uses headers, strips own token query, and drops auth on same-origin non-subtitle redirect',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      final api = subtitleApi(server.origin);
      addTearDown(api.dispose);
      final loader = ExternalSubtitleLoader(api);
      addTearDown(loader.dispose);
      server.intercept = (r) async => r.target.startsWith('/Videos/')
          ? (
              status: 302,
              headers: {'Location': '/public/sub.srt?api_key=upstream'},
              body: <int>[],
            )
          : (status: 200, headers: <String, String>{}, body: utf8.encode(_srt));
      final lease = await loader.load(
        '/Videos/item/source/Subtitles/2/Stream.srt?api_key=emby-fixture&sig=%7e',
        itemId: 'item',
        sourceId: 'source',
      );
      expect(
        server.requests.first.target,
        '/Videos/item/source/Subtitles/2/Stream.srt?sig=%7e',
      );
      expect(server.requests.first.headers['x-emby-token'], 'emby-fixture');
      expect(server.requests.last.headers.containsKey('x-emby-token'), false);
      expect(server.requests.last.headers.containsKey('authorization'), false);
      expect(server.requests.last.target, '/public/sub.srt?api_key=upstream');
      expect(await lease.file.readAsString(), _srt);
      lease.attached = true;
      await loader.dispose();
      expect(await lease.file.exists(), true);
      await lease.release();
      expect(await lease.file.exists(), false);
    },
  );

  test(
    'third-party raw URL and query are preserved with no Emby credentials',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      final api = subtitleApi('https://emby.invalid');
      addTearDown(api.dispose);
      final loader = ExternalSubtitleLoader(api);
      addTearDown(loader.dispose);
      server.intercept = (_) async =>
          (status: 200, headers: <String, String>{}, body: utf8.encode(_srt));
      final lease = await loader.load(
        '${server.origin}/s%2fsub?api_key=own&sig=%7e&x=1&x=2',
        itemId: 'item',
        sourceId: 'source',
      );
      expect(
        server.requests.single.target,
        '/s%2fsub?api_key=own&sig=%7e&x=1&x=2',
      );
      expect(
        server.requests.single.headers.keys,
        isNot(contains('x-emby-token')),
      );
      expect(
        server.requests.single.headers.keys,
        isNot(contains('authorization')),
      );
      await lease.release();
    },
  );

  test('rejects HTML and gzip exceeding decoded 10 MiB', () async {
    final server = await ProgressiveOrigin.start();
    addTearDown(server.close);
    final api = subtitleApi('https://emby.invalid');
    addTearDown(api.dispose);
    final loader = ExternalSubtitleLoader(api);
    addTearDown(loader.dispose);
    server.intercept = (_) async => (
      status: 200,
      headers: <String, String>{},
      body: utf8.encode('<html>sign in</html>'),
    );
    Future<SubtitleFileLease> load() => loader.load(
      '${server.origin}/subtitle',
      itemId: 'item',
      sourceId: 'source',
    );
    await expectLater(load(), throwsA(isA<SourceInputException>()));
    final compressed = gzip.encode(List<int>.filled(10 * 1024 * 1024 + 1, 65));
    server.intercept = (_) async =>
        (status: 200, headers: {'Content-Encoding': 'gzip'}, body: compressed);
    await expectLater(load(), throwsA(isA<SourceInputException>()));
  });

  test(
    '32 MiB budget never deletes attached files to admit another download',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      final api = subtitleApi('https://emby.invalid');
      addTearDown(api.dispose);
      final loader = ExternalSubtitleLoader(api);
      addTearDown(loader.dispose);
      final body = utf8.encode(_srt + ('a' * (8 * 1024 * 1024)));
      server.intercept = (_) async =>
          (status: 200, headers: <String, String>{}, body: body);
      Future<SubtitleFileLease> load() => loader.load(
        '${server.origin}/subtitle',
        itemId: 'item',
        sourceId: 'source',
      );
      final leases = <SubtitleFileLease>[];
      addTearDown(() async {
        for (final lease in leases) {
          await lease.release();
        }
      });
      for (var i = 0; i < 3; i++) {
        leases.add((await load())..attached = true);
      }
      await expectLater(load(), throwsA(isA<SourceInputException>()));
      expect(server.requests, hasLength(3));
      for (final lease in leases) {
        expect(await lease.file.exists(), true);
      }
    },
  );

  test(
    'cancel stops an in-flight download without publishing a lease',
    () async {
      final server = await ProgressiveOrigin.start();
      addTearDown(server.close);
      final api = subtitleApi('https://emby.invalid');
      addTearDown(api.dispose);
      final loader = ExternalSubtitleLoader(api);
      addTearDown(loader.dispose);
      final gate = Completer<FixtureReply?>();
      server.intercept = (_) => gate.future;
      final operation = loader.load(
        '${server.origin}/subtitle',
        itemId: 'item',
        sourceId: 'source',
      );
      final expectation = expectLater(
        operation,
        throwsA(isA<SourceInputException>()),
      );
      while (server.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      loader.cancel();
      await expectation;
      gate.complete((
        status: 200,
        headers: <String, String>{},
        body: utf8.encode(_srt),
      ));
    },
  );
}
