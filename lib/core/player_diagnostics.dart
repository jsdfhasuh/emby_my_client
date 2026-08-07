import 'diagnostic_log.dart';

enum PlayerDiagnosticEvent {
  playerRouteEnter('player_route_enter'),
  playerPlaybackStarted('player_playback_started'),
  playerCompleted('player_completed'),
  playerExitRequested('player_exit_requested'),
  playerRouteDispose('player_route_dispose'),
  fullscreenOrientationRequested('fullscreen_orientation_requested'),
  fullscreenOrientationApplied('fullscreen_orientation_applied'),
  fullscreenOrientationFailed('fullscreen_orientation_failed'),
  orientationRestoreRequested('orientation_restore_requested'),
  orientationRestoreApplied('orientation_restore_applied'),
  orientationRestoreFailed('orientation_restore_failed'),
  systemUiRestoreRequested('system_ui_restore_requested'),
  systemUiRestoreApplied('system_ui_restore_applied'),
  systemUiRestoreFailed('system_ui_restore_failed'),
  orientationMetricsChanged('orientation_metrics_changed'),
  appLifecycleChanged('app_lifecycle_changed');

  const PlayerDiagnosticEvent(this.code);

  final String code;
}

enum PlayerExitReason {
  userBack('user_back'),
  systemBack('system_back'),
  remoteStop('remote_stop'),
  playbackError('playback_error'),
  completed('completed'),
  routeDisposed('route_disposed'),
  unknown('unknown');

  const PlayerExitReason(this.code);

  final String code;
}

enum PlayerOrientationPolicy {
  landscapePlayback('landscape_playback'),
  systemDefault('system_default'),
  androidPortraitDefault('android_portrait_default');

  const PlayerOrientationPolicy(this.code);

  final String code;
}

enum PlayerDiagnosticErrorType {
  systemUi('SystemUiError'),
  orientation('OrientationError'),
  playback('PlaybackError'),
  unknown('Unknown');

  const PlayerDiagnosticErrorType(this.code);

  final String code;
}

extension PlayerDiagnosticLog on DiagnosticLog {
  void playerEvent({
    required PlayerDiagnosticEvent event,
    PlayerExitReason? exitReason,
    PlayerOrientationPolicy? orientationPolicy,
    double? logicalWidth,
    double? logicalHeight,
    String? lifecycleState,
    PlayerDiagnosticErrorType? errorType,
  }) {
    final fields = <String>[
      'event=${event.code}',
      if (exitReason != null) 'exitReason=${exitReason.code}',
      if (orientationPolicy != null)
        'orientationPolicy=${orientationPolicy.code}',
      if (logicalWidth != null) 'logicalWidth=${_formatMetric(logicalWidth)}',
      if (logicalHeight != null)
        'logicalHeight=${_formatMetric(logicalHeight)}',
      if (lifecycleState != null) 'lifecycleState=$lifecycleState',
      if (errorType != null) 'errorType=${errorType.code}',
    ];
    info('player', fields.join(' '));
  }

  static String _formatMetric(double value) =>
      value.isFinite ? value.toStringAsFixed(2) : '0.00';
}
