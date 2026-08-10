import 'dart:convert';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/playback/playback_diagnostics_test_overrides.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/ui/diagnostic_log_screen.dart';
import 'package:emby_my_client/ui/playback_acceptance_test_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'overrides are consumed once and logs contain only fixed type names',
    () {
      final lines = <String>[];
      DiagnosticLog.instance.setTestSink(lines.add);
      addTearDown(() => DiagnosticLog.instance.setTestSink(null));
      final controller = PlaybackDiagnosticsTestOverridesController();
      addTearDown(controller.dispose);
      const overrides = PlaybackDiagnosticsTestOverrides(
        streamBufferBytes: 512 << 10,
        sessionTargetBytes: 128 << 20,
        storageSimulation: PlaybackDiagnosticsStorageSimulation.lowSpace,
        injectApprovedSeekFailureAfterNextExecutedSeek: true,
        forceCacheCreateFailureObservation: true,
      );

      controller.enable(overrides);
      final consumed = controller.consumeForPlayback();

      expect(consumed, same(overrides));
      expect(controller.isActive, isFalse);
      expect(controller.consumeForPlayback(), isNull);
      final log = lines.join('\n');
      expect(log, contains('event=playback_test_override_enabled'));
      expect(
        log,
        contains(
          'types=streamBuffer,sessionTarget,storageSimulation,seekFailure,'
          'cacheCreateFailure',
        ),
      );
      expect(log, isNot(contains('itemId')));
      expect(log, isNot(contains('http')));
    },
  );

  test(
    'clear removes pending overrides without persisting into settings',
    () async {
      final storage = _MemorySettingsStorage();
      final repository = PlaybackSettingsRepository(storage: storage);
      final controller = PlaybackDiagnosticsTestOverridesController();
      addTearDown(controller.dispose);
      controller.enable(
        const PlaybackDiagnosticsTestOverrides(streamBufferBytes: 2 << 20),
      );

      await repository.load(_session);
      await repository.patch(
        _session,
        const PlaybackSettingsPatch(playbackRate: 1.5),
      );
      controller.clear();

      expect(controller.isActive, isFalse);
      final persisted =
          jsonDecode(storage.values.single) as Map<String, dynamic>;
      expect(persisted, isNot(contains('testOverrides')));
      expect(persisted, isNot(contains('streamBufferBytes')));
      expect(persisted['playbackRate'], 1.5);
    },
  );

  test('a fresh process controller starts with no test override', () {
    final first = PlaybackDiagnosticsTestOverridesController()
      ..enable(
        const PlaybackDiagnosticsTestOverrides(sessionTargetBytes: 128 << 20),
      );
    final restarted = PlaybackDiagnosticsTestOverridesController();
    addTearDown(first.dispose);
    addTearDown(restarted.dispose);

    expect(first.isActive, isTrue);
    expect(restarted.isActive, isFalse);
  });

  testWidgets(
    'diagnostic page is the only entry to playback acceptance tests',
    (tester) async {
      final controller = PlaybackDiagnosticsTestOverridesController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosticLogScreen(
            capabilities: PlatformCapabilities.android,
            playbackTestOverrides: controller,
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('播放验收测试'), findsOneWidget);
      await tester.tap(find.byTooltip('播放验收测试'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackAcceptanceTestScreen), findsOneWidget);

      await tester.tap(find.text('下一次已执行 Seek 后注入批准故障'));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('enable-playback-test-overrides')),
      );
      await tester.pumpAndSettle();
      expect(find.text('启用播放验收测试？'), findsOneWidget);
      await tester.tap(find.text('确认启用'));
      await tester.pumpAndSettle();

      expect(controller.isActive, isTrue);
      expect(find.text('测试覆盖已启用，将由下一次播放消费'), findsOneWidget);
    },
  );

  testWidgets('acceptance controls have no overflow at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = PlaybackDiagnosticsTestOverridesController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: PlaybackAcceptanceTestScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('playback-test-override-status')),
      findsOneWidget,
    );
  });
}

class _MemorySettingsStorage implements PlaybackSettingsStorage {
  final Map<String, String> byKey = {};

  Iterable<String> get values => byKey.values;

  @override
  Future<String?> read(String key) async => byKey[key];

  @override
  Future<void> write(String key, String value) async => byKey[key] = value;

  @override
  Future<void> delete(String key) async => byKey.remove(key);
}

const _session = EmbySession(
  serverUrl: 'https://example.test',
  serverName: 'Test',
  serverId: 'server',
  userId: 'user',
  username: 'tester',
  accessToken: 'token',
  deviceId: 'device',
);
