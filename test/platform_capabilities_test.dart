import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/downloads/foreground_download_executor.dart';
import 'package:emby_my_client/downloads/download_executor.dart';
import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/playback/picture_in_picture.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('existing device ids remain stable when the platform changes', () async {
    final storage = _MemorySessionStorage()
      ..values['emby_device_id_v1'] = 'emby-android-existing';

    final deviceId = await SessionStore(
      sessionStorage: storage,
      capabilities: PlatformCapabilities.ipad,
    ).getOrCreateDeviceId();

    expect(deviceId, 'emby-android-existing');
  });

  test('new device ids use the platform prefix', () async {
    final storage = _MemorySessionStorage();

    final deviceId = await SessionStore(
      sessionStorage: storage,
      capabilities: PlatformCapabilities.ipad,
    ).getOrCreateDeviceId();

    expect(deviceId, startsWith('emby-ios-'));
  });

  test('Android capabilities keep the existing platform behaviors', () {
    expect(PlatformCapabilities.android.platformName, 'android');
    expect(PlatformCapabilities.android.embyDeviceName, 'Android');
    expect(
      PlatformCapabilities.android.supportsAndroidForegroundDownloadExecutor,
      isTrue,
    );
    expect(PlatformCapabilities.android.supportsLanUdpDiscovery, isTrue);
    expect(PlatformCapabilities.android.supportsPictureInPicture, isTrue);
    expect(
      PlatformCapabilities.android.supportsLocalNetworkPermissionRecovery,
      isFalse,
    );
    expect(PlatformCapabilities.android.deviceIdPrefix, 'emby-android-');
  });

  test('iPadOS uses its own Emby device display name and UDP capability', () {
    expect(PlatformCapabilities.ipad.embyDeviceName, 'iPadOS');
    expect(PlatformCapabilities.ipad.supportsLanUdpDiscovery, isTrue);
    expect(
      PlatformCapabilities.ipad.supportsLocalNetworkPermissionRecovery,
      isTrue,
    );
  });

  test(
    'iPad foreground executor never registers the Android callback',
    () async {
      final executor = ForegroundDownloadExecutor(
        capabilities: PlatformCapabilities.ipad,
      );

      expect(await executor.isRunning, isFalse);
      await executor.start();
      await executor.send(DownloadExecutorCommand.wake);
      await executor.stop();
      await executor.dispose();
    },
  );

  test('unsupported iPad PiP channel is a safe no-op', () async {
    final controller = PictureInPictureController(
      capabilities: PlatformCapabilities.ipad,
      onToggle: () async {},
      onClose: () {},
    );

    await controller.initialize();
    expect(await controller.isSupported, isFalse);
    await controller.updatePlaying(true);
    expect(await controller.enter(isPlaying: true), isFalse);
    controller.dispose();
  });

  testWidgets('iPad login starts UDP discovery', (tester) async {
    final discovery = _SpyDiscovery();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LoginScreen(
          controller: AppController(),
          discovery: discovery,
          capabilities: PlatformCapabilities.ipad,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(discovery.calls, 1);
    expect(find.text('局域网服务器'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
  });
}

class _MemorySessionStorage implements SessionStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _SpyDiscovery extends EmbyServerDiscovery {
  int calls = 0;

  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async {
    calls++;
    return const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.notFound);
  }
}
