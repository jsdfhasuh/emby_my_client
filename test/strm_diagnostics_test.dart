import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/progressive_fixture.dart';

Future<({DiagnosticLog log, Directory directory})> fileLog() async {
  final directory = await Directory.systemTemp.createTemp('strm-log-test-');
  final log = DiagnosticLog.forTesting();
  await log.initializeFileForTesting(File('${directory.path}/log.txt'));
  addTearDown(() async {
    await log.read();
    await directory.delete(recursive: true);
  });
  return (log: log, directory: directory);
}

Future<FullDiagnosticReport> report(DiagnosticLog log, String name) async {
  final report = await FullDiagnosticExportService(
    readLog: log.read,
    appVersion: '1.0.0',
    buildNumber: '156',
  ).buildReport();
  FullDiagnosticExportService.validateSnapshot(report.content);
  final output = Platform.environment['STRM_DIAGNOSTIC_EVIDENCE'];
  if (output != null) {
    await Directory(output).create(recursive: true);
    await File('$output/$name.txt').writeAsString(report.content);
  }
  return report;
}

Future<PlaybackPlan> resolve(StrmTrace trace, String url) async {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) => h.resolve(
          Response(
            requestOptions: o,
            statusCode: 200,
            data: {
              'MediaSources': [
                {
                  'Id': 'private-source',
                  'Protocol': 'Http',
                  'Path': url,
                  'Container': 'avi',
                  'RequiredHttpHeaders': {
                    'Authorization': 'private-credential',
                  },
                },
              ],
            },
          ),
        ),
      ),
    );
  final api = EmbyApi(
    const EmbySession(
      serverUrl: 'https://private-emby.invalid',
      serverName: 'private-name',
      serverId: 'private-server',
      userId: 'private-user',
      username: 'private-user',
      accessToken: 'private-credential',
      deviceId: 'private-device',
    ),
    dio: dio,
  );
  addTearDown(api.dispose);
  return EmbyStreamResolver(api, trace: trace).resolve(
    EmbyItem.fromJson({
      'Id': 'private-item',
      'MediaSources': [
        {'Id': 'private-source', 'Container': 'strm'},
      ],
    }),
  );
}

