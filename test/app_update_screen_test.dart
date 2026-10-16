import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:emby_my_client/ui/app_update_screen.dart';
import 'package:emby_my_client/updates/app_update.dart';
import 'package:emby_my_client/updates/update_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_update_test.dart' as fixtures show releaseJson, installed;

class Download extends VerifiedDownload {
  Download() : super(File('unused/update.apk'), 'a' * 64, 4, 180);
  bool discarded = false;
  @override
  Future<void> discard() async {
    discarded = true;
  }
}

class Source implements UpdateSource {
  int checks = 0;
  int downloads = 0;
  AppRelease release = AppRelease.parse(fixtures.releaseJson());
  final value = Download();
  Completer<AppRelease>? pending;
  bool cancelDownload = false;
  @override
  Future<AppRelease> latest(CancelToken cancel) async {
    checks++;
    return pending?.future ?? release;
  }

  @override
  Future<VerifiedDownload> download(
    AppRelease release,
    ReleaseAsset asset,
    CancelToken cancel,
    void Function(int, int) progress,
  ) async {
    downloads++;
    progress(1, 4);
    if (cancelDownload) {
      await cancel.whenCancel;
      throw const UpdateFailure('cancelled');
    }
    return value;
  }

  @override
  void close() {}
}

class Gateway implements UpdateGateway {
  InstalledApp app = fixtures.installed;
  final calls = <String>[];
  String? rejection;
  InstallHandoff result = InstallHandoff.opened;
  @override
  Future<InstalledApp> installed() async => app;
  @override
  Future<void> validate(VerifiedDownload download) async {
    calls.add('validate');
    if (rejection != null) throw UpdateFailure(rejection!);
  }

  @override
  Future<InstallHandoff> install(VerifiedDownload download) async {
    calls.add('install');
    return result;
  }

  @override
  Future<void> allowInstalls() async {
    calls.add('settings');
  }
}

void main() {
  test('release summary is bounded and preserves a complete-notes source', () {
    final notes =
        '# Release\n\n- Fix subtitle selection\n* Improve seek\n'
        '- ${'长' * 200}\n- Fourth change';
    final summary = releaseChangelogSummary(notes);
    expect(summary, startsWith('Fix subtitle selection\nImprove seek\n'));
    expect(summary, isNot(contains('# Release')));
    expect(summary, isNot(contains('Fourth change')));
    expect(summary.split('\n').last.runes.length, 161);
  });

  late Source source;
  late Gateway gateway;
  setUp(() {
    source = Source();
    gateway = Gateway();
  });
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppUpdateScreen(source: source, gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('shows installed version and never checks automatically', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('1.0.179'), findsOneWidget);
    expect(find.textContaining('1792000'), findsOneWidget);
    expect(source.checks, 0);
    expect(find.text('最新版本：尚未检查'), findsOneWidget);
    expect(find.textContaining('已安装版本 1.0.179'), findsOneWidget);
    await tap(tester, 'check-update');
    expect(source.checks, 1);
    expect(find.text('最新公开版本：1.0.180（build-180）'), findsOneWidget);
    expect(find.text('更新摘要'), findsOneWidget);
    expect(find.text('A public release'), findsOneWidget);
    expect(find.byKey(const ValueKey('install-update')), findsNothing);
  });

  testWidgets('does not offer same or older version', (tester) async {
    source.release = AppRelease.parse(fixtures.releaseJson(number: 178));
    await pump(tester);
    await tap(tester, 'check-update');
    expect(find.text('当前已是最新版本。'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-update')), findsNothing);
  });

  testWidgets('duplicate check taps issue one request; errors can retry', (
    tester,
  ) async {
    source.pending = Completer<AppRelease>();
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pump();
    expect(source.checks, 1);
    source.pending!.completeError(const UpdateFailure('network'));
    await tester.pumpAndSettle();
    expect(find.text(const UpdateFailure('network').message), findsOneWidget);
    source.pending = null;
    await tap(tester, 'check-update');
    expect(source.checks, 2);
  });

  testWidgets(
    'verification precedes explicit installer handoff; never claims success',
    (tester) async {
      await pump(tester);
      await tap(tester, 'check-update');
      await tap(tester, 'download-update');
      expect(gateway.calls, ['validate']);
      expect(find.text('校验通过，等待你确认安装。'), findsOneWidget);
      await tap(tester, 'install-update');
      expect(gateway.calls, ['validate', 'install']);
      expect(find.textContaining('是否完成安装，以系统结果为准'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(source.value.discarded, isFalse);
    },
  );

  for (final code in [
    'signature',
    'downgrade',
    'package',
    'unsupported',
    'checksum',
  ]) {
    testWidgets('$code rejection removes download and blocks installation', (
      tester,
    ) async {
      gateway.rejection = code;
      await pump(tester);
      await tap(tester, 'check-update');
      await tap(tester, 'download-update');
      expect(find.text(UpdateFailure(code).message), findsOneWidget);
      expect(source.value.discarded, isTrue);
      expect(find.byKey(const ValueKey('install-update')), findsNothing);
      expect(gateway.calls, ['validate']);
    });
  }

  testWidgets(
    'permission settings need explicit tap and return needs another install tap',
    (tester) async {
      gateway.result = InstallHandoff.permissionRequired;
      await pump(tester);
      await tap(tester, 'check-update');
      await tap(tester, 'download-update');
      await tap(tester, 'install-update');
      expect(gateway.calls, ['validate', 'install']);
      await tester.ensureVisible(find.text('允许此应用安装更新'));
      await tester.tap(find.text('允许此应用安装更新'));
      await tester.pumpAndSettle();
      expect(gateway.calls, ['validate', 'install', 'settings']);
      gateway.result = InstallHandoff.opened;
      await tap(tester, 'install-update');
      expect(gateway.calls.last, 'install');
    },
  );

  testWidgets(
    'download progress, duplicate protection, cancellation and retry',
    (tester) async {
      source.cancelDownload = true;
      await pump(tester);
      await tap(tester, 'check-update');
      await tester.ensureVisible(find.byKey(const ValueKey('download-update')));
      await tester.tap(find.byKey(const ValueKey('download-update')));
      await tester.pump();
      expect(source.downloads, 1);
      expect(find.text('下载中 25%'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('download-update')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('download-update')))
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.text('取消'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        find.text(const UpdateFailure('cancelled').message),
        findsOneWidget,
      );
      expect(gateway.calls, isEmpty);
      source.cancelDownload = false;
      await tap(tester, 'download-update');
      expect(source.downloads, 2);
    },
  );

  testWidgets('iOS offers manual TrollStore guidance and no APK installer', (
    tester,
  ) async {
    gateway.app = const InstalledApp(
      version: '1.0.179',
      buildNumber: 179,
      platform: UpdatePlatform.ios,
    );
    await pump(tester);
    await tap(tester, 'check-update');
    expect(find.textContaining('TrollStore'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-update')), findsNothing);
    expect(find.byKey(const ValueKey('install-update')), findsNothing);
    expect(find.text('复制发布页链接'), findsOneWidget);
  });

  testWidgets(
    'small screen and large text remain scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
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
          home: AppUpdateScreen(source: source, gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'check-update');
      await tap(tester, 'download-update');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('entry displays native version and opens the about screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateEntry(gateway: gateway)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1.0.179 · 构建 1792000'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateScreen), findsOneWidget);
  });
}
