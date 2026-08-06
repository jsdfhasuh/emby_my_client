import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/safe_diagnostic_export.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/models/discovered_server.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:emby_my_client/ui/diagnostic_log_screen.dart';
import 'package:emby_my_client/ui/safe_diagnostic_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'typed safe events are written to an independent JSONL stream',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'emby-safe-diagnostic-test-',
      );
      final log = DiagnosticLog.forTesting();
      final file = File('${directory.path}/emby_safe_diagnostics_v1.jsonl');
      log.setTestSafeEventFile(file);
      addTearDown(() async {
        await log.readSafeEvents();
        await directory.delete(recursive: true);
      });

      log.safeFailure(
        component: SafeDiagnosticComponent.storage,
        event: SafeDiagnosticEvent.sessionRestoreFailure,
        stage: SignInStage.sessionRead,
        reason: SafeDiagnosticReason.secureStorageUnexpected,
        errorType: SafeDiagnosticErrorType.secureStorageFailure,
      );

      final records = await log.readSafeEvents();
      expect(records, hasLength(1));
      expect(records.single.stage, SignInStage.sessionRead);
      expect(
        records.single.reason,
        SafeDiagnosticReason.secureStorageUnexpected,
      );
      expect(records.single.diagnosticCode, 'LOGIN-UNKNOWN');
      expect(await file.readAsLines(), hasLength(1));
      expect(await log.read(), isEmpty);
    },
  );

  test('safe event write failure is best effort and does not throw', () {
    final log = DiagnosticLog.forTesting()
      ..setSafeEventTestSink((_) => throw StateError('not exported'));

    expect(
      () => log.safeStage(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInStageStart,
        stage: SignInStage.authenticate,
        reason: SafeDiagnosticReason.unknown,
        errorType: SafeDiagnosticErrorType.unknown,
      ),
      returnsNormally,
    );
  });

  test('raw diagnostic messages never enter the safe event stream', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-safe-diagnostic-redaction-',
    );
    final log = DiagnosticLog.forTesting();
    final file = File('${directory.path}/events.jsonl');
    log.setTestSafeEventFile(file);
    addTearDown(() => directory.delete(recursive: true));
    const secret =
        'password=secret username=fixture deviceId=device-1 '
        'https://fixture.invalid:8096 Authorization: Bearer token';

    log.error(
      'auth',
      secret,
      error: StateError(secret),
      stackTrace: StackTrace.fromString(secret),
    );
    log.safeFailure(
      component: SafeDiagnosticComponent.auth,
      event: SafeDiagnosticEvent.signInFailure,
      stage: SignInStage.authenticate,
      reason: SafeDiagnosticReason.unknown,
      errorType: SafeDiagnosticErrorType.unknown,
    );

    await log.readSafeEvents();
    final contents = await file.readAsString();
    expect(contents, isNot(contains('password=secret')));
    expect(contents, isNot(contains('fixture.invalid')));
    expect(contents, isNot(contains('Bearer token')));
    expect(contents, isNot(contains('StateError')));
    expect(contents, isNot(contains('StackTrace')));
  });

  test('corrupt safe JSONL fails closed and clear restores writing', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-safe-diagnostic-recovery-',
    );
    final log = DiagnosticLog.forTesting();
    final file = File('${directory.path}/events.jsonl');
    log.setTestSafeEventFile(file);
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsString('{"not":"a safe event"}\n');

    await expectLater(
      log.readSafeEvents(),
      throwsA(isA<SafeDiagnosticValidationException>()),
    );
    await log.clearSafeEvents();
    log.safeStage(
      component: SafeDiagnosticComponent.auth,
      event: SafeDiagnosticEvent.signInStageStart,
      stage: SignInStage.authenticate,
      reason: SafeDiagnosticReason.unknown,
      errorType: SafeDiagnosticErrorType.unknown,
    );

    final records = await log.readSafeEvents();
    expect(records, hasLength(1));
    expect(records.single.stage, SignInStage.authenticate);
  });

  test('clear is serialized with append and does not leave a race', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-safe-diagnostic-queue-',
    );
    final log = DiagnosticLog.forTesting();
    log.setTestSafeEventFile(File('${directory.path}/events.jsonl'));
    addTearDown(() => directory.delete(recursive: true));

    for (var index = 0; index < 25; index++) {
      log.safeStage(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInStageStart,
        stage: SignInStage.authenticate,
        reason: SafeDiagnosticReason.unknown,
        errorType: SafeDiagnosticErrorType.unknown,
      );
    }
    await log.clearSafeEvents();
    log.safeStage(
      component: SafeDiagnosticComponent.storage,
      event: SafeDiagnosticEvent.sessionRestoreFailure,
      stage: SignInStage.sessionRead,
      reason: SafeDiagnosticReason.secureStorageUnexpected,
      errorType: SafeDiagnosticErrorType.secureStorageFailure,
    );

    final records = await log.readSafeEvents();
    expect(records, hasLength(1));
    expect(records.single.component, SafeDiagnosticComponent.storage);
  });

  test('safe event JSONL rejects blank or malformed records', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-safe-diagnostic-invalid-',
    );
    final log = DiagnosticLog.forTesting();
    final file = File('${directory.path}/events.jsonl');
    log.setTestSafeEventFile(file);
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsString(
      '${jsonEncode(<String, Object>{'unknown': true})}\n\n',
    );

    await expectLater(
      log.readSafeEvents(),
      throwsA(isA<SafeDiagnosticValidationException>()),
    );
  });

  test(
    'report has the fixed schema and hashes only its verified snapshot',
    () async {
      final source = _FakeSafeEventSource(records: [_record(0)]);
      final service = _service(source);
      final report = await service.buildReport(
        generatedAtUtc: DateTime.utc(2026, 8, 6, 12, 30, 45),
      );
      final decoded = jsonDecode(report.content) as Map<String, dynamic>;
      final record =
          (decoded['records'] as List).single as Map<String, dynamic>;

      expect(decoded.keys.toSet(), {
        'schema',
        'generatedAtUtc',
        'appVersion',
        'buildNumber',
        'platform',
        'recordCount',
        'truncated',
        'records',
      });
      expect(decoded['schema'], 'emby-safe-diagnostics/v1');
      expect(decoded['platform'], 'iPadOS');
      expect(decoded['recordCount'], 1);
      expect(decoded['truncated'], isFalse);
      expect(record.keys.toSet(), {
        'atUtc',
        'level',
        'component',
        'event',
        'stage',
        'reason',
        'errorType',
        'diagnosticCode',
      });
      expect(
        report.filename,
        'emby-safe-diagnostics-v1-b42-20260806T123045Z.json',
      );
      expect(
        report.sha256,
        sha256.convert(utf8.encode(report.content)).toString(),
      );
      expect(report.content, isNot(contains('emby_client_diagnostics.log')));
      SafeDiagnosticExportService.validateSnapshot(report.content);
    },
  );

  test(
    'invalid metadata blocks report creation without unknown placeholders',
    () async {
      final source = _FakeSafeEventSource(records: [_record(0)]);
      for (final values in const [
        ('1.0', '42'),
        ('1.0.0', ''),
        ('unknown', '42'),
        ('1.0.0', '42x'),
      ]) {
        final service = SafeDiagnosticExportService(
          source: source,
          appVersion: values.$1,
          buildNumber: values.$2,
        );
        await expectLater(
          service.buildReport(),
          throwsA(
            isA<SafeDiagnosticExportException>().having(
              (error) => error.code,
              'code',
              SafeDiagnosticExportException.unsafe,
            ),
          ),
        );
      }
    },
  );

  test('only the newest 1000 complete records are retained', () async {
    final records = List<SafeDiagnosticRecord>.generate(1001, _record);
    final report = await _service(
      _FakeSafeEventSource(records: records),
    ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 6));

    expect(report.recordCount, 1000);
    expect(report.truncated, isTrue);
    expect(report.records.first.atUtc, records[1].atUtc);
    expect(report.records.last.atUtc, records.last.atUtc);
    expect(utf8.encode(report.content).length, lessThanOrEqualTo(256 * 1024));
  });

  test(
    'legal records trigger byte truncation without invalid metadata',
    () async {
      final records = List<SafeDiagnosticRecord>.generate(1000, (index) {
        return SafeDiagnosticRecord(
          atUtc: DateTime.utc(2026, 8, 6).add(Duration(seconds: index)),
          level: SafeDiagnosticLevel.error,
          component: SafeDiagnosticComponent.storage,
          event: SafeDiagnosticEvent.sessionRestoreFailure,
          stage: SignInStage.sessionPrepare,
          reason: SafeDiagnosticReason.secureStorageMissingEntitlement,
          errorType: SafeDiagnosticErrorType.secureStorageFailure,
        );
      });
      final longButValidAppVersion = '1.${'1' * 20000}.0';
      final report = await SafeDiagnosticExportService(
        source: _FakeSafeEventSource(records: records),
        appVersion: longButValidAppVersion,
        buildNumber: '42',
      ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 6));

      expect(report.truncated, isTrue);
      expect(report.recordCount, lessThan(1000));
      expect(report.appVersion, longButValidAppVersion);
      expect(utf8.encode(report.content).length, lessThanOrEqualTo(256 * 1024));
      expect(
        report.records.every((record) => record.toJson().length == 8),
        isTrue,
      );
      expect(
        report.recordCount,
        (jsonDecode(report.content)['records'] as List).length,
      );
      SafeDiagnosticExportService.validateSnapshot(report.content);
    },
  );

  test(
    'an oversized verified snapshot fails closed instead of cutting a record',
    () async {
      final hugeVersion = '1.${'1' * (256 * 1024)}.0';
      final service = SafeDiagnosticExportService(
        source: _FakeSafeEventSource(),
        appVersion: hugeVersion,
        buildNumber: '42',
      );

      await expectLater(
        service.buildReport(),
        throwsA(
          isA<SafeDiagnosticExportException>().having(
            (error) => error.code,
            'code',
            SafeDiagnosticExportException.unsafe,
          ),
        ),
      );
    },
  );

  test('read failure never falls back to the raw diagnostic log', () async {
    final service = SafeDiagnosticExportService(
      source: _FakeSafeEventSource(readError: StateError('raw log content')),
      appVersion: '1.0.0',
      buildNumber: '42',
    );

    await expectLater(
      service.buildReport(),
      throwsA(
        isA<SafeDiagnosticExportException>().having(
          (error) => error.code,
          'code',
          SafeDiagnosticExportException.read,
        ),
      ),
    );
  });

  test('clearing safe events maps failures to the fixed write code', () async {
    final service = _service(
      _FakeSafeEventSource(clearError: StateError('raw clear failure')),
    );

    await expectLater(
      service.clearSafeEvents(),
      throwsA(
        isA<SafeDiagnosticExportException>().having(
          (error) => error.code,
          'code',
          SafeDiagnosticExportException.write,
        ),
      ),
    );
  });

  test(
    'unknown keys, enums, sensitive fields, URLs and paths fail validation',
    () async {
      final report = await _service(
        _FakeSafeEventSource(records: [_record(0)]),
      ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 6));
      final decoded = jsonDecode(report.content) as Map<String, dynamic>;
      final baseRecord = Map<String, dynamic>.from(
        (decoded['records'] as List).single as Map,
      );

      final invalidSnapshots = <Map<String, dynamic>>[
        {...decoded, 'password': 'fixture-only'},
        {
          ...decoded,
          'records': [
            {...baseRecord, 'extra': 'x'},
          ],
        },
        {
          ...decoded,
          'records': [
            {...baseRecord, 'stage': 'UNKNOWN'},
          ],
        },
        {
          ...decoded,
          'records': [
            {...baseRecord, 'atUtc': '2026-08-06T12:00:00Z\n'},
          ],
        },
        {...decoded, 'serverUrl': 'https://fixture.invalid:8096'},
      ];

      for (final snapshot in invalidSnapshots) {
        expect(
          () => SafeDiagnosticExportService.validateSnapshot(
            jsonEncode(snapshot),
          ),
          throwsA(
            isA<SafeDiagnosticExportException>().having(
              (error) => error.code,
              'code',
              SafeDiagnosticExportException.unsafe,
            ),
          ),
        );
      }
    },
  );

  test('native share gateway receives the exact immutable snapshot', () async {
    final report = await _service(
      _FakeSafeEventSource(records: [_record(0)]),
    ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 6));
    Map<String, Object?>? arguments;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      MethodChannelSafeDiagnosticMetadataProvider.channel,
      (call) async {
        expect(call.method, 'share');
        arguments = Map<String, Object?>.from(call.arguments as Map);
        return 'completed';
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        MethodChannelSafeDiagnosticMetadataProvider.channel,
        null,
      ),
    );

    await const MethodChannelSafeDiagnosticShareGateway().share(
      report,
      anchor: SafeDiagnosticPopoverAnchor(x: 1, y: 2, width: 3, height: 4),
    );

    expect(arguments?['content'], report.content);
    expect(arguments?['x'], 1);
    expect(arguments?['y'], 2);
    expect(arguments?['width'], 3);
    expect(arguments?['height'], 4);
    expect(
      arguments?['content'],
      isNot(contains('emby_client_diagnostics.log')),
    );
  });

  test(
    'native share maps fixed completed, cancelled, and error outcomes',
    () async {
      final report = await _service(
        _FakeSafeEventSource(records: [_record(0)]),
      ).buildReport(generatedAtUtc: DateTime.utc(2026, 8, 6));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final outcomes = <Object?>['completed', 'cancelled'];
      for (final outcome in outcomes) {
        messenger.setMockMethodCallHandler(
          MethodChannelSafeDiagnosticMetadataProvider.channel,
          (_) async => outcome,
        );
        final result = await const MethodChannelSafeDiagnosticShareGateway()
            .share(
              report,
              anchor: const SafeDiagnosticPopoverAnchor(
                x: 0,
                y: 0,
                width: 1,
                height: 1,
              ),
            );
        expect(
          result,
          outcome == 'completed'
              ? SafeDiagnosticShareOutcome.completed
              : SafeDiagnosticShareOutcome.cancelled,
        );
      }
      for (final code in [
        SafeDiagnosticExportException.unsafe,
        SafeDiagnosticExportException.write,
        SafeDiagnosticExportException.share,
        SafeDiagnosticExportException.busy,
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannelSafeDiagnosticMetadataProvider.channel,
          (_) async => throw PlatformException(
            code: code,
            message: 'password=must-not-be-shown',
            details: 'raw details',
          ),
        );
        await expectLater(
          const MethodChannelSafeDiagnosticShareGateway().share(
            report,
            anchor: SafeDiagnosticPopoverAnchor(
              x: 0,
              y: 0,
              width: 1,
              height: 1,
            ),
          ),
          throwsA(
            isA<SafeDiagnosticExportException>().having(
              (error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          MethodChannelSafeDiagnosticMetadataProvider.channel,
          null,
        ),
      );
    },
  );

  testWidgets('safe page shares the exact text shown in its preview', (
    tester,
  ) async {
    final gateway = _CapturingShareGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: SafeDiagnosticExportScreen(
          service: _service(_FakeSafeEventSource(records: [_record(0)])),
          shareGateway: gateway,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final preview = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('safe-diagnostic-preview')),
    );
    final previewText = preview.data!;
    await tester.tap(find.text('导出安全诊断'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    expect(gateway.report?.content, previewText);
  });

  testWidgets('confirmation cancellation never calls native share', (
    tester,
  ) async {
    final gateway = _CapturingShareGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: SafeDiagnosticExportScreen(
          service: _service(_FakeSafeEventSource(records: [_record(0)])),
          shareGateway: gateway,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出安全诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.report, isNull);
  });

  testWidgets('rapid taps keep one confirmation and one native call', (
    tester,
  ) async {
    final gateway = _DelayedShareGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: SafeDiagnosticExportScreen(
          service: _service(_FakeSafeEventSource(records: [_record(0)])),
          shareGateway: gateway,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出安全诊断'));
    await tester.pump();
    expect(find.text('导出安全诊断？'), findsOneWidget);
    await tester.tap(find.text('导出安全诊断'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('导出安全诊断？'), findsOneWidget);
    await tester.tap(find.text('导出'));
    await tester.pump();
    expect(gateway.calls, 1);
    gateway.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'empty safe report disables export and shows the fixed empty text',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SafeDiagnosticExportScreen(
            service: _service(_FakeSafeEventSource()),
            shareGateway: _CapturingShareGateway(),
            capabilities: PlatformCapabilities.ipad,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('暂无可导出的安全诊断记录'), findsOneWidget);
      final exportButton = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('导出安全诊断'),
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        ),
      );
      expect(exportButton.onPressed, isNull);
    },
  );

  testWidgets('iPad login exposes safe diagnostics without submitting', (
    tester,
  ) async {
    final controller = _CountingLoginController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          controller: controller,
          capabilities: PlatformCapabilities.ipad,
          discovery: _EmptyDiscovery(),
          safeDiagnosticService: _service(_FakeSafeEventSource()),
          safeDiagnosticShareGateway: _CapturingShareGateway(),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-server-field')),
      'fixture-server',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-username-field')),
      'fixture-user',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('login-safe-diagnostics-button')),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.byType(SafeDiagnosticExportScreen), findsOneWidget);
    expect(find.text('安全登录诊断'), findsOneWidget);
    expect(controller.signInCalls, 0);
    await tester.pageBack();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.text('fixture-server'), findsOneWidget);
    expect(find.text('fixture-user'), findsOneWidget);
  });

  testWidgets('Android login does not expose the iPad safe diagnostics entry', (
    tester,
  ) async {
    final controller = _CountingLoginController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          controller: controller,
          capabilities: PlatformCapabilities.android,
          discovery: _EmptyDiscovery(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('login-safe-diagnostics-button')),
      findsNothing,
    );
  });

  testWidgets('Android diagnostic log page has no iPad export entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DiagnosticLogScreen(capabilities: PlatformCapabilities.android),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('安全登录诊断'), findsNothing);
  });
}

