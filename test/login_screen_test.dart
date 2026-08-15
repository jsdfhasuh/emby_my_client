import 'dart:async';

import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/models/discovered_server.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selecting a discovered server fills the address field', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LoginScreen(
          controller: AppController(),
          discovery: _FakeDiscovery(),
          capabilities: PlatformCapabilities.android,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Living Room Emby'), findsOneWidget);
    await tester.tap(find.text('Living Room Emby'));
    await tester.pump();

    final serverField = tester.widget<TextFormField>(
      find.byType(TextFormField).first,
    );
    expect(serverField.controller?.text, 'http://192.168.1.20:8096');
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the login page cancels discovery', (tester) async {
    final discovery = _CancellableDiscovery();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LoginScreen(
          controller: AppController(),
          discovery: discovery,
          capabilities: PlatformCapabilities.android,
        ),
      ),
    );
    await tester.pump();

    expect(discovery.cancellation?.isCancelled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(discovery.cancellation?.isCancelled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notFound shows the fixed network guidance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LoginScreen(
          controller: AppController(),
          discovery: _ResultDiscovery(
            const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.notFound),
          ),
          capabilities: _discoveryCapabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('未发现局域网服务器。请确认设备与服务器位于同一网络；若首次使用或曾拒绝权限，请检查系统的“本地网络”设置。'),
      findsOneWidget,
    );
    expect(find.text('本地网络权限已被拒绝'), findsNothing);
  });

  testWidgets('unavailable preserves the previous server while rescanning', (
    tester,
  ) async {
    final discovery = _SequenceDiscovery([
      const EmbyDiscoveryResult(
        status: EmbyDiscoveryStatus.found,
        servers: [
          DiscoveredServer(
            id: 'server-1',
            name: 'Previous Emby',
            address: 'http://192.168.1.20:8096',
          ),
        ],
      ),
      const EmbyDiscoveryResult(
        status: EmbyDiscoveryStatus.unavailable,
        failureKind: EmbyDiscoveryFailureKind.broadcast,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LoginScreen(
          controller: AppController(),
          discovery: discovery,
          capabilities: _discoveryCapabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Previous Emby'), findsOneWidget);

    await tester.tap(find.byTooltip('重新扫描'));
    await tester.pump();
    expect(find.text('正在搜索局域网中的 Emby 服务器…'), findsOneWidget);
    expect(find.text('Previous Emby'), findsOneWidget);

    discovery.completeNext();
    await tester.pumpAndSettle();
    expect(find.text('无法启动局域网扫描，仍可手动输入服务器地址。'), findsOneWidget);
    expect(find.text('Previous Emby'), findsOneWidget);
  });
}

const _discoveryCapabilities = PlatformCapabilities(
  platformName: 'ios',
  embyDeviceName: 'iPadOS',
  supportsAndroidForegroundDownloadExecutor: false,
  supportsLanUdpDiscovery: true,
  supportsPictureInPicture: false,
  supportsLocalNetworkPermissionRecovery: true,
  targetDeviceFamily: 'iPad',
);

class _FakeDiscovery extends EmbyServerDiscovery {
  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async => const EmbyDiscoveryResult(
    status: EmbyDiscoveryStatus.found,
    servers: [
      DiscoveredServer(
        id: 'server-1',
        name: 'Living Room Emby',
        address: 'http://192.168.1.20:8096',
      ),
    ],
  );
}

class _CancellableDiscovery extends EmbyServerDiscovery {
  EmbyDiscoveryCancellation? cancellation;

  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async {
    this.cancellation = cancellation;
    await cancellation?.whenCancelled;
    return const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.cancelled);
  }
}

class _ResultDiscovery extends EmbyServerDiscovery {
  _ResultDiscovery(this.result);

  final EmbyDiscoveryResult result;

  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async => result;
}

class _SequenceDiscovery extends EmbyServerDiscovery {
  _SequenceDiscovery(this._results);

  final List<EmbyDiscoveryResult> _results;
  final List<Completer<EmbyDiscoveryResult>> _pending = [];

  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) {
    final result = _results.removeAt(0);
    if (_results.isNotEmpty) return Future<EmbyDiscoveryResult>.value(result);
    final completer = Completer<EmbyDiscoveryResult>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext() {
    _pending
        .removeAt(0)
        .complete(
          const EmbyDiscoveryResult(
            status: EmbyDiscoveryStatus.unavailable,
            failureKind: EmbyDiscoveryFailureKind.broadcast,
          ),
        );
  }
}
