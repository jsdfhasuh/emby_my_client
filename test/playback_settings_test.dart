import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/horizontal_scrub_mapping.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/seek_preview_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback settings round-trip all persisted controls', () {
    const settings = PlaybackSettings(
      maxStreamingBitrate: 10000000,
      seekBackwardSeconds: 15,
      seekForwardSeconds: 30,
      horizontalSwipeSeekSpanSeconds: 600,
      seekPreviewMode: SeekPreviewMode.serverOnly,
      playbackRate: 1.5,
      videoFit: 'cover',
      subtitleDelayMilliseconds: 500,
      audioDelayMilliseconds: -500,
      subtitleFontSize: 52,
      subtitleColor: 0xFFFFFF00,
      subtitleOutlineColor: 0xFF101010,
      subtitlePosition: 88,
      cache: PlaybackCacheSettings(
        mode: PlaybackCacheMode.custom,
        customForwardSeconds: 240,
        customBackwardSeconds: 90,
        customSessionTargetBytes: 768 * 1024 * 1024,
        reservedFreeBytes: 3 * 1024 * 1024 * 1024,
      ),
    );

    final restored = PlaybackSettings.fromJson(settings.toJson());

    expect(restored.maxStreamingBitrate, 10000000);
    expect(restored.seekBackwardSeconds, 15);
    expect(restored.seekForwardSeconds, 30);
    expect(restored.horizontalSwipeSeekSpanSeconds, 600);
    expect(restored.seekPreviewMode, SeekPreviewMode.serverOnly);
    expect(restored.playbackRate, 1.5);
    expect(restored.videoFit, 'cover');
    expect(restored.subtitleDelayMilliseconds, 500);
    expect(restored.audioDelayMilliseconds, -500);
    expect(restored.subtitleFontSize, 52);
    expect(restored.subtitleColor, 0xFFFFFF00);
    expect(restored.subtitleOutlineColor, 0xFF101010);
    expect(restored.subtitlePosition, 88);
    expect(restored.cache.mode, PlaybackCacheMode.custom);
    expect(restored.cache.customForwardSeconds, 240);
    expect(restored.cache.customBackwardSeconds, 90);
    expect(restored.cache.customSessionTargetBytes, 768 * 1024 * 1024);
    expect(restored.cache.reservedFreeBytes, 3 * 1024 * 1024 * 1024);
  });

  test('old v1 settings without cache migrate to automatic defaults', () {
    final restored = PlaybackSettings.fromJson({
      'maxStreamingBitrate': 10000000,
      'playbackRate': 1.5,
      'videoFit': 'cover',
    });

    expect(restored.maxStreamingBitrate, 10000000);
    expect(restored.playbackRate, 1.5);
    expect(restored.videoFit, 'cover');
    expect(
      restored.horizontalSwipeSeekSpanSeconds,
      defaultHorizontalSwipeSeekSpanSeconds,
    );
    expect(restored.seekPreviewMode, SeekPreviewMode.automatic);
    expect(restored.cache.mode, PlaybackCacheMode.automatic);
    expect(
      restored.cache.customSessionTargetBytes,
      PlaybackCacheSettings.defaultSessionTargetBytes,
    );
  });

  test('damaged cache only falls back the cache field', () {
    final restored = PlaybackSettings.fromJson({
      'maxStreamingBitrate': 7000000,
      'playbackRate': 1.25,
      'subtitleFontSize': 50,
      'cache': <Object?>['not', 'an', 'object'],
    });

    expect(restored.maxStreamingBitrate, 7000000);
    expect(restored.playbackRate, 1.25);
    expect(restored.subtitleFontSize, 50);
    expect(restored.cache.mode, PlaybackCacheMode.automatic);
  });

  test(
    'cache deserialization rejects modes and clamps every numeric field',
    () {
      final low = PlaybackCacheSettings.fromJsonValue({
        'mode': 'not-a-mode',
        'forwardSeconds': -1,
        'backwardSeconds': '-20',
        'sessionTargetBytes': 1,
        'reservedFreeBytes': 100,
        'unknown': 'ignored',
      });
      final high = PlaybackCacheSettings.fromJsonValue({
        'mode': 'aggressive',
        'forwardSeconds': 901,
        'backwardSeconds': 601.9,
        'sessionTargetBytes': 5 * 1024 * 1024 * 1024,
        'reservedFreeBytes': 9 * 1024 * 1024 * 1024,
      });

      expect(low.mode, PlaybackCacheMode.automatic);
      expect(low.customForwardSeconds, PlaybackCacheSettings.minForwardSeconds);
      expect(
        low.customBackwardSeconds,
        PlaybackCacheSettings.minBackwardSeconds,
      );
      expect(
        low.customSessionTargetBytes,
        PlaybackCacheSettings.minSessionTargetBytes,
      );
      expect(low.reservedFreeBytes, PlaybackCacheSettings.minReservedFreeBytes);
      expect(high.mode, PlaybackCacheMode.aggressive);
      expect(
        high.customForwardSeconds,
        PlaybackCacheSettings.maxForwardSeconds,
      );
      expect(
        high.customBackwardSeconds,
        PlaybackCacheSettings.maxBackwardSeconds,
      );
      expect(
        high.customSessionTargetBytes,
        PlaybackCacheSettings.maxSessionTargetBytes,
      );
      expect(
        high.reservedFreeBytes,
        PlaybackCacheSettings.maxReservedFreeBytes,
      );
    },
  );

  test('all cache modes use stable serialized names', () {
    for (final mode in PlaybackCacheMode.values) {
      final restored = PlaybackCacheSettings.fromJsonValue(
        PlaybackCacheSettings(mode: mode).toJson(),
      );
      expect(restored.mode, mode);
    }
  });

  test('invalid scrub settings recover to safe defaults', () {
    final restored = PlaybackSettings.fromJson({
      'horizontalSwipeSeekSpanSeconds': 91,
      'seekPreviewMode': 'unknown',
    });

    expect(
      restored.horizontalSwipeSeekSpanSeconds,
      defaultHorizontalSwipeSeekSpanSeconds,
    );
    expect(restored.seekPreviewMode, SeekPreviewMode.automatic);

    const directlyConstructed = PlaybackSettings(
      horizontalSwipeSeekSpanSeconds: 91,
    );
    expect(
      directlyConstructed.toJson()['horizontalSwipeSeekSpanSeconds'],
      defaultHorizontalSwipeSeekSpanSeconds,
    );
  });

  test('scrub settings copyWith normalizes the span and changes the mode', () {
    const settings = PlaybackSettings(
      horizontalSwipeSeekSpanSeconds: 30,
      seekPreviewMode: SeekPreviewMode.off,
    );

    final normalized = settings.copyWith(horizontalSwipeSeekSpanSeconds: 999);
    expect(
      normalized.horizontalSwipeSeekSpanSeconds,
      defaultHorizontalSwipeSeekSpanSeconds,
    );
    expect(normalized.seekPreviewMode, SeekPreviewMode.off);

    final changed = settings.copyWith(
      horizontalSwipeSeekSpanSeconds: 300,
      seekPreviewMode: SeekPreviewMode.serverOnly,
    );
    expect(changed.horizontalSwipeSeekSpanSeconds, 300);
    expect(changed.seekPreviewMode, SeekPreviewMode.serverOnly);
  });

  test('all seek preview modes use stable serialized names', () {
    for (final mode in SeekPreviewMode.values) {
      final restored = PlaybackSettings.fromJson(
        PlaybackSettings(seekPreviewMode: mode).toJson(),
      );
      expect(restored.seekPreviewMode, mode);
    }
  });

  test('full read-ahead mode round-trips without changing defaults', () {
    const settings = PlaybackSettings(
      cache: PlaybackCacheSettings(mode: PlaybackCacheMode.fullReadAhead),
    );

    final restored = PlaybackSettings.fromJson(settings.toJson());

    expect(restored.cache.mode, PlaybackCacheMode.fullReadAhead);
    expect(restored.maxStreamingBitrate, 120000000);
    expect(restored.cache.customForwardSeconds, 180);
    expect(restored.cache.customBackwardSeconds, 120);
  });
}
