import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/export_credential_redactor.dart';
import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'package:emby_my_client/core/playback_diagnostic_snapshot.dart';
import 'package:emby_my_client/core/safe_diagnostic_export.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/ui/full_diagnostic_export_screen.dart';
import 'package:emby_my_client/ui/safe_diagnostic_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const safeChannel = MethodChannelSafeDiagnosticMetadataProvider.channel;
  const fullChannel = MethodChannelFullDiagnosticShareGateway.channel;
  tearDown(() {
    messenger.setMockMethodCallHandler(safeChannel, null);
    messenger.setMockMethodCallHandler(fullChannel, null);
  });

  for (final input in <String>[
    'password=fixture-secret',
    'password=["fixture-secret","second-private"]',
    'Cookie: ["sid=fixture-secret"]',
    '"password":"fixture-secret with spaces"',
    "pw='fixture-secret'",
    'Authorization: Basic fixture-secret',
    'headers={"Authorization":"Bearer fixture-secret"}',
    'Cookie: sid=fixture-secret; preferences=private',
    'Set-Cookie: session=fixture-secret; HttpOnly',
    'https://name:fixture-secret@server.invalid/Video/42',
    'https://server.invalid/Video/42?custom_credential=fixture-secret&lang=zh',
    'https://server.invalid/Video/42?Password=fixture-secret',
    'url=https%3A%2F%2Fserver.invalid%2Fa%3Fsignature%3Dfixture-secret',
    'password%253Dfixture-secret',
    r'{"password":"fixture\u002dsecret"}',
    'api_key=fixture-secret',
    'refresh_token=fixture-secret',
  ]) {
    test('export removes encoded credentials: ${input.split('=').first}', () {
      final redacted = ExportCredentialRedactor.redact(input);
      expect(redacted, isNot(contains('fixture-secret')));
      expect(redacted, isNot(contains(r'fixture\u002dsecret')));
      expect(ExportCredentialRedactor.redact(redacted), redacted);
    });
  }

  test(
    'Android full snapshot preserves original file and binds privacy platform and digest',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'emo-export-fixture-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/fixture.log');
      const raw =
          'server=https://server.invalid/Items/42 password=fixture-secret\n';
      await file.writeAsString(raw);
      final report = await FullDiagnosticExportService(
        readLog: file.readAsString,
        appVersion: '1.0.183',
        buildNumber: '1832000',
        platform: 'Android',
      ).buildReport();
      expect(await file.readAsString(), raw);
      expect(report.content, contains('server.invalid/Items/42'));
      expect(report.content, contains('platform=Android'));
      expect(report.content, contains('redaction=credentials-v1'));
      expect(report.content, isNot(contains('fixture-secret')));
      FullDiagnosticExportService.validateSnapshot(report.content);
      for (final invalid in [
        report.content.replaceFirst('platform=Android', 'platform=unknown'),
        report.content.replaceFirst('credentials-v1', 'token-only-v1'),
        '${report.content}tampered',
      ]) {
        expect(
          () => FullDiagnosticExportService.validateSnapshot(invalid),
          throwsA(isA<FullDiagnosticExportException>()),
        );
      }
    },
  );

  test(
    'native metadata uses Android installed version and split build',
    () async {
      messenger.setMockMethodCallHandler(safeChannel, (call) async {
        expect(call.method, 'metadata');
        return {
          'appVersion': '1.0.183',
          'buildNumber': '1832000',
          'platform': 'Android',
        };
      });
      final report = await SafeDiagnosticExportService(
        source: _Events(),
      ).buildReport();
      final json = jsonDecode(report.content) as Map<String, dynamic>;
      expect(json['platform'], 'Android');
      expect(json['buildNumber'], '1832000');
      SafeDiagnosticExportService.validateSnapshot(report.content);
      json['password'] = 'fixture-secret';
      expect(
        () => SafeDiagnosticExportService.validateSnapshot(jsonEncode(json)),
        throwsA(isA<SafeDiagnosticExportException>()),
      );
    },
  );

  test('unsupported platform metadata is rejected', () async {
    messenger.setMockMethodCallHandler(
      safeChannel,
      (_) async => {
        'appVersion': '1.0.183',
        'buildNumber': '1832000',
        'platform': 'other',
      },
    );
    await expectLater(
      SafeDiagnosticExportService(source: _Events()).buildReport(),
      throwsA(isA<SafeDiagnosticExportException>()),
    );
  });

  for (final full in [false, true]) {
    for (final outcome in [
      'saved',
      'cancelled',
      'opened',
      'write-error',
      'share-error',
    ]) {
      testWidgets(
        '${full ? 'full' : 'safe'} Android export reports $outcome truthfully',
        (tester) async {
          tester.view.physicalSize = const Size(1000, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final calls = <MethodCall>[];
          messenger.setMockMethodCallHandler(full ? fullChannel : safeChannel, (
            call,
          ) async {
            calls.add(call);
            final content = (call.arguments as Map)['content'] as String;
            expect(content, isNot(contains('fixture-secret')));
            if (outcome.endsWith('error')) {
              throw PlatformException(
                code:
                    '${full ? 'FULL-DIAG' : 'DIAG-EXPORT'}-${outcome == 'write-error' ? 'WRITE' : 'SHARE'}',
                message: 'fixture-secret',
              );
            }
            return outcome;
          });
          await tester.pumpWidget(
            MaterialApp(home: full ? _fullScreen() : _safeScreen()),
          );
          await tester.pumpAndSettle();
          final save =
              outcome == 'saved' ||
              outcome == 'cancelled' ||
              outcome == 'write-error';
          final entry = full
              ? find.byTooltip(save ? '保存完整调试日志' : '导出完整调试日志')
              : find.text(save ? '保存安全诊断' : '导出安全诊断');
          await tester.ensureVisible(entry);
          await tester.tap(entry);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.widgetWithText(FilledButton, '导出'));
          await tester.pumpAndSettle();
          expect(
            calls.single.method,
            full
                ? (save ? 'fullSave' : 'fullShare')
                : (save ? 'save' : 'share'),
          );
          expect(
            find.textContaining('诊断文件已保存'),
            outcome == 'saved' ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('已取消导出'),
            outcome == 'cancelled' ? findsOneWidget : findsNothing,
          );
          if (outcome == 'opened') {
            expect(find.textContaining('未自动发送'), findsOneWidget);
          }
          if (outcome.endsWith('error')) {
            expect(find.textContaining('操作失败'), findsOneWidget);
          }
          expect(find.textContaining('fixture-secret'), findsNothing);
        },
      );
    }
  }

  testWidgets(
    'save remains single-flight and closing the page ignores a late completion',
    (tester) async {
      final result = Completer<String>();
      var calls = 0;
      messenger.setMockMethodCallHandler(fullChannel, (_) {
        calls++;
        return result.future;
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('home')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => _fullScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存完整调试日志'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '导出'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == '保存完整调试日志',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(calls, 1);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      result.complete('saved');
      await tester.pumpAndSettle();
      expect(find.textContaining('诊断文件已保存'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

FullDiagnosticExportScreen _fullScreen() => FullDiagnosticExportScreen(
  initialScope: DiagnosticLogScope.all,
  capabilities: PlatformCapabilities.android,
  service: FullDiagnosticExportService(
    readLog: () async => 'event=fixture password=fixture-secret\n',
    appVersion: '1.0.183',
    buildNumber: '1832000',
    platform: 'Android',
  ),
);
SafeDiagnosticExportScreen _safeScreen() => SafeDiagnosticExportScreen(
  capabilities: PlatformCapabilities.android,
  service: SafeDiagnosticExportService(
    source: _Events(),
    appVersion: '1.0.183',
    buildNumber: '1832000',
    platform: 'Android',
  ),
);

class _Events implements SafeDiagnosticEventSource {
  @override
  Future<void> clearSafeEvents() async {}
  @override
  Future<List<SafeDiagnosticRecord>> readSafeEvents() async => [
    SafeDiagnosticRecord(
      atUtc: DateTime.utc(2026, 10, 14),
      level: SafeDiagnosticLevel.error,
      component: SafeDiagnosticComponent.auth,
      event: SafeDiagnosticEvent.signInFailure,
      stage: SignInStage.authenticate,
      reason: SafeDiagnosticReason.embyApiFailure,
      errorType: SafeDiagnosticErrorType.embyApiException,
    ),
  ];
}
