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

    test(
      'full read-ahead eligibility depends on progressive transport and duration',
      () {
        expect(isFullReadAheadEligible(_plan()), isTrue);
        expect(
          isFullReadAheadEligible(
            _plan(transport: PlaybackTransportKind.segmentedHttp),
          ),
          isFalse,
        );
        expect(
          isFullReadAheadEligible(_plan(duration: Duration.zero)),
          isFalse,
        );
      },
    );
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
            for (final option in playbackCacheNativeOptionNames) option: true,
          },
          resetValues: _completeResetValues(''),
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

    test('resolved profile carries source-size evidence and anchor', () {
      final declared = resolver.resolve(
        plan: _plan(sourceSizeBytes: 9 << 30),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.fullReadAhead,
        ),
        capabilities: _capabilities(),
        storage: _storage(80 << 30),
        readAheadAnchor: const Duration(minutes: 5),
      );
      final estimated = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.fullReadAhead,
        ),
        capabilities: _capabilities(),
        storage: _storage(80 << 30),
      );
      final unknown = resolver.resolve(
        plan: _plan(bitrate: null),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.fullReadAhead,
        ),
        capabilities: _capabilities(),
        storage: _storage(80 << 30),
      );

      expect(
        declared.sizeConfidence,
        PlaybackCacheSizeConfidence.serverDeclared,
      );
      expect(declared.estimatedSourceBytes, 9 << 30);
      expect(declared.readAheadAnchor, const Duration(minutes: 5));
      expect(
        declared.readAheadStrategy,
        PlaybackCacheReadAheadStrategy.mediaEnd,
      );
      expect(declared.budgetPolicy, PlaybackCacheBudgetPolicy.lowSpaceOnly);
      expect(estimated.sizeConfidence, PlaybackCacheSizeConfidence.estimated);
      expect(estimated.estimatedSourceBytes, isNotNull);
      expect(unknown.sizeConfidence, PlaybackCacheSizeConfidence.unknown);
      expect(unknown.estimatedSourceBytes, isNull);
    });

    test('known full-read-ahead size bypasses bounded target caps', () {
      final profile = resolver.resolve(
        plan: _plan(sourceSizeBytes: 9 << 30),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.fullReadAhead,
        ),
        capabilities: _capabilities(),
        storage: _storage(80 << 30),
        readAheadAnchor: const Duration(minutes: 5),
      );

      expect(profile.runtimeMode, PlaybackCacheRuntimeMode.disk);
      expect(
        profile.readAheadStrategy,
        PlaybackCacheReadAheadStrategy.mediaEnd,
      );
      expect(profile.budgetPolicy, PlaybackCacheBudgetPolicy.lowSpaceOnly);
      expect(profile.sessionTargetBytes, greaterThan(4 << 30));
      expect(profile.sessionTargetBytes, greaterThan(9 << 30));
      expect(profile.readAheadAnchor, const Duration(minutes: 5));
    });

    test(
      'known full-read-ahead size falls back to bounded cache when needed',
      () {
        final profile = resolver.resolve(
          plan: _plan(sourceSizeBytes: 9 << 30),
          settings: const PlaybackCacheSettings(
            mode: PlaybackCacheMode.fullReadAhead,
          ),
          capabilities: _capabilities(),
          storage: _storage(8 << 30),
        );

        expect(profile.runtimeMode, PlaybackCacheRuntimeMode.disk);
        expect(
          profile.fallbackReason,
          PlaybackCacheFallbackReason.fullReadAheadInsufficientSpace,
        );
        expect(
          profile.readAheadStrategy,
          PlaybackCacheReadAheadStrategy.boundedWindow,
        );
        expect(profile.budgetPolicy, PlaybackCacheBudgetPolicy.boundedReopen);
        expect(profile.sessionTargetBytes, lessThanOrEqualTo(512 << 20));
      },
    );

    test('estimated full-read-ahead size uses the remaining duration', () {
      final profile = resolver.resolve(
        plan: _plan(),
        settings: const PlaybackCacheSettings(
          mode: PlaybackCacheMode.fullReadAhead,
        ),
        capabilities: _capabilities(),
        storage: _storage(80 << 30),
        readAheadAnchor: const Duration(minutes: 30),
      );

      expect(profile.runtimeMode, PlaybackCacheRuntimeMode.disk);
      expect(profile.sizeConfidence, PlaybackCacheSizeConfidence.estimated);
      expect(
        profile.readAheadStrategy,
        PlaybackCacheReadAheadStrategy.mediaEnd,
      );
      expect(profile.sessionTargetBytes, greaterThan(2 << 30));
      expect(profile.sessionTargetBytes, lessThan(4 << 30));
    });

    test('unknown full-read-ahead size uses all safe spendable space', () {
      const freeBytes = 12 << 30;
      const settings = PlaybackCacheSettings(
        mode: PlaybackCacheMode.fullReadAhead,
        reservedFreeBytes: 2 << 30,
      );
      final profile = resolver.resolve(
        plan: _plan(bitrate: null),
        settings: settings,
        capabilities: _capabilities(),
        storage: _storage(freeBytes),
        rawInputRateBytesPerSecond: 64 << 20,
      );
      final guard = fullReadAheadLowSpaceGuardBytes(
        mediaBitrate: null,
        rawInputRateBytesPerSecond: 64 << 20,
        pollInterval: const Duration(seconds: 10),
        expectedCloseLatency: const Duration(seconds: 2),
      );

      expect(profile.runtimeMode, PlaybackCacheRuntimeMode.disk);
      expect(profile.sizeConfidence, PlaybackCacheSizeConfidence.unknown);
      expect(
        profile.readAheadStrategy,
        PlaybackCacheReadAheadStrategy.mediaEnd,
      );
      expect(
        profile.sessionTargetBytes,
        freeBytes - settings.reservedFreeBytes - guard,
      );
      expect(profile.sessionTargetBytes, greaterThan(4 << 30));
    });

    test(
      'unknown full-read-ahead size falls back below the best-effort floor',
      () {
        final profile = resolver.resolve(
          plan: _plan(bitrate: null),
          settings: const PlaybackCacheSettings(
            mode: PlaybackCacheMode.fullReadAhead,
            reservedFreeBytes: 2 << 30,
          ),
          capabilities: _capabilities(),
          storage: _storage((2.4 * (1 << 30)).floor()),
        );

        expect(profile.runtimeMode, PlaybackCacheRuntimeMode.memoryFallback);
        expect(
          profile.fallbackReason,
          PlaybackCacheFallbackReason.fullReadAheadInsufficientSpace,
        );
        expect(
          profile.readAheadStrategy,
          PlaybackCacheReadAheadStrategy.boundedWindow,
        );
      },
    );
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
  Duration duration = const Duration(hours: 1),
  int? sourceSizeBytes,
}) => PlaybackPlan(
  uri: Uri.https('media.test', '/video.mp4'),
  mediaSourceId: 'source',
  playSessionId: 'session',
  method: PlayMethod.directPlay,
  usesServerAuthentication: true,
  mediaStreams: const [],
  transcodingReasons: const [],
  availableMediaSources: const [],
  duration: duration,
  bitrate: bitrate,
  sourceSizeBytes: sourceSizeBytes,
  transportKind: transport,
);

