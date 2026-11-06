import 'dart:async';
import 'dart:convert';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_http_input_test.dart' show fixtureRequest;
import 'support/progressive_fixture.dart';

Future<Map<String, dynamic>> failedBody({
  required String contentType,
  required List<int> body,
  Map<String, String> headers = const {},
}) async {
  final lines = <String>[];
  final log = DiagnosticLog.forTesting()..setTestSink(lines.add);
  final trace = StrmTrace(log: log);
  final origin = await ProgressiveOrigin.start();
  addTearDown(origin.close);
  origin.intercept = (_) async => (
    status: 500,
    headers: {'Content-Type': contentType, ...headers},
    body: body,
  );
  final request = fixtureRequest('${origin.origin}/video.avi', trace: trace);
  final input = SourceHttpInput(request, embyServer: request.embyServer);
  addTearDown(input.close);
  await expectLater(
    input.prepare(),
    throwsA(
      isA<SourceInputException>()
          .having((error) => error.reason, 'reason', 'source_server_error')
          .having((error) => error.safeHttp, 'status', 500),
    ),
  );
  expect(input.networkBytes, 0);
  expect(input.ranges, 0);
  expect(origin.requests, hasLength(1));
  final record = lines.singleWhere(
    (line) => line.contains('stage=response_body'),
  );
  return jsonDecode(record.substring(record.indexOf('details=') + 8))
      as Map<String, dynamic>;
}

