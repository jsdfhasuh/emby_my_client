import 'package:flutter/widgets.dart';

import 'playback_settings_repository.dart';

class PlaybackSettingsRepositoryScope extends InheritedWidget {
  const PlaybackSettingsRepositoryScope({
    super.key,
    required this.repository,
    required super.child,
  });

  final PlaybackSettingsRepository repository;

  static PlaybackSettingsRepository of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<PlaybackSettingsRepositoryScope>();
    if (scope == null) {
      throw StateError('PlaybackSettingsRepositoryScope is unavailable');
    }
    return scope.repository;
  }

  @override
  bool updateShouldNotify(PlaybackSettingsRepositoryScope oldWidget) =>
      !identical(repository, oldWidget.repository);
}
