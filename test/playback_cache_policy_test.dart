import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_option_bindings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transport classification', () {
    test('classifies offline, progressive, segmented, live, and unknown', () {
      expect(
        _transport(uri: Uri.file('/offline/video.mp4')),
        PlaybackTransportKind.offlineLocal,
      );
      expect(
        _transport(uri: Uri.https('media.test', '/video.mp4')),
        PlaybackTransportKind.progressiveHttp,
      );
      expect(
        _transport(
          uri: Uri.https('media.test', '/master.m3u8'),
          container: 'm3u8',
        ),
        PlaybackTransportKind.segmentedHttp,
      );
      expect(
        _transport(
          uri: Uri.https('media.test', '/stream'),
          method: PlayMethod.transcode,
        ),
        PlaybackTransportKind.segmentedHttp,
      );
      expect(
        _transport(
          uri: Uri.https('media.test', '/video.mp4'),
          duration: Duration.zero,
        ),
        PlaybackTransportKind.live,
      );
      expect(
        _transport(uri: Uri.parse('rtsp://media.test/video')),
        PlaybackTransportKind.unknown,
      );
    });

    test('does not classify from a URL suffix alone', () {
      expect(
        _transport(
          uri: Uri.https('media.test', '/video.mp4'),
          liveStreamId: 'live',
        ),
        PlaybackTransportKind.live,
      );
      expect(
        _transport(
          uri: Uri.https('media.test', '/video.mp4'),
          sourceProtocol: 'Rtmp',
        ),
        PlaybackTransportKind.unknown,
      );
    });
  });

  group('profile resolution', () {
    const resolver = PlaybackCacheProfileResolver();

    test('automatic mode resolves every free-space tier', () {
      final cases = <(int, PlaybackCacheRuntimeMode, int, int, int)>[
        (1 << 30, PlaybackCacheRuntimeMode.memoryFallback, 60, 30, 0),
        (6 << 30, PlaybackCacheRuntimeMode.disk, 90, 60, 256 << 20),
        (12 << 30, PlaybackCacheRuntimeMode.disk, 180, 120, 512 << 20),
        (32 << 30, PlaybackCacheRuntimeMode.disk, 300, 180, 1 << 30),
        (80 << 30, PlaybackCacheRuntimeMode.disk, 600, 300, 2 << 30),
      ];
      for (final entry in cases) {
        final profile = resolver.resolve(
          plan: _plan(),
          settings: const PlaybackCacheSettings(),
          capabilities: _capabilities(),
          storage: _storage(entry.$1),
        );
        expect(profile.runtimeMode, entry.$2);
        expect(profile.forwardTarget.inSeconds, entry.$3);
        expect(profile.backwardTarget.inSeconds, entry.$4);
        expect(profile.sessionTargetBytes, entry.$5);
      }
    });

    test('safe spendable space limits the selected mode target', () {
      final profile = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.aggressive,
          reservedFreeBytes: 2 << 30,
        ),
        capabilities: _capabilities(),
        storage: _storage(4 << 30),
      );

      expect(profile.runtimeMode, PlaybackCacheRuntimeMode.disk);
      expect(profile.sessionTargetBytes, 512 << 20);
    });

    test('high bitrate never violates the minimum disk window', () {
      final fallback = resolver.resolve(
        plan: _plan(bitrate: 1000 * 1000 * 1000),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.spaceSaving,
        ),
        capabilities: _capabilities(),
        storage: _storage(20 << 30),
      );
      final scaled = resolver.resolve(
        plan: _plan(bitrate: 40 * 1000 * 1000),
        settings: const PlaybackCacheSettings(mode: PlaybackCacheMode.balanced),
        capabilities: _capabilities(),
        storage: _storage(20 << 30),
      );

      expect(
        fallback.fallbackReason,
        PlaybackCacheFallbackReason.targetTooSmallForMinimumWindow,
      );
      expect(scaled.runtimeMode, PlaybackCacheRuntimeMode.disk);
      expect(scaled.forwardTarget.inSeconds, greaterThanOrEqualTo(30));
      expect(scaled.backwardTarget.inSeconds, greaterThanOrEqualTo(15));
      final estimated =
          (40 *
                  1000 *
                  1000 /
                  8 *
                  (scaled.forwardTarget.inSeconds +
                      scaled.backwardTarget.inSeconds) *
                  1.25)
              .ceil();
      expect(estimated, lessThanOrEqualTo(scaled.sessionTargetBytes));
    });

    test('metadata budgets map independently and stay under the cap', () {
      final profile = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.custom,
          customForwardSeconds: 900,
          customBackwardSeconds: 15,
          customSessionTargetBytes: 512 << 20,
        ),
        capabilities: _capabilities(),
        storage: _storage(20 << 30),
      );

      expect(profile.runtimeMode, PlaybackCacheRuntimeMode.disk);
      expect(profile.demuxerForwardMetadataBytes, greaterThan(16 << 20));
      expect(
        profile.demuxerBackwardMetadataBytes,
        greaterThanOrEqualTo(8 << 20),
      );
      expect(profile.totalMetadataBytes, lessThanOrEqualTo(64 << 20));
      expect(
        profile.totalMetadataBytes,
        lessThanOrEqualTo(profile.metadataBudgetCapBytes),
      );
    });

    test(
      'memory pressure and ineligible media use explicit safe fallbacks',
      () {
        final pressured = resolver.resolve(
          plan: _plan(),
          settings: const PlaybackCacheSettings(
            mode: PlaybackCacheMode.aggressive,
          ),
          capabilities: _capabilities(),
          storage: _storage(80 << 30),
          memoryPressure: true,
        );
        final segmented = resolver.resolve(
          plan: _plan(transport: PlaybackTransportKind.segmentedHttp),
          settings: const PlaybackCacheSettings(),
          capabilities: _capabilities(),
          storage: _storage(80 << 30),
        );
        final offline = resolver.resolve(
          plan: _plan(transport: PlaybackTransportKind.offlineLocal),
          settings: const PlaybackCacheSettings(),
          capabilities: _capabilities(),
          storage: _storage(80 << 30),
        );

        expect(pressured.runtimeMode, PlaybackCacheRuntimeMode.memoryFallback);
        expect(
          pressured.fallbackReason,
          PlaybackCacheFallbackReason.memoryPressure,
        );
        expect(pressured.totalMetadataBytes, lessThanOrEqualTo(64 << 20));
        expect(
          segmented.fallbackReason,
          PlaybackCacheFallbackReason.segmentedTransport,
        );
        expect(offline.runtimeMode, PlaybackCacheRuntimeMode.disabled);
        expect(
          offline.fallbackReason,
          PlaybackCacheFallbackReason.offlineMedia,
        );
      },
    );

    test('capability and storage failures never enable disk cache', () {
      final unsupported = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(),
        capabilities: _capabilities(passed: false),
        storage: _storage(80 << 30),
      );
      final unknown = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(),
        capabilities: _capabilities(),
        storage: const PlaybackCacheStorageSnapshot.unavailable(
          PlaybackCacheStorageFailureReason.storageCapacityUnknown,
        ),
      );

      expect(
        unsupported.fallbackReason,
        PlaybackCacheFallbackReason.engineCapabilityUnavailable,
      );
      expect(
        unknown.fallbackReason,
        PlaybackCacheFallbackReason.storageCapacityUnknown,
      );
      expect(unsupported.sessionDirectory, isNull);
      expect(unknown.sessionDirectory, isNull);
    });

    test('memory fallback metadata matches the complete mpv profile', () {
      final profile = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.aggressive,
        ),
        capabilities: _capabilities(passed: false),
        storage: _storage(80 << 30),
      );
      final values = PlaybackCacheProfileValues.fromProfile(
        profile,
        bindings: bindingsFromNativeMaps(
          optionSupport: {
            for (final option in playbackCacheOptionNames) option: true,
          },
          resetValues: {
            for (final option in playbackCacheOptionNames)
              option: option == 'demuxer-cache-dir' ? '' : '0',
          },
        ),
      ).plan;

      expect(profile.runtimeMode, PlaybackCacheRuntimeMode.memoryFallback);
      expect(profile.demuxerForwardMetadataBytes, lessThanOrEqualTo(64 << 20));
      expect(profile.demuxerBackwardMetadataBytes, lessThanOrEqualTo(16 << 20));
      expect(profile.totalMetadataBytes, lessThanOrEqualTo(64 << 20));
      expect(
        values.criticalValues[PlaybackCacheLogicalOption.forwardMetadataBytes],
        profile.demuxerForwardMetadataBytes.toString(),
      );
      expect(
        values.criticalValues[PlaybackCacheLogicalOption.backwardMetadataBytes],
        profile.demuxerBackwardMetadataBytes.toString(),
      );
    });
  });
}

