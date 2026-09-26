import 'package:media_kit/media_kit.dart';

Future<void> pauseMediaKitOutputUrgently(Player player) {
  final platform = player.platform;
  if (platform is NativePlayer) {
    // This lock-bypassing command is reserved for immediately silencing the
    // current audio output. Normal controls keep media_kit's default
    // serialization, and late open/play/seek completions reassert pause again.
    return platform.pause(synchronized: false);
  }
  return player.pause();
}
