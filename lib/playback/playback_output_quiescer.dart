import 'package:media_kit/media_kit.dart';

import 'playback_output_quiescer_platform.dart'
    if (dart.library.io) 'playback_output_quiescer_platform_native.dart'
    as platform;

abstract interface class PlaybackOutputQuiescer {
  Future<void> pauseUrgently();
}

class MediaKitPlaybackOutputQuiescer implements PlaybackOutputQuiescer {
  const MediaKitPlaybackOutputQuiescer(this.player);

  final Player player;

  @override
  Future<void> pauseUrgently() => platform.pauseMediaKitOutputUrgently(player);
}
