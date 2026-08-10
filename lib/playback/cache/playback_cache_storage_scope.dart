import 'package:flutter/widgets.dart';

import 'playback_cache_storage.dart';

class PlaybackCacheStorageScope extends InheritedWidget {
  const PlaybackCacheStorageScope({
    super.key,
    required this.storage,
    required super.child,
  });

  final PlaybackCacheStorage storage;

  static PlaybackCacheStorage of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<PlaybackCacheStorageScope>();
    if (scope == null) {
      throw StateError('PlaybackCacheStorageScope is unavailable');
    }
    return scope.storage;
  }

  @override
  bool updateShouldNotify(PlaybackCacheStorageScope oldWidget) =>
      !identical(storage, oldWidget.storage);
}
