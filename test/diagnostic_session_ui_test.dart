import 'dart:async';
import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'package:emby_my_client/core/playback_diagnostic_snapshot.dart';
import 'package:emby_my_client/core/safe_diagnostic_export.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/ui/diagnostic_log_screen.dart';
import 'package:emby_my_client/ui/full_diagnostic_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const a = '1111111111111111';
const b = '2222222222222222';
const first =
    'event=strm_entry trace=$a entry=fullscreen outcome=started\n'
    'event=playback_subtitle_apply_requested trace=$a streamIndex=3 generation=1\n'
    'event=playback_subtitle_content_detected trace=$a streamIndex=3 generation=1 format=ass\n'
    'event=playback_subtitle_applied trace=$a streamIndex=3 generation=1\n';
const second = 'event=strm_entry trace=$b entry=fullscreen outcome=started\n';

void main() {
  testWidgets(
    'small screen large-text diagnostics keep scope controls usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: DiagnosticLogScreen(
            capabilities: PlatformCapabilities.android,
            readLog: () async => first,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('diagnostic-scope-all')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('导出完整调试日志'), findsOneWidget);
    },
  );

  testWidgets(
    'diagnostics default to playback and keep its ID through refresh and all toggle',
    (tester) async {
      var raw = first;
      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosticLogScreen(
            capabilities: PlatformCapabilities.android,
            readLog: () async => raw,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放标识：$a'), findsOneWidget);
      expect(find.text('实际字幕格式：ASS'), findsOneWidget);
      expect(find.byTooltip('导出本次播放诊断'), findsOneWidget);
      raw += second;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(_preview(tester), isNot(contains(b)));
      await tester.tap(find.byKey(const ValueKey('diagnostic-scope-all')));
      await tester.pumpAndSettle();
      expect(_preview(tester), contains(b));
      expect(find.byTooltip('导出完整调试日志'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('diagnostic-scope-currentPlayback')),
      );
      await tester.pumpAndSettle();
      expect(_preview(tester), contains(a));
      expect(_preview(tester), isNot(contains(b)));
    },
  );

  testWidgets('explicit playback selection wins over a newer session', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticLogScreen(
          capabilities: PlatformCapabilities.android,
          playbackTraceId: a,
          readLog: () async => '$first$second',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('播放标识：$a'), findsOneWidget);
    expect(_preview(tester), isNot(contains(b)));
  });

  testWidgets(
    'export pins the preview snapshot through confirmation and native handoff',
    (tester) async {
      var raw = first;
      final gateway = _Gateway();
      await tester.pumpWidget(
        MaterialApp(
          home: FullDiagnosticExportScreen(
            capabilities: PlatformCapabilities.android,
            service: FullDiagnosticExportService(
              readLog: () async => raw,
              appVersion: '1.0.195',
              buildNumber: '1952000',
              platform: 'Android',
            ),
            shareGateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放标识：$a'), findsOneWidget);
      final preview = tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('full-diagnostic-preview')),
          )
          .data!;
      raw = second;
      await tester.tap(find.byTooltip('导出本次播放诊断'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('播放标识：$a'), findsNWidgets(2));
      await tester.tap(find.widgetWithText(FilledButton, '导出'));
      await tester.pump();
      expect(gateway.report?.playbackTraceId, a);
      expect(gateway.report?.content, preview);
      expect(gateway.report?.content, isNot(contains(b)));
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('diagnostic-scope-all')),
            )
            .onSelected,
        isNull,
      );
      gateway.completed.complete(FullDiagnosticShareOutcome.opened);
      await tester.pumpAndSettle();
      expect(find.textContaining('未自动发送。播放标识：$a'), findsOneWidget);
    },
  );

  test('export keeps scope in hashed body and redacts every platform', () async {
    for (final platform in ['Android', 'iPadOS']) {
      final snapshot = PlaybackDiagnosticSnapshot.capture(
        '$first'
        'event=strm_detail trace=$a stage=metadata details={"password":"private-password"}\n',
      );
      var reads = 0;
      final report = await FullDiagnosticExportService(
        readLog: () async {
          reads++;
          return second;
        },
        appVersion: '1.0.195',
        buildNumber: '195',
        platform: platform,
      ).buildReport(snapshot: snapshot);
      expect(reads, 0);
      expect(report.scope, DiagnosticLogScope.currentPlayback);
      expect(report.playbackTraceId, a);
      expect(report.content, contains('scope=currentPlayback trace=$a'));
      expect(report.content, contains('credentialRedaction=credentials-v1'));
      expect(report.content, isNot(contains('private-password')));
      FullDiagnosticExportService.validateSnapshot(report.content);
      expect(
        () => FullDiagnosticExportService.validateSnapshot(
          report.content.replaceFirst('scope=currentPlayback', 'scope=all'),
        ),
        throwsA(isA<FullDiagnosticExportException>()),
      );
    }
  });
}

String _preview(WidgetTester tester) => tester
    .widget<SelectableText>(find.byKey(const ValueKey('diagnostic-preview')))
    .data!;

class _Gateway implements FullDiagnosticShareGateway {
  FullDiagnosticReport? report;
  final completed = Completer<FullDiagnosticShareOutcome>();
  @override
  Future<FullDiagnosticShareOutcome> share(
    FullDiagnosticReport value, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) {
    report = value;
    return completed.future;
  }
}
