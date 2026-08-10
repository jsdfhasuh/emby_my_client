import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disk profile writes and reads every profile option back', () async {
    final access = _FakeNativeAccess();
    final result = await PlaybackCacheProfileApplier(
      access: access,
      capabilities: _capabilities(),
    ).apply(_profile(PlaybackCacheRuntimeMode.disk));

    expect(result.actualMode, PlaybackCacheRuntimeMode.disk);
    expect(access.values, hasLength(playbackCacheProfileOptionNames.length));
    expect(access.values['cache'], 'yes');
    expect(access.values['cache-on-disk'], 'yes');
    expect(access.values['demuxer-cache-unlink-files'], 'immediate');
    expect(access.values['cache-secs'], '180');
    expect(access.values['demuxer-max-bytes'], '${32 << 20}');
    expect(access.values['demuxer-max-back-bytes'], '${16 << 20}');
    expect(access.values['stream-buffer-size'], '${128 << 10}');
    expect(
      result.readBack.keys,
      unorderedEquals(playbackCacheProfileOptionNames),
    );
  });

  test(
    'critical disk failure applies and confirms a memory fallback',
    () async {
      final access = _FakeNativeAccess(failOnceOn: 'cache-on-disk');
      final result = await PlaybackCacheProfileApplier(
        access: access,
        capabilities: _capabilities(),
      ).apply(_profile(PlaybackCacheRuntimeMode.disk));

      expect(result.actualMode, PlaybackCacheRuntimeMode.memoryFallback);
      expect(
        result.fallbackReason,
        PlaybackCacheFallbackReason.engineCapabilityUnavailable,
      );
      expect(access.values['cache-on-disk'], 'no');
      expect(access.values['demuxer-cache-dir'], 'reset-directory');
      expect(result.readBack['cache-on-disk'], 'no');
    },
  );

  test('any profile read-back mismatch fails closed', () async {
    final access = _FakeNativeAccess(readMismatchOn: 'stream-buffer-size');

    final result = await PlaybackCacheProfileApplier(
      access: access,
      capabilities: _capabilities(),
    ).apply(_profile(PlaybackCacheRuntimeMode.disk));

    expect(result.actualMode, PlaybackCacheRuntimeMode.unconfirmed);
    expect(
      result.fallbackReason,
      PlaybackCacheFallbackReason.actualModeUnconfirmed,
    );
  });

  test('missing native directory reset fails closed without writing', () async {
    final access = _FakeNativeAccess();
    final result = await PlaybackCacheProfileApplier(
      access: access,
      capabilities: _capabilities(resetValues: const {}),
    ).apply(_profile(PlaybackCacheRuntimeMode.memory));

    expect(result.actualMode, PlaybackCacheRuntimeMode.unconfirmed);
    expect(
      result.fallbackReason,
      PlaybackCacheFallbackReason.actualModeUnconfirmed,
    );
    expect(access.values, isEmpty);
  });

  test('disk to memory to disabled fully resets inherited options', () async {
    final access = _FakeNativeAccess();
    final applier = PlaybackCacheProfileApplier(
      access: access,
      capabilities: _capabilities(),
    );

    await applier.apply(_profile(PlaybackCacheRuntimeMode.disk));
    await applier.apply(_profile(PlaybackCacheRuntimeMode.memory));
    expect(access.values['cache'], 'yes');
    expect(access.values['cache-on-disk'], 'no');
    expect(access.values['demuxer-cache-dir'], 'reset-directory');
    expect(
      int.parse(access.values['demuxer-max-bytes']!),
      lessThanOrEqualTo(64 << 20),
    );
    expect(
      int.parse(access.values['demuxer-max-back-bytes']!),
      lessThanOrEqualTo(16 << 20),
    );

    await applier.apply(_profile(PlaybackCacheRuntimeMode.disabled));
    expect(access.values['cache'], 'no');
    expect(access.values['cache-on-disk'], 'no');
    expect(access.values['cache-secs'], '0');
    expect(access.values['cache-pause'], 'no');
    expect(access.values['stream-buffer-size'], '${128 << 10}');
  });

  test('snapshot parser ignores damaged fields and unknown keys', () async {
    final access = _FakeNativeAccess()
      ..values['cache-on-disk'] = 'yes'
      ..values['paused-for-cache'] = 'no'
      ..values['cache-buffering-state'] = '42'
      ..nativeValues['demuxer-cache-state'] = {
        'file-cache-bytes': 1234,
        'raw-input-rate': '8192',
        'seekable-ranges': [
          {'start': 10, 'end': 20.5},
          {'start': 'bad', 'end': 50},
          {'start': 30, 'end': 29},
          'invalid',
        ],
        'unknown': {'raw': 'ignored'},
      };
    final engine = NativePlaybackCacheEngine(
      access: access,
      hasOpenedMedia: () => false,
    );

    final snapshot = await engine.readCacheSnapshot();

    expect(snapshot?.fileCacheBytes, 1234);
    expect(snapshot?.rawInputRateBytesPerSecond, 8192);
    expect(snapshot?.seekableRanges, hasLength(1));
    expect(snapshot?.seekableRanges.single.start, const Duration(seconds: 10));
    expect(
      snapshot?.seekableRanges.single.end,
      const Duration(milliseconds: 20500),
    );
    expect(snapshot?.pausedForCache, isFalse);
    expect(snapshot?.cacheBufferingPercent, 42);
    expect(snapshot?.cacheOnDisk, isTrue);
  });

  test('recreation strategy never partially writes an opened player', () async {
    final access = _FakeNativeAccess();
    final engine = NativePlaybackCacheEngine(
      access: access,
      hasOpenedMedia: () => true,
    );
    final result = await engine.configureCache(
      _profile(PlaybackCacheRuntimeMode.disk),
      _capabilities(
        strategy: PlaybackCacheProfileSwitchStrategy.requiresPlayerRecreation,
      ),
    );

    expect(result.requiresPlayerRecreation, isTrue);
    expect(result.actualMode, PlaybackCacheRuntimeMode.unconfirmed);
    expect(access.values, isEmpty);
  });
}

