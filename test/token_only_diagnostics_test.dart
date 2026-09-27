import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/core/token_redactor.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'strm_diagnostics_test.dart' as fixtures;
import 'support/progressive_fixture.dart';

void main() {
  test('token aliases preserve every other byte, including nested encodings', () {
    const secret = 'secret-A9/value+你好';
    for (final alias in [
      'token',
      'ToKeN',
      'access_token',
      'AccessToken',
      'X-Emby-Token',
      'api_key',
    ]) {
      final raw =
          'https://主机.example:8920/中文/%e4%b8%ad/%2f?sign=keep&$alias=$secret&x=%2B&x=2&session=keep';
      for (var depth = 0; depth <= 4; depth++) {
        var input = raw;
        var credential = secret;
        for (var i = 0; i < depth; i++) {
          input = Uri.encodeComponent(input);
          credential = Uri.encodeComponent(credential);
        }
        final expected = input.replaceFirst(credential, TokenRedactor.marker);
        expect(
          DiagnosticLog.redact(input),
          expected,
          reason: '$alias depth=$depth',
        );
        expect(FullDiagnosticRedactor.redact(input), expected);
        expect(
          FullDiagnosticRedactor.containsSensitiveContent(expected),
          false,
        );
        expect(FullDiagnosticRedactor.containsSensitiveContent(input), true);
      }
    }
    const duplicates =
        'https://host/a?token=one&TOKEN=two&key=keep&sign=keep&session=keep&x=1&x=2';
    expect(
      DiagnosticLog.redact(duplicates),
      duplicates
          .replaceAll('=one', '=<redacted-token>')
          .replaceAll('=two', '=<redacted-token>'),
    );
    const encodedValue = 'https://host/a?token=a%26b%3dc&file=%e4%b8%ad%2f';
    expect(
      DiagnosticLog.redact(encodedValue),
      'https://host/a?token=<redacted-token>&file=%e4%b8%ad%2f',
    );
  });

  test('header, JSON, Cookie and error copies hide only token values', () {
    const secret = 'credential-A9-secret';
    TokenRedactor.register(secret);
    final inputs = [
      'Authorization: Bearer $secret',
      'X-Emby-Authorization: MediaBrowser Client="App", Device="中文", Token="$secret", Version="1.0"',
      'Cookie: token=$secret; theme=dark; session=keep',
      'Cookie: opaque=$secret; theme=dark',
      jsonEncode({'AccessToken': secret, 'Path': '/中文/a%2fb', 'key': 'keep'}),
      jsonEncode({
        'nested': jsonEncode({'access_token': secret, 'name': '中文'}),
      }),
      'SocketException: $secret peer=[2001:db8::1]:8096 file=C:\\中文\\video.mp4',
      r'\u0074oken\u003dcredential-A9-secret&sign=keep',
      '%74%6f%6b%65%6e%3dcredential-A9-secret&sign=keep',
    ];
    for (final input in inputs) {
      final expected = input.replaceAll(secret, TokenRedactor.marker);
      expect(DiagnosticLog.redact(input), expected);
      expect(DiagnosticLog.redact(expected), expected);
    }
    const headers =
        '{"X-Emby-Token":["header-one","header-two"],"Set-Cookie":["token=cookie-secret; path=/中文"]}';
    final expectedHeaders = headers
        .replaceAll('header-one', TokenRedactor.marker)
        .replaceAll('header-two', TokenRedactor.marker)
        .replaceAll('cookie-secret', TokenRedactor.marker);
    expect(DiagnosticLog.redact(headers), expectedHeaders);
    expect(
      FullDiagnosticRedactor.containsSensitiveContent(expectedHeaders),
      false,
    );
    TokenRedactor.registerCredentials('https://host/a?token=a%26b%3dc');
    expect(
      DiagnosticLog.redact('error a&b=c path=/a; value=b'),
      'error <redacted-token> path=/a; value=b',
    );
    const retained =
        'password=pw username=姓名 api-sign=x key=y session=z Cookie: theme=dark Authorization: Basic dXNlcjpwYXNz';
    expect(DiagnosticLog.redact(retained), retained);
  });

  test(
    'real refused connection preserves target DNS attempt and error through file and export',
    () async {
      final origin = await ProgressiveOrigin.start();
      final address = origin.host;
      final port = origin.server.port;
      await origin.close();
      final fixture = await fixtures.fileLog();
      final console = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) console.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);
      final trace = StrmTrace(log: fixture.log);
      final url =
          'http://$address:$port/中文/%e4%b8%ad/file.avi?token=failed-wire-token&sign=keep&x=1&x=2';
      final plan = await fixtures.resolve(trace, url);
      final request = plan.sourceRequest!;
      final headersBefore = Map<String, String>.from(request.headers);
      final input = SourceHttpInput(
        request,
        embyServer: request.embyServer,
        openAttempt: trace.nextOpen(),
      );
      await expectLater(
        input.prepare(),
        throwsA(
          isA<SourceInputException>().having(
            (e) => e.reason,
            'connection classification',
            'connect_failed',
          ),
        ),
      );
      input.close();
      trace.finish();
      fixture.log.error('test', 'console token=failed-wire-token source=$url');
      final report = await fixtures.report(
        fixture.log,
        'token-only-connect-failure',
      );
      final disk = await File(
        '${fixture.directory.path}/log.txt',
      ).readAsString();
      final local = await fixture.log.read();
      expect(local, disk);
      expect(report.content.split('\n').skip(8).join('\n'), local);
      for (final text in [disk, local, report.content]) {
        expect(
          text,
          contains(url.replaceAll('failed-wire-token', TokenRedactor.marker)),
        );
        expect(text, contains('"sourceUrl"'));
        expect(text, contains('"requestUrl"'));
        expect(text, contains('"host":"$address"'));
        expect(text, contains('"addresses":["$address"]'));
        expect(text, contains('stage=connect_attempt'));
        expect(text, contains('"ip":"$address","port":$port'));
        expect(text, contains('SocketException'));
        expect(text, contains('"osErrorCode":'));
        expect(text, contains('"stack":'));
        expect(text, contains('elapsedMs='));
        expect(text, isNot(contains('failed-wire-token')));
        expect(text, isNot(contains('private-credential')));
        expect(
          text.indexOf('stage=connect_attempt'),
          lessThan(text.indexOf('reason=connect_failed')),
        );
      }
      expect(console.join(), contains('<redacted-token>'));
      expect(console.join(), isNot(contains('failed-wire-token')));
      expect(request.rawUrl, url);
      expect(request.headers, headersBefore);
    },
  );

  test(
    'redirect evidence and actual wire request preserve original token and encoding',
    () async {
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      const first = '/first?api_key=wire-original-secret&x=%2f&x=2&opaque=%FF';
      const last = '/last?access_token=wire-next-secret&sign=a%2Fb&x=1&x=2';
      origin.intercept = (request) async => request.target == first
          ? (
              status: 302,
              headers: {
                'Location': '${origin.origin}$last',
                'Set-Cookie': 'token=wire-cookie-secret; theme=keep',
              },
              body: <int>[],
            )
          : null;
      final fixture = await fixtures.fileLog();
      final trace = StrmTrace(log: fixture.log);
      final plan = await fixtures.resolve(trace, '${origin.origin}$first');
      final input = SourceHttpInput(
        plan.sourceRequest!,
        embyServer: plan.sourceRequest!.embyServer,
      );
      await input.prepare();
      input.close();
      trace.finish();
      expect(origin.requests.map((r) => r.target), [first, last]);
      expect(
        origin.requests.first.headers['authorization'],
        'private-credential',
      );
      final report = await fixtures.report(fixture.log, 'token-only-redirect');
      expect(
        report.content,
        contains(
          '"location":"${origin.origin}/last?access_token=<redacted-token>&sign=a%2Fb&x=1&x=2"',
        ),
      );
      expect(report.content, contains('"fromUrl"'));
      expect(report.content, contains('"toUrl"'));
      expect(report.content, contains('"http":302'));
      expect(report.content, contains('theme=keep'));
      for (final token in [
        'wire-original-secret',
        'wire-next-secret',
        'wire-cookie-secret',
        'private-credential',
      ]) {
        expect(report.content, isNot(contains(token)));
      }
    },
  );
}
