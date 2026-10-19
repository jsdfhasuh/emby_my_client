import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_connection.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/downloads/download_connection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

void main() {
  testWidgets('small Android layout and large text remain usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('VisualQA')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final key = GlobalKey();
    final manager = _Manager()
      ..settings = DownloadConnectionSettings(
        mode: DownloadConnectionMode.hysteria2,
        profile: Hysteria2Profile.parse(
          'hy2://fixture-password@oracle.example.test'
          '?sni=oracle.example.test&obfs=salamander&obfs-password=fixture-obfs',
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'VisualQA', useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: key,
          child: DownloadConnectionScreen(session: _session, manager: manager),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('download-connection-test')),
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/test-artifacts').create(recursive: true);
      await File(
        'build/test-artifacts/download-connection-android.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('import clears credential input and save is explicit', (
    tester,
  ) async {
    final manager = _Manager();
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadConnectionScreen(session: _session, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('普通连接'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('download-connection-link')),
      'hy2://fixture-password@example.test?sni=cert.test',
    );
    await tester.tap(find.byKey(const ValueKey('download-connection-import')));
    await tester.pumpAndSettle();
    expect(find.text('example.test:443'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('download-connection-link')),
    );
    expect(field.controller!.text, isEmpty);
    expect(field.obscureText, isTrue);
    expect(manager.saved, isNull);
    await tester.tap(find.text('Hysteria2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-connection-save')));
    await tester.pumpAndSettle();
    expect(manager.saved!.mode, DownloadConnectionMode.hysteria2);
    expect(manager.saved!.profile!.auth, 'fixture-password');
    expect(find.textContaining('fixture-password'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('busy download prevents edits, tests and save', (tester) async {
    final manager = _Manager()..busy = true;
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadConnectionScreen(session: _session, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('download-connection-save')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('download-connection-link')),
          )
          .enabled,
      isFalse,
    );
    expect(find.textContaining('暂停下载'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reports handshake separately from failed Emby access', (
    tester,
  ) async {
    final manager = _Manager()
      ..settings = DownloadConnectionSettings(
        profile: Hysteria2Profile.parse('hy2://fixture-password@example.test'),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadConnectionScreen(session: _session, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('download-connection-test')),
    );
    await tester.tap(find.byKey(const ValueKey('download-connection-test')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Emby 访问'));
    expect(find.text('Hysteria2 握手'), findsOneWidget);
    expect(find.textContaining('成功'), findsOneWidget);
    expect(find.textContaining('失败'), findsOneWidget);
    expect(manager.tests, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('delete clears stored profile and returns to direct mode', (
    tester,
  ) async {
    final manager = _Manager()
      ..settings = DownloadConnectionSettings(
        mode: DownloadConnectionMode.hysteria2,
        profile: Hysteria2Profile.parse('hy2://fixture-password@example.test'),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadConnectionScreen(session: _session, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-connection-delete')));
    await tester.pumpAndSettle();
    expect(manager.deleted, isTrue);
    expect(find.text('example.test:443'), findsNothing);
    expect(find.textContaining('配置已删除'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

const _session = EmbySession(
  serverUrl: 'https://emby.test',
  serverName: 'fixture',
  serverId: 'server',
  userId: 'user',
  username: 'fixture',
  accessToken: 'fixture',
  deviceId: 'device',
);

class _Manager extends DownloadConnectionManager {
  _Manager() : super(supportedOverride: true);
  DownloadConnectionSettings settings = const DownloadConnectionSettings();
  DownloadConnectionSettings? saved;
  bool busy = false, deleted = false;
  int tests = 0;
  @override
  Future<DownloadConnectionSettings> load(ServerScope scope) async => settings;
  @override
  Future<DownloadConnectionStatus> status() async =>
      DownloadConnectionStatus(downloads: busy ? 1 : 0);
  @override
  Future<void> save(ServerScope scope, DownloadConnectionSettings value) async {
    saved = value;
    settings = value;
  }

  @override
  Future<void> delete(ServerScope scope) async {
    deleted = true;
  }

  @override
  Future<DownloadConnectionTestResult> test(
    EmbySession session,
    Hysteria2Profile profile,
  ) async {
    tests++;
    return const DownloadConnectionTestResult(
      handshakeSucceeded: true,
      serverReachable: false,
      handshakeTime: Duration(milliseconds: 100),
    );
  }
}
