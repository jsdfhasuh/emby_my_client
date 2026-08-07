import 'dart:async';
import 'dart:convert';

import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'package:emby_my_client/core/safe_diagnostic_export.dart';
import 'package:emby_my_client/ui/diagnostic_log_screen.dart';
import 'package:emby_my_client/ui/full_diagnostic_export_screen.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('full report contains fixed playback and orientation events', () async {
    final report = await _service(
      '''2026-08-07T01:00:00.000Z [INFO] [player] event=player_route_enter orientationPolicy=landscape_playback
2026-08-07T01:00:01.000Z [INFO] [player] event=fullscreen_orientation_applied orientationPolicy=landscape_playback
2026-08-07T01:00:02.000Z [INFO] [player] event=orientation_restore_applied orientationPolicy=system_default
''',
    ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 7, 1));

    expect(report.filename, 'emby-full-diagnostics-b42-20260807T010000Z.txt');
    expect(report.content, contains('schema=emby-full-diagnostics/v1'));
    expect(report.content, contains('platform=iPadOS'));
    expect(report.content, contains('player_route_enter'));
    expect(report.content, contains('orientation_restore_applied'));
    expect(report.sha256, hasLength(64));
    expect(report.content, contains('sha256=${report.sha256}'));
    FullDiagnosticExportService.validateSnapshot(report.content);
  });

  test('full report performs a second redaction pass', () async {
    final report = await _service('''Authorization: Basic dXNlcjpwYXNzd29yZA==
username=fixture-user password=fixture-password
Bearer fixture-token X-Emby-Token=fixture-emby-token api_key=fixture-key
deviceId=fixture-device http://192.0.2.10:8096 Session JSON {"accessToken":"fixture"}
path=/Users/fixture/Library/Containers/app/data
''').buildReport(generatedAtUtc: DateTime.utc(2026, 8, 7));

    expect(report.content, isNot(contains('fixture-password')));
    expect(report.content, isNot(contains('fixture-user')));
    expect(report.content, isNot(contains('fixture-token')));
    expect(report.content, isNot(contains('192.0.2.10')));
    expect(report.content, isNot(contains('/Users/fixture')));
    expect(report.content, isNot(contains('Authorization')));
  });

  test(
    'full report redacts server, path, session, and request fields',
    () async {
      final report = await _service('''
serverUrl=http://fixture.invalid:8096
baseUrl=/var/mobile/Containers/Data/server
host=fixture.invalid address=192.0.2.40
Session: {"value":"fixture"}
request headers: {"Authorization":"Bearer fixture"}
''').buildReport(generatedAtUtc: DateTime.utc(2026, 8, 7));

      expect(report.content, isNot(contains('fixture.invalid')));
      expect(report.content, isNot(contains('192.0.2.40')));
      expect(report.content, isNot(contains('/var/mobile')));
      expect(report.content, isNot(contains('Session:')));
      expect(report.content, isNot(contains('request headers')));
      FullDiagnosticExportService.validateSnapshot(report.content);
    },
  );

  test('read failure maps to the fixed read code', () async {
    await expectLater(
      _service(
        '',
        readError: StateError('raw diagnostic failure'),
      ).buildReport(),
      throwsA(
        isA<FullDiagnosticExportException>().having(
          (error) => error.code,
          'code',
          FullDiagnosticExportException.read,
        ),
      ),
    );
  });

  test('second redaction failure fails closed', () async {
    await expectLater(
      _service('payload 2001:db8::10').buildReport(),
      throwsA(
        isA<FullDiagnosticExportException>().having(
          (error) => error.code,
          'code',
          FullDiagnosticExportException.unsafe,
        ),
      ),
    );
  });

  test('large legal logs truncate complete recent lines under 750 KiB', () async {
    final log = List<String>.generate(
      12000,
      (index) =>
          'event=orientation_metrics_changed logicalWidth=1024 logicalHeight=768 index=$index ${'x' * 70}',
    ).join('\n');
    final report = await _service(
      log,
    ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 7));

    expect(report.truncated, isTrue);
    expect(report.content.codeUnits.length, greaterThan(0));
    expect(utf8.encode(report.content).length, lessThanOrEqualTo(750 * 1024));
    expect(report.content, contains('index=11999'));
    expect(report.content, isNot(contains('index=0 ')));
    FullDiagnosticExportService.validateSnapshot(report.content);
  });

  test(
    'method channel maps fixed full diagnostic outcomes and errors',
    () async {
      final report = await _service('event=player_route_enter').buildReport();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final gateway = const MethodChannelFullDiagnosticShareGateway();
      final anchor = const SafeDiagnosticPopoverAnchor(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
      );

      messenger.setMockMethodCallHandler(
        MethodChannelFullDiagnosticShareGateway.channel,
        (_) async => 'completed',
      );
      expect(
        await gateway.share(report, anchor: anchor),
        FullDiagnosticShareOutcome.completed,
      );
      messenger.setMockMethodCallHandler(
        MethodChannelFullDiagnosticShareGateway.channel,
        (_) async => 'cancelled',
      );
      expect(
        await gateway.share(report, anchor: anchor),
        FullDiagnosticShareOutcome.cancelled,
      );

      for (final code in [
        FullDiagnosticExportException.unsafe,
        FullDiagnosticExportException.write,
        FullDiagnosticExportException.share,
        FullDiagnosticExportException.busy,
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannelFullDiagnosticShareGateway.channel,
          (_) async => throw PlatformException(
            code: code,
            message: 'password=fixture-secret',
            details: '/private/fixture/path',
          ),
        );
        await expectLater(
          gateway.share(report, anchor: anchor),
          throwsA(
            isA<FullDiagnosticExportException>().having(
              (error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          MethodChannelFullDiagnosticShareGateway.channel,
          null,
        ),
      );
    },
  );

  testWidgets('full preview and share use the same immutable snapshot', (
    tester,
  ) async {
    final gateway = _CapturingGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: FullDiagnosticExportScreen(
          service: _service('event=player_route_enter'),
          shareGateway: gateway,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final preview = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('full-diagnostic-preview')),
    );
    final snapshot = preview.data!;
    await tester.tap(find.text('导出完整调试日志'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('导出'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(gateway.report?.content, snapshot);
  });

  testWidgets('cancelled full export does not call native share', (
    tester,
  ) async {
    final gateway = _CapturingGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: FullDiagnosticExportScreen(
          service: _service('event=player_route_enter'),
          shareGateway: gateway,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出完整调试日志'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(gateway.calls, 0);
  });

  testWidgets('rapid full export taps keep one native call', (tester) async {
    final gateway = _DelayedGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: FullDiagnosticExportScreen(
          service: _service('event=player_route_enter'),
          shareGateway: gateway,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出完整调试日志'));
    await tester.pump();
    expect(find.text('导出完整调试日志？'), findsOneWidget);
    await tester.tap(find.text('导出完整调试日志'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('导出完整调试日志？'), findsOneWidget);
    await tester.tap(find.text('导出'));
    await tester.pump();
    expect(gateway.calls, 1);
    gateway.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('Android diagnostics page has no full export entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DiagnosticLogScreen(capabilities: PlatformCapabilities.android),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('导出完整调试日志'), findsNothing);
  });
}

FullDiagnosticExportService _service(String log, {Object? readError}) {
  return FullDiagnosticExportService(
    appVersion: '1.0.0',
    buildNumber: '42',
    readLog: () async {
      if (readError != null) throw readError;
      return log;
    },
  );
}

class _CapturingGateway implements FullDiagnosticShareGateway {
  FullDiagnosticReport? report;
  int calls = 0;

  @override
  Future<FullDiagnosticShareOutcome> share(
    FullDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) async {
    calls++;
    this.report = report;
    return FullDiagnosticShareOutcome.completed;
  }
}

class _DelayedGateway implements FullDiagnosticShareGateway {
  final completer = Completer<FullDiagnosticShareOutcome>();
  int calls = 0;

  @override
  Future<FullDiagnosticShareOutcome> share(
    FullDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) {
    calls++;
    return completer.future;
  }

  void complete() => completer.complete(FullDiagnosticShareOutcome.completed);
}
