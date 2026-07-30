import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback settings round-trip all persisted controls', () {
    const settings = PlaybackSettings(
      maxStreamingBitrate: 10000000,
      seekBackwardSeconds: 15,
      seekForwardSeconds: 30,
      playbackRate: 1.5,
      videoFit: 'cover',
      subtitleDelayMilliseconds: 500,
      audioDelayMilliseconds: -500,
      subtitleFontSize: 52,
      subtitleColor: 0xFFFFFF00,
      subtitleOutlineColor: 0xFF101010,
      subtitlePosition: 88,
    );

    final restored = PlaybackSettings.fromJson(settings.toJson());

    expect(restored.maxStreamingBitrate, 10000000);
    expect(restored.seekBackwardSeconds, 15);
    expect(restored.seekForwardSeconds, 30);
    expect(restored.playbackRate, 1.5);
    expect(restored.videoFit, 'cover');
    expect(restored.subtitleDelayMilliseconds, 500);
    expect(restored.audioDelayMilliseconds, -500);
    expect(restored.subtitleFontSize, 52);
    expect(restored.subtitleColor, 0xFFFFFF00);
    expect(restored.subtitleOutlineColor, 0xFF101010);
    expect(restored.subtitlePosition, 88);
  });
}