PlaybackTransportKind _transport({
  required Uri uri,
  PlayMethod method = PlayMethod.directPlay,
  String? sourceProtocol = 'Http',
  String? container = 'mp4',
  String? liveStreamId,
  Duration duration = const Duration(hours: 1),
}) => classifyPlaybackTransport(
  method: method,
  uri: uri,
  sourceProtocol: sourceProtocol,
  container: container,
  liveStreamId: liveStreamId,
  duration: duration,
);

PlaybackPlan _plan({
  PlaybackTransportKind transport = PlaybackTransportKind.progressiveHttp,
  int? bitrate = 8 * 1000 * 1000,
}) => PlaybackPlan(
  uri: Uri.https('media.test', '/video.mp4'),
  mediaSourceId: 'source',
  playSessionId: 'session',
  method: PlayMethod.directPlay,
  usesServerAuthentication: true,
  mediaStreams: const [],
  transcodingReasons: const [],
  availableMediaSources: const [],
  duration: const Duration(hours: 1),
  bitrate: bitrate,
  transportKind: transport,
);

PlaybackCacheEngineCapabilities _capabilities({bool passed = true}) =>
    PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: 'mpv-test',
      platform: 'test',
      optionSupport: {
        for (final option in playbackCacheOptionNames) option: passed,
      },
      propertySupport: {
        for (final property in playbackCachePropertyNames) property: passed,
      },
      supportsImmediateUnlink: passed,
      profileSwitchStrategy: passed
          ? PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop
          : PlaybackCacheProfileSwitchStrategy.unsupported,
      resetValues: passed
          ? {
              for (final option in playbackCacheProfileOptionNames)
                option: option == 'demuxer-cache-dir' ? '' : 'auto',
            }
          : const {},
    );

PlaybackCacheStorageSnapshot _storage(int freeBytes) =>
    PlaybackCacheStorageSnapshot.available(
      session: PlaybackCacheSession(
        directory: Directory.systemTemp,
        nonce: '0123456789abcdef0123456789abcdef',
      ),
      freeBytes: freeBytes,
    );
