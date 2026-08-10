import 'package:flutter/widgets.dart';

import 'playback_diagnostics_test_overrides.dart';

class PlaybackDiagnosticsTestOverridesScope extends InheritedWidget {
  const PlaybackDiagnosticsTestOverridesScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final PlaybackDiagnosticsTestOverridesController controller;

  static PlaybackDiagnosticsTestOverridesController? maybeOf(
    BuildContext context,
  ) => context
      .dependOnInheritedWidgetOfExactType<
        PlaybackDiagnosticsTestOverridesScope
      >()
      ?.controller;

  @override
  bool updateShouldNotify(PlaybackDiagnosticsTestOverridesScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
