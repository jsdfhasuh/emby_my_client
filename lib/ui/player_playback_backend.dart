import 'package:flutter/widgets.dart';

import '../playback/playback_engine.dart';

/// Keeps the native engine and its video surface together. Tests can replace
/// only this boundary while exercising the actual screen and controller.
class PlayerPlaybackBackend {
  const PlayerPlaybackBackend({required this.engine, required this.buildVideo});

  final PlaybackEngine engine;
  final Widget Function(BoxFit fit) buildVideo;
}

class PlayerPlaybackBackendScope extends InheritedWidget {
  const PlayerPlaybackBackendScope({
    super.key,
    required this.create,
    required super.child,
  });

  final PlayerPlaybackBackend Function() create;

  // A backend is owned for the lifetime of the route, not rebuilt on changes.
  static PlayerPlaybackBackend Function()? maybeFactory(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<PlayerPlaybackBackendScope>()
          ?.create;

  @override
  bool updateShouldNotify(PlayerPlaybackBackendScope oldWidget) => false;
}