ResolvedPlaybackCacheProfile _profile(PlaybackCacheRuntimeMode mode) =>
    ResolvedPlaybackCacheProfile(
      runtimeMode: mode,
      transportKind: mode == PlaybackCacheRuntimeMode.disabled
          ? PlaybackTransportKind.offlineLocal
          : PlaybackTransportKind.progressiveHttp,
      fallbackReason: PlaybackCacheFallbackReason.none,
      forwardTarget: const Duration(seconds: 180),
      backwardTarget: const Duration(seconds: 120),
      sessionTargetBytes: mode == PlaybackCacheRuntimeMode.disk ? 512 << 20 : 0,
      reservedFreeBytes: 2 << 30,
      demuxerForwardMetadataBytes: 32 << 20,
      demuxerBackwardMetadataBytes: 16 << 20,
      metadataBudgetCapBytes: 64 << 20,
      streamBufferBytes: 128 << 10,
      donateBuffer: true,
      sessionDirectory: mode == PlaybackCacheRuntimeMode.disk
          ? Directory.systemTemp
          : null,
    );

PlaybackCacheEngineCapabilities _capabilities({
  PlaybackCacheProfileSwitchStrategy strategy =
      PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
  Map<String, String>? resetValues,
}) => PlaybackCacheEngineCapabilities(
  mpvVersionFingerprint: 'mpv-test',
  platform: 'test',
  optionSupport: {for (final option in playbackCacheOptionNames) option: true},
  propertySupport: {
    for (final property in playbackCachePropertyNames) property: true,
  },
  supportsImmediateUnlink: true,
  profileSwitchStrategy: strategy,
  resetValues: resetValues ?? _completeResetValues('reset-directory'),
);

Map<String, String> _completeResetValues(String directory) => {
  for (final option in playbackCacheProfileOptionNames)
    option: option == 'demuxer-cache-dir' ? directory : 'auto',
};

class _FakeNativeAccess implements NativePlaybackPropertyAccess {
  _FakeNativeAccess({this.failOnceOn, this.readMismatchOn});

  final String? failOnceOn;
  final String? readMismatchOn;
  final Map<String, String> values = {};
  final Map<String, Object> nativeValues = {};
  bool _failed = false;

  @override
  Future<String?> getString(String name) async =>
      name == readMismatchOn ? 'mismatch' : values[name];

  @override
  Future<Object?> getNative(String name) async =>
      nativeValues[name] ?? values[name];

  @override
  Future<bool> hasOption(String name) async => true;

  @override
  Future<bool> hasProperty(String name) async => true;

  @override
  Future<void> setString(String name, String value) async {
    if (!_failed && name == failOnceOn) {
      _failed = true;
      throw StateError('fixed native failure');
    }
    values[name] = value;
  }

  @override
  Future<void> command(List<String> command) async {}
}
