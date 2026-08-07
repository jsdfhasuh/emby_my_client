import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/core/player_diagnostics.dart';
import 'package:emby_my_client/ui/player_system_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iPad playback enters immersive landscape in order', () async {
    final chrome = _FakePlayerSystemChrome();
    final controller = DefaultPlayerSystemUiController(
      capabilities: PlatformCapabilities.ipad,
      chrome: chrome,
    );

    await controller.enterPlayback();

    expect(chrome.operations, [
      'ui:${SystemUiMode.immersiveSticky}',
      'orient:landscapeLeft,landscapeRight',
    ]);
  });

  test(
    'iPad playback restores edge-to-edge and system default orientation',
    () async {
      final chrome = _FakePlayerSystemChrome();
      final controller = DefaultPlayerSystemUiController(
        capabilities: PlatformCapabilities.ipad,
        chrome: chrome,
      );

      await controller.restoreAfterPlayback();

      expect(chrome.operations, ['ui:${SystemUiMode.edgeToEdge}', 'orient:']);
    },
  );

  test(
    'Android playback keeps the existing portrait default restoration',
    () async {
      final chrome = _FakePlayerSystemChrome();
      final controller = DefaultPlayerSystemUiController(
        capabilities: PlatformCapabilities.android,
        chrome: chrome,
      );

      await controller.restoreAfterPlayback();

      expect(chrome.operations, [
        'ui:${SystemUiMode.edgeToEdge}',
        'orient:portraitUp',
      ]);
    },
  );

  test(
    'restore still attempts orientation after a system UI failure',
    () async {
      final chrome = _FakePlayerSystemChrome()..failUi = true;
      final controller = DefaultPlayerSystemUiController(
        capabilities: PlatformCapabilities.ipad,
        chrome: chrome,
      );

      await expectLater(controller.restoreAfterPlayback(), throwsStateError);
      expect(chrome.operations, ['ui:${SystemUiMode.edgeToEdge}', 'orient:']);
    },
  );

  test(
    'close is single-flight and pops once after all restoration steps',
    () async {
      final calls = <String>[];
      final coordinator = PlayerCloseCoordinator(
        stopPlayback: () async => calls.add('stop'),
        resetBrightness: () async => calls.add('brightness'),
        restoreSystemUi: () async => calls.add('system-ui'),
        popRoute: () async => calls.add('pop'),
        onExitRequested: (reason) => calls.add('exit:${reason.code}'),
        onFailure: (type, error) => calls.add('failure:${type.code}'),
      );

      final first = coordinator.close(PlayerExitReason.userBack);
      final second = coordinator.close(PlayerExitReason.remoteStop);
      await Future.wait([first, second]);

      expect(calls, [
        'exit:user_back',
        'stop',
        'brightness',
        'system-ui',
        'pop',
      ]);
    },
  );

  test(
    'restore failures still pop and do not escape the close future',
    () async {
      final calls = <String>[];
      final coordinator = PlayerCloseCoordinator(
        stopPlayback: () async => calls.add('stop'),
        resetBrightness: () async => throw StateError('brightness fixture'),
        restoreSystemUi: () async => throw StateError('orientation fixture'),
        popRoute: () async => calls.add('pop'),
        onExitRequested: (reason) => calls.add('exit:${reason.code}'),
        onFailure: (type, error) => calls.add('failure:${type.code}'),
      );

      await coordinator.close(PlayerExitReason.playbackError);

      expect(calls, [
        'exit:playback_error',
        'stop',
        'failure:SystemUiError',
        'failure:OrientationError',
        'pop',
      ]);
    },
  );

  test('diagnostic callback failure cannot block route close', () async {
    final calls = <String>[];
    final coordinator = PlayerCloseCoordinator(
      stopPlayback: () async => calls.add('stop'),
      resetBrightness: () async => throw StateError('brightness fixture'),
      restoreSystemUi: () async => calls.add('system-ui'),
      popRoute: () async => calls.add('pop'),
      onExitRequested: (reason) => calls.add('exit:${reason.code}'),
      onFailure: (_, _) => throw StateError('diagnostic fixture'),
    );

    await coordinator.close(PlayerExitReason.userBack);

    expect(calls, ['exit:user_back', 'stop', 'system-ui', 'pop']);
  });
}

class _FakePlayerSystemChrome implements PlayerSystemChrome {
  final operations = <String>[];
  bool failUi = false;
  bool failOrientation = false;

  @override
  Future<void> setEnabledSystemUIMode(SystemUiMode mode) async {
    operations.add('ui:$mode');
    if (failUi) throw StateError('system UI fixture');
  }

  @override
  Future<void> setPreferredOrientations(
    List<DeviceOrientation> orientations,
  ) async {
    operations.add(
      'orient:${orientations.map((value) => value.name).join(',')}',
    );
    if (failOrientation) throw StateError('orientation fixture');
  }
}