PlaybackCacheEngineCapabilities _capabilities({bool passed = true}) =>
    PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: 'mpv-test',
      platform: 'test',
      optionSupport: {
        for (final option in playbackCacheNativeOptionNames) option: passed,
      },
      propertySupport: {
        for (final property in playbackCachePropertyNames) property: passed,
      },
      supportsImmediateUnlink: passed,
      profileSwitchStrategy: passed
          ? PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop
          : PlaybackCacheProfileSwitchStrategy.unsupported,
      resetValues: passed ? _completeResetValues('') : const {},
      optionBindings: resolvePlaybackCacheOptionBindings(
        optionSupport: {
          for (final option in playbackCacheNativeOptionNames) option: passed,
        },
        resetValues: passed ? _completeResetValues('') : const {},
        requiredChoiceAvailable: {
          'demuxer-cache-unlink-files': passed,
          'cache-unlink-files': passed,
        },
        writeReadBackPassed: {
          'demuxer-cache-dir': passed,
          'cache-dir': passed,
          'demuxer-cache-unlink-files': passed,
          'cache-unlink-files': passed,
        },
      ),
    );

Map<String, String> _completeResetValues(String directory) => {
  for (final option in playbackCacheProfileOptionNames)
    option: switch (option) {
      'demuxer-cache-dir' => directory,
      'cache' ||
      'cache-on-disk' ||
      'demuxer-donate-buffer' ||
      'cache-pause' => 'no',
      'demuxer-cache-unlink-files' => 'whendone',
      'demuxer-seekable-cache' => 'auto',
      _ => '0',
    },
};

PlaybackCacheStorageSnapshot _storage(int freeBytes) =>
    PlaybackCacheStorageSnapshot.available(
      session: PlaybackCacheSession(
        directory: Directory.systemTemp,
        nonce: '0123456789abcdef0123456789abcdef',
      ),
      freeBytes: freeBytes,
    );