void main() {
  test(
    'outer transfer deadline preserves HTTP 500 observed before body sampling',
    () async {
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      final release = Completer<FixtureReply?>();
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete((
            status: 500,
            headers: <String, String>{},
            body: <int>[],
          ));
        }
      });
      var headersSent = false;
      origin.intercept = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 24300));
        final socket = origin.sockets.last;
        socket.add(
          latin1.encode(
            'HTTP/1.1 500 Fixture\r\n'
            'Content-Type: text/plain\r\n'
            'Content-Length: 512\r\n'
            'Connection: close\r\n\r\n'
            'password="deadline-private-password',
          ),
        );
        await socket.flush();
        headersSent = true;
        return release.future;
      };
      final request = fixtureRequest('${origin.origin}/video.avi');
      final input = SourceHttpInput(request, embyServer: request.embyServer);
      addTearDown(input.close);
      final watch = Stopwatch()..start();
      await expectLater(
        input.prepare(),
        throwsA(
          isA<SourceInputException>()
              .having((error) => error.reason, 'reason', 'source_server_error')
              .having((error) => error.safeHttp, 'status', 500)
              .having((error) => error.safeStage, 'stage', 'range_response'),
        ),
      ).timeout(const Duration(seconds: 32));
      expect(headersSent, isTrue);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(24800));
      expect(watch.elapsedMilliseconds, lessThan(28000));
      expect(input.networkBytes, 0);
      expect(input.ranges, 0);
      expect(origin.requests, hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  for (final cancel in [false, true]) {
    test(
      cancel
          ? 'closing a stalled error body preserves the original HTTP failure'
          : 'stalled error body times out without replacing HTTP 500',
      () async {
        final lines = <String>[];
        final log = DiagnosticLog.forTesting()..setTestSink(lines.add);
        final trace = StrmTrace(log: log);
        final origin = await ProgressiveOrigin.start();
        addTearDown(origin.close);
        final sent = Completer<void>();
        final release = Completer<FixtureReply?>();
        addTearDown(() {
          if (!release.isCompleted) {
            release.complete((
              status: 500,
              headers: <String, String>{},
              body: <int>[],
            ));
          }
        });
        origin.intercept = (_) async {
          final socket = origin.sockets.last;
          socket.add(
            latin1.encode(
              'HTTP/1.1 500 Fixture\r\n'
              'Content-Type: text/plain\r\n'
              'Content-Length: 512\r\n'
              'Connection: close\r\n\r\n'
              'password="incomplete-private-password',
            ),
          );
          await socket.flush();
          sent.complete();
          return release.future;
        };
        final request = fixtureRequest(
          '${origin.origin}/video.avi',
          trace: trace,
        );
        final input = SourceHttpInput(request, embyServer: request.embyServer);
        addTearDown(input.close);
        final watch = Stopwatch()..start();
        final pending = expectLater(
          input.prepare(),
          throwsA(
            isA<SourceInputException>()
                .having(
                  (error) => error.reason,
                  'reason',
                  'source_server_error',
                )
                .having((error) => error.safeHttp, 'status', 500),
          ),
        );
        await sent.future;
        if (cancel) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          input.close();
        }
        await pending.timeout(const Duration(seconds: 4));
        expect(watch.elapsedMilliseconds, lessThan(3500));
        expect(input.networkBytes, 0);
        expect(origin.requests, hasLength(1));
        final line = lines.singleWhere(
          (line) => line.contains('stage=response_body'),
        );
        final record =
            jsonDecode(line.substring(line.indexOf('details=') + 8))
                as Map<String, dynamic>;
        expect(record['bodyReadOutcome'], cancel ? 'failed' : 'timeout');
        expect(record['bodyTruncated'], isTrue);
        expect(record['responseBody'], isNull);
        expect(lines.join(), isNot(contains('incomplete-private-password')));
      },
    );
  }

  test(
    'JSON error body retains evidence but masks credential values',
    () async {
      final record = await failedBody(
        contentType: 'application/problem+json; charset=utf-8',
        body: utf8.encode(
          jsonEncode({
            'error': 'upstream read failed',
            'password': 'body-private-password',
            'secret': 'body-private-secret',
            'cookie': 'session=body-private-cookie',
            'authorization': 'Bearer body-private-authorization',
            'upstream':
                'https://source.invalid/video?sig=body-private-signature',
          }),
        ),
      );
      expect(record['http'], 500);
      expect(record['bodyReadOutcome'], 'complete');
      expect(record['bodyTruncated'], isFalse);
      final captured = record['responseBody'] as String;
      expect(captured, contains('upstream read failed'));
      for (final secret in [
        'body-private-password',
        'body-private-secret',
        'body-private-cookie',
        'body-private-authorization',
        'body-private-signature',
      ]) {
        expect(captured, isNot(contains(secret)));
      }
    },
  );

  test(
    'large error body omits an incomplete credential-bearing prefix',
    () async {
      final record = await failedBody(
        contentType: 'application/json',
        body: utf8.encode(
          '{"error":"upstream failed",\n"password":"'
          '${List.filled(600, 'private-secret').join()}"}',
        ),
      );
      expect(record['bodyBytes'], lessThanOrEqualTo(4096));
      expect(record['bodyTruncated'], isTrue);
      expect(record['bodyReadOutcome'], 'limit');
      expect(record['responseBody'], isNull);
      expect(jsonEncode(record), isNot(contains('private-secret')));
    },
  );

  test('complete malformed JSON cannot expose an unclosed password', () async {
    final record = await failedBody(
      contentType: 'application/json',
      body: utf8.encode(
        '{"error":"upstream failed","password":"malformed-private-password',
      ),
    );
    expect(record['bodyReadOutcome'], 'complete');
    expect(jsonEncode(record), isNot(contains('malformed-private-password')));
  });

  for (final contentType in ['application/octet-stream', 'video/mp4']) {
    test('binary $contentType error body is not captured', () async {
      final record = await failedBody(
        contentType: contentType,
        body: utf8.encode('binary-private-payload'),
      );
      expect(record['bodyReadOutcome'], 'skipped');
      expect(record['responseBody'], isNull);
      expect(jsonEncode(record), isNot(contains('binary-private-payload')));
    });
  }

  test('encoded error body is not decoded or captured', () async {
    final record = await failedBody(
      contentType: 'text/html',
      headers: {'Content-Encoding': 'gzip'},
      body: utf8.encode('encoded-private-payload'),
    );
    expect(record['bodyReadOutcome'], 'skipped');
    expect(record['responseBody'], isNull);
    expect(jsonEncode(record), isNot(contains('encoded-private-payload')));
  });
}
