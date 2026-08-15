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
}

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
