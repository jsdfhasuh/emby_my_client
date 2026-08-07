import 'package:flutter/services.dart';

import '../core/diagnostic_log.dart';
import '../core/player_diagnostics.dart';
import '../platform/platform_capabilities.dart';

abstract interface class PlayerSystemUiController {
  Future<void> enterPlayback();

  Future<void> restoreAfterPlayback();
}

abstract interface class PlayerSystemChrome {
  Future<void> setEnabledSystemUIMode(SystemUiMode mode);

  Future<void> setPreferredOrientations(List<DeviceOrientation> orientations);
}

class FlutterPlayerSystemChrome implements PlayerSystemChrome {
  const FlutterPlayerSystemChrome();

  @override
  Future<void> setEnabledSystemUIMode(SystemUiMode mode) =>
      SystemChrome.setEnabledSystemUIMode(mode);

  @override
  Future<void> setPreferredOrientations(List<DeviceOrientation> orientations) =>
      SystemChrome.setPreferredOrientations(orientations);
}

class DefaultPlayerSystemUiController implements PlayerSystemUiController {
  const DefaultPlayerSystemUiController({
    required this.capabilities,
    this.chrome = const FlutterPlayerSystemChrome(),
  });

  final PlatformCapabilities capabilities;
  final PlayerSystemChrome chrome;

  @override
  Future<void> enterPlayback() async {
    Object? firstError;
    try {
      await chrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (error) {
      firstError ??= error;
    }
    try {
      await chrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (error) {
      firstError ??= error;
    }
    if (firstError != null) throw firstError;
  }

  @override
  Future<void> restoreAfterPlayback() async {
    Object? firstError;
    try {
      await chrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (error) {
      firstError ??= error;
    }
    try {
      await chrome.setPreferredOrientations(
        capabilities.platformName == 'ios'
            ? const <DeviceOrientation>[]
            : const [DeviceOrientation.portraitUp],
      );
    } catch (error) {
      firstError ??= error;
    }
    if (firstError != null) throw firstError;
  }
}

class PlayerCloseCoordinator {
  PlayerCloseCoordinator({
    required this.stopPlayback,
    required this.resetBrightness,
    required this.restoreSystemUi,
    required this.popRoute,
    required this.onExitRequested,
    required this.onFailure,
  });

  final Future<void> Function() stopPlayback;
  final Future<void> Function() resetBrightness;
  final Future<void> Function() restoreSystemUi;
  final Future<void> Function() popRoute;
  final void Function(PlayerExitReason reason) onExitRequested;
  final void Function(PlayerDiagnosticErrorType type, Object error) onFailure;

  Future<void>? _operation;

  bool get isClosing => _operation != null;

  Future<void> close(PlayerExitReason reason) {
    final existing = _operation;
    if (existing != null) return existing;
    final operation = _close(reason);
    _operation = operation;
    return operation;
  }

  Future<void> _close(PlayerExitReason reason) async {
    try {
      onExitRequested(reason);
    } catch (error) {
      _reportFailure(PlayerDiagnosticErrorType.unknown, error);
    }
    try {
      await _runSafely(stopPlayback, PlayerDiagnosticErrorType.playback);
      await _runSafely(resetBrightness, PlayerDiagnosticErrorType.systemUi);
      await _runSafely(restoreSystemUi, PlayerDiagnosticErrorType.orientation);
    } finally {
      try {
        await popRoute();
      } catch (error) {
        _reportFailure(PlayerDiagnosticErrorType.unknown, error);
      }
    }
  }

  Future<void> _runSafely(
    Future<void> Function() operation,
    PlayerDiagnosticErrorType errorType,
  ) async {
    try {
      await operation();
    } catch (error) {
      _reportFailure(errorType, error);
    }
  }

  void _reportFailure(PlayerDiagnosticErrorType type, Object error) {
    try {
      onFailure(type, error);
    } catch (_) {
      // A diagnostic callback must not prevent the route from closing.
    }
  }
}

void logPlayerFailure(PlayerDiagnosticErrorType errorType, Object error) {
  try {
    DiagnosticLog.instance.playerEvent(
      event: switch (errorType) {
        PlayerDiagnosticErrorType.systemUi =>
          PlayerDiagnosticEvent.systemUiRestoreFailed,
        PlayerDiagnosticErrorType.orientation =>
          PlayerDiagnosticEvent.orientationRestoreFailed,
        PlayerDiagnosticErrorType.playback ||
        PlayerDiagnosticErrorType.unknown =>
          PlayerDiagnosticEvent.playerRouteDispose,
      },
      errorType: errorType,
    );
    DiagnosticLog.instance.error(
      'player',
      'Player close operation failed',
      error: error,
    );
  } catch (_) {
    // Diagnostics must never block player shutdown.
  }
}