SafeDiagnosticExportService _service(SafeDiagnosticEventSource source) =>
    SafeDiagnosticExportService(
      source: source,
      appVersion: '1.0.0',
      buildNumber: '42',
    );

SafeDiagnosticRecord _record(int index) => SafeDiagnosticRecord(
  atUtc: DateTime.utc(2026, 8, 6).add(Duration(seconds: index)),
  level: SafeDiagnosticLevel.info,
  component: SafeDiagnosticComponent.auth,
  event: SafeDiagnosticEvent.signInStageStart,
  stage: SignInStage.sessionRead,
  reason: SafeDiagnosticReason.unknown,
  errorType: SafeDiagnosticErrorType.unknown,
);

class _FakeSafeEventSource implements SafeDiagnosticEventSource {
  _FakeSafeEventSource({
    this.records = const [],
    this.readError,
    this.clearError,
  });

  final List<SafeDiagnosticRecord> records;
  final Object? readError;
  final Object? clearError;

  @override
  Future<List<SafeDiagnosticRecord>> readSafeEvents() async {
    if (readError != null) throw readError!;
    return records;
  }

  @override
  Future<void> clearSafeEvents() async {
    if (clearError != null) throw clearError!;
  }
}

class _CapturingShareGateway implements SafeDiagnosticShareGateway {
  SafeDiagnosticReport? report;
  SafeDiagnosticPopoverAnchor? anchor;

  @override
  Future<SafeDiagnosticShareOutcome> share(
    SafeDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) async {
    this.report = report;
    this.anchor = anchor;
    return SafeDiagnosticShareOutcome.completed;
  }
}

class _DelayedShareGateway implements SafeDiagnosticShareGateway {
  final completer = Completer<SafeDiagnosticShareOutcome>();
  var calls = 0;

  @override
  Future<SafeDiagnosticShareOutcome> share(
    SafeDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) {
    calls++;
    return completer.future;
  }

  void complete() => completer.complete(SafeDiagnosticShareOutcome.completed);
}

class _CountingLoginController extends AppController {
  _CountingLoginController()
    : super(capabilities: PlatformCapabilities.android);

  int signInCalls = 0;

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    signInCalls++;
  }
}

class _EmptyDiscovery extends EmbyServerDiscovery {
  @override
  Future<List<DiscoveredServer>> discover() async => const [];
}
