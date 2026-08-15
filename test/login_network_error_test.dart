import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iPadOS private-network failure gives a retryable hint', (
    tester,
  ) async {
    final controller = _FailingController(
      const EmbyApiException(
        '无法连接 Emby 服务器，请检查地址和网络',
        serverUrl: 'http://192.168.1.20:8096',
        isConnectionFailure: true,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(
      tester,
      controller,
      PlatformCapabilities.ipad,
      '192.168.1.20:8096',
    );

    expect(
      find.text('无法访问局域网服务器。请确认已在“设置 → 隐私与安全性 → 本地网络”中允许本应用，然后重试。'),
      findsOneWidget,
    );
    expect(controller.calls, 1);

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(controller.calls, 2);
  });

  testWidgets('Android private-network failure keeps the existing message', (
    tester,
  ) async {
    final controller = _FailingController(
      const EmbyApiException(
        '无法连接 Emby 服务器，请检查地址和网络',
        serverUrl: 'http://192.168.1.20:8096',
        isConnectionFailure: true,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(
      tester,
      controller,
      PlatformCapabilities.android,
      '192.168.1.20:8096',
    );

    expect(find.text('无法连接 Emby 服务器，请检查地址和网络'), findsOneWidget);
    expect(find.textContaining('本地网络'), findsNothing);
  });

  testWidgets('public iPadOS connection failure is not a local hint', (
    tester,
  ) async {
    final controller = _FailingController(
      const EmbyApiException(
        '无法连接 Emby 服务器，请检查地址和网络',
        serverUrl: 'https://emby.example.com',
        isConnectionFailure: true,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(
      tester,
      controller,
      PlatformCapabilities.ipad,
      'https://emby.example.com',
    );

    expect(find.text('无法连接 Emby 服务器，请检查地址和网络'), findsOneWidget);
    expect(find.textContaining('本地网络'), findsNothing);
  });
}

Future<void> _submit(
  WidgetTester tester,
  _FailingController controller,
  PlatformCapabilities capabilities,
  String server,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: LoginScreen(
        controller: controller,
        capabilities: capabilities,
        discovery: _EmptyDiscovery(),
      ),
    ),
  );
  await tester.pump();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), server);
  await tester.enterText(fields.at(1), 'tester');
  await tester.enterText(fields.at(2), 'password');
  await tester.tap(find.text('登录'));
  await tester.pumpAndSettle();
}

class _EmptyDiscovery extends EmbyServerDiscovery {
  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async => const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.notFound);
}

class _FailingController extends AppController {
  _FailingController(this.failure)
    : super(capabilities: PlatformCapabilities.android);

  final EmbyApiException failure;
  int calls = 0;

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    calls++;
    throw failure;
  }
}