void main() {
  test('queued reporting retains the attempt captured at invocation', () async {
    final fixture = await fileLog();
    final trace = StrmTrace(log: fixture.log);
    final plan = await resolve(trace, 'https://source.invalid/video');
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            requests.add(o.path);
            h.resolve(Response(requestOptions: o, statusCode: 204));
          },
        ),
      );
    final api = EmbyApi(
      const EmbySession(
        serverUrl: 'https://private-emby.invalid',
        serverName: 'fixture',
        serverId: 'private-server',
        userId: 'private-user',
        username: 'private-user',
        accessToken: 'private-credential',
        deviceId: 'private-device',
      ),
      dio: dio,
    );
    addTearDown(api.dispose);
    final reporter = PlaybackSessionReporter(
      api: api,
      item: EmbyItem.fromJson({'Id': 'private-item'}),
      trace: trace,
    );
    reporter.activate(plan);
    trace.nextOpen();
    final start = reporter.reportStart(Duration.zero, isPaused: true);
    trace.nextOpen();
    await start;
    final stopped = reporter.stop(Duration.zero);
    trace.nextOpen();
    await stopped;
    expect(requests, ['/Sessions/Playing', '/Sessions/Playing/Stopped']);
    final exported = await report(fixture.log, 'queued-reporting');
    final lines = exported.content.split('\n');
    final starts = lines.where((l) => l.contains('operation=start'));
    final stops = lines.where((l) => l.contains('operation=stopped'));
    expect(starts, hasLength(2));
    expect(stops, hasLength(2));
    expect(starts.every((l) => l.contains('openAttempt=1')), true);
    expect(stops.every((l) => l.contains('openAttempt=2')), true);
  });

  test('Dart and native full export use exactly the same closed schema', () {
    final swift = File(
      'ios/Runner/SafeDiagnosticExportSupport.swift',
    ).readAsStringSync();
    final encoded = RegExp(
      r'static let schemaJSON = #"(.*)"#',
    ).firstMatch(swift)![1]!;
    final schema = jsonDecode(encoded) as Map<String, dynamic>;
    expect(schema['common'], StrmDiagnosticSchema.common.toList());
    expect(schema['numbers'], StrmDiagnosticSchema.numbers.toList());
    expect(schema['booleans'], StrmDiagnosticSchema.booleans.toList());
    expect(
      schema['events'],
      StrmDiagnosticSchema.events.map((k, v) => MapEntry(k, v.toList())),
    );
    expect(
      schema['enums'],
      StrmDiagnosticSchema.enums.map((k, v) => MapEntry(k, v.toList())),
    );
  });

  test(
    'resolver and real input persist one trace without per-read logging',
    () async {
      final fixture = await fileLog();
      final trace = StrmTrace(log: fixture.log);
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      final plan = await resolve(
        trace,
        '${origin.origin}/private-path?api_key=private-secret',
      );
      final input = SourceHttpInput(
        plan.sourceRequest!,
        embyServer: plan.sourceRequest!.embyServer,
        openAttempt: trace.nextOpen(),
      );
      await input.prepare();
      for (var i = 0; i < 2000; i++) {
        input.recordNativeRead();
        input.recordDelivery((await input.read(0, 16)).length);
      }
      input.recordNativeRead();
      input.recordDelivery((await input.read(400000, 1000)).length);
      input.close();
      input.close();
      trace.finish();
      trace.finish();
      final result = await report(fixture.log, 'success');
      expect(
        result.content,
        contains('route=source_direct inputMode=stream_cb'),
      );
      expect(result.content, contains('nativeReads=2001 httpRequests=2'));
      expect(
        result.content,
        contains('networkBytes=263144 deliveredBytes=33000 prefixHits=2000'),
      );
      expect(result.content.split('scope=input').length - 1, 1);
      expect(result.content.split('scope=playback').length - 1, 1);
      expect(result.lineCount, lessThan(25));
      expect(
        RegExp(
          r'trace=([0-9a-f]{16})',
        ).allMatches(result.content).map((m) => m[1]).toSet(),
        {trace.id},
      );
      expect(result.content, isNot(contains('private-')));
    },
  );

  for (final status in [401, 403, 200, 206]) {
    test(
      'real HTTP $status survives input failure to file and export safely',
      () async {
        final fixture = await fileLog();
        final trace = StrmTrace(log: fixture.log);
        final origin = await ProgressiveOrigin.start();
        addTearDown(origin.close);
        origin.intercept = (_) async =>
            (status: status, headers: <String, String>{}, body: <int>[]);
        final plan = await resolve(
          trace,
          '${origin.origin}/private-file?sig=private-secret',
        );
        final input = SourceHttpInput(
          plan.sourceRequest!,
          embyServer: plan.sourceRequest!.embyServer,
          openAttempt: trace.nextOpen(),
        );
        final reason = status == 401 || status == 403
            ? 'source_denied'
            : 'range_unsupported';
        await expectLater(
          input.prepare(),
          throwsA(
            isA<SourceInputException>()
                .having((e) => e.reason, 'reason', reason)
                .having((e) => e.safeHttp, 'status', status)
                .having((e) => e.allowsSeekRecovery, 'no retry', false),
          ),
        );
        input.close();
        trace.finish();
        final result = await report(fixture.log, 'http-$status');
        expect(
          result.content,
          contains('stage=range_response reason=$reason http=$status'),
        );
        expect(result.content, isNot(contains('private-')));
        expect(result.content, isNot(contains(origin.host)));
        expect(result.content, isNot(contains('fingerprint=other')));
      },
    );
  }

  test(
    'cancelled in-flight input remains on old trace after new playback',
    () async {
      final fixture = await fileLog();
      final old = StrmTrace(log: fixture.log),
          next = StrmTrace(log: fixture.log);
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      final entered = Completer<void>(), release = Completer<void>();
      origin.intercept = (_) async {
        entered.complete();
        await release.future;
        return null;
      };
      final plan = await resolve(old, '${origin.origin}/private-file');
      final input = SourceHttpInput(
        plan.sourceRequest!,
        embyServer: plan.sourceRequest!.embyServer,
        openAttempt: old.nextOpen(),
      );
      final pending = expectLater(
        input.prepare(),
        throwsA(
          isA<SourceInputException>().having(
            (e) => e.reason,
            'reason',
            'cancelled',
          ),
        ),
      );
      await entered.future;
      input.close();
      next.emit('strm_entry', {'entry': 'inline', 'outcome': 'started'});
      release.complete();
      await pending;
      old.finish();
      next.finish();
      final result = await report(fixture.log, 'cancelled');
      final failures = result.content
          .split('\n')
          .where((l) => l.contains('event=strm_failure'))
          .toList();
      expect(failures, hasLength(1));
      expect(failures.single, contains('trace=${old.id}'));
      expect(failures.single, contains('reason=cancelled'));
      expect(failures.single, contains('http=unavailable'));
    },
  );

  test(
    'actual DNS and refused socket failures keep their stage without fake status',
    () async {
      final fixture = await fileLog();
      final server = await ProgressiveOrigin.start();
      final refused = server.origin;
      await server.close();
      for (final sample in [
        (
          url: 'http://nonexistent-strm-diagnostic.invalid/file',
          reason: 'dns_failed',
        ),
        (url: '$refused/file', reason: 'connect_failed'),
      ]) {
        final trace = StrmTrace(log: fixture.log);
        final plan = await resolve(trace, sample.url);
        final input = SourceHttpInput(
          plan.sourceRequest!,
          embyServer: plan.sourceRequest!.embyServer,
        );
        await expectLater(
          input.prepare(),
          throwsA(
            isA<SourceInputException>()
                .having((e) => e.reason, 'reason', sample.reason)
                .having((e) => e.safeHttp, 'http', null),
          ),
        );
        input.close();
        trace.finish();
      }
      final result = await report(fixture.log, 'dns-connect');
      expect(result.content, contains('reason=dns_failed http=unavailable'));
      expect(
        result.content,
        contains('reason=connect_failed http=unavailable'),
      );
    },
  );

  test(
    'active window summarizes at five seconds and idle input stays quiet',
    () async {
      final fixture = await fileLog();
      final trace = StrmTrace(log: fixture.log);
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      final plan = await resolve(trace, '${origin.origin}/file');
      final input = SourceHttpInput(
        plan.sourceRequest!,
        embyServer: plan.sourceRequest!.embyServer,
      );
      await input.prepare();
      final before = await fixture.log.read();
      await Future<void>.delayed(const Duration(milliseconds: 5100));
      expect(await fixture.log.read(), before);
      await input.read(400000, 1000);
      final active = await fixture.log.read();
      expect(active.split('outcome=periodic').length - 1, 1);
      for (var i = 0; i < 100; i++) {
        await input.read(0, 10);
      }
      expect(await fixture.log.read(), active);
      input.close();
      trace.finish();
      await report(fixture.log, 'periodic');
    },
  );

  test('typed IO categories are conservative and never inspect raw text', () {
    expect(
      SourceInputException.from(
        const SocketException('private-host'),
        stage: 'dns',
      ).reason,
      'dns_failed',
    );
    expect(
      SourceInputException.from(
        const SocketException('private-host'),
        stage: 'connect',
      ).reason,
      'connect_failed',
    );
    expect(
      SourceInputException.from(
        const HandshakeException('private-url'),
        stage: 'tls',
      ).reason,
      'tls_certificate',
    );
    expect(
      SourceInputException.from(
        TimeoutException('private'),
        stage: 'connect',
      ).reason,
      'timeout',
    );
    final unknown = SourceInputException.from(
      StateError('403 partial file https://private.invalid'),
      stage: 'body_read',
    );
    expect(unknown.reason, 'unknown');
    expect(unknown.safeHttp, null);
    expect(unknown.allowsSeekRecovery, false);
    expect(const SourceInputException('truncated').allowsSeekRecovery, true);
  });

  test(
    'structured export keeps skipped_stale but rejects appended payloads locally',
    () async {
      final fixture = await fileLog();
      const valid = 'event=playback_subtitle_apply_skipped_stale generation=3';
      fixture.log.info('playback', valid);
      for (final suffix in [
        ' url=https://private.invalid',
        ' token=private-secret',
        ' Cookie=private-secret',
        '\r\nCookie=private-secret',
        '\r\nCookie=private-secret\n',
        ' reason=%74%6f%6b%65%6e',
        ' unknown=private-secret',
        ' generation=4',
        ' generation=-1',
      ]) {
        fixture.log.info('playback', '$valid$suffix');
        expect(StrmDiagnosticSchema.valid('$valid$suffix'), false);
        expect(
          FullDiagnosticRedactor.containsSensitiveContent('$valid$suffix'),
          true,
        );
      }
      final raw = await fixture.log.read();
      expect(raw, contains(valid));
      expect(raw, isNot(contains('private-')));
      final result = await report(fixture.log, 'redaction');
      expect(result.content, contains(valid));
      expect(result.content, isNot(contains('private-')));
    },
  );

  test(
    'actual log file write failure does not change a successful source read',
    () async {
      final fixture = await fileLog();
      fixture.log.info('test', 'event=fixture');
      await fixture.log.read();
      await File('${fixture.directory.path}/log.txt').delete();
      await Directory('${fixture.directory.path}/log.txt').create();
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      final trace = StrmTrace(log: fixture.log);
      final plan = await resolve(trace, '${origin.origin}/file');
      final input = SourceHttpInput(
        plan.sourceRequest!,
        embyServer: plan.sourceRequest!.embyServer,
      );
      await input.prepare();
      expect((await input.read(0, 100)).length, 100);
      input.close();
      trace.finish();
      await fixture.log.read();
      expect(fixture.log.writeFailed, true);
    },
  );

  test(
    'bounded log queue and failed sink cannot fail input or hang export',
    () async {
      final fixture = await fileLog();
      fixture.log.setTestSink((_) => throw StateError('private-failure'));
      for (var i = 0; i < 4000; i++) {
        fixture.log.info('test', 'event=fixture count=$i padding=${'x' * 120}');
      }
      expect(fixture.log.droppedWrites, greaterThan(0));
      expect(fixture.log.writeFailed, true);
      expect(
        await fixture.log.read().timeout(const Duration(seconds: 10)),
        contains('event=diagnostic_entries_dropped'),
      );
      final origin = await ProgressiveOrigin.start();
      addTearDown(origin.close);
      final trace = StrmTrace(log: fixture.log);
      final plan = await resolve(trace, '${origin.origin}/file');
      final input = SourceHttpInput(
        plan.sourceRequest!,
        embyServer: plan.sourceRequest!.embyServer,
      );
      await input.prepare();
      input.close();
      trace.finish();
      await report(fixture.log, 'failed-sink');
    },
  );
}
