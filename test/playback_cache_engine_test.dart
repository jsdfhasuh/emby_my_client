import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_option_bindings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
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
    expect(result.cacheEvidence, PlaybackCacheEvidence.diskConfiguredOnly);
  });

  test(
    'critical disk failure remains unconfirmed after disk capability passes',
    () async {
      final access = _FakeNativeAccess(failOnceOn: 'cache-on-disk');
      final result = await PlaybackCacheProfileApplier(
        access: access,
        capabilities: _capabilities(),
      ).apply(_profile(PlaybackCacheRuntimeMode.disk));

      expect(result.actualMode, PlaybackCacheRuntimeMode.unconfirmed);
      expect(
        result.fallbackReason,
        PlaybackCacheFallbackReason.actualModeUnconfirmed,
      );
      expect(result.readBack, isEmpty);
    },
  );

  test(
    'disk capability unavailable permits an explicit memory fallback',
    () async {
      final access = _FakeNativeAccess();
      final result = await PlaybackCacheProfileApplier(
        access: access,
        capabilities: _capabilities(
          optionSupportOverride: {
            'cache': true,
            'cache-on-disk': true,
            'cache-secs': true,
            'demuxer-max-bytes': true,
            'demuxer-max-back-bytes': true,
          },
          resetValues: {
            'cache': 'no',
            'cache-on-disk': 'no',
            'cache-secs': '0',
            'demuxer-max-bytes': '0',
            'demuxer-max-back-bytes': '0',
          },
        ),
      ).apply(_profile(PlaybackCacheRuntimeMode.disk));

      expect(result.actualMode, PlaybackCacheRuntimeMode.memoryFallback);
      expect(
        result.fallbackReason,
        PlaybackCacheFallbackReason.engineCapabilityUnavailable,
      );
      expect(
        result.cacheEvidence,
        PlaybackCacheEvidence.memoryProfileConfirmed,
      );
    },
  );

  test('optional profile read-back mismatch degrades tuning only', () async {
    final access = _FakeNativeAccess(readMismatchOn: 'stream-buffer-size');

    final result = await PlaybackCacheProfileApplier(
      access: access,
      capabilities: _capabilities(),
    ).apply(_profile(PlaybackCacheRuntimeMode.disk));

    expect(result.actualMode, PlaybackCacheRuntimeMode.disk);
    expect(result.optionalTuningDegraded, isTrue);
    expect(
      result.optionalTuningUnavailable,
      contains(PlaybackCacheLogicalOption.streamBufferSize),
    );
  });

  test(
    'missing native directory reset does not block memory core options',
    () async {
      final access = _FakeNativeAccess();
      final result = await PlaybackCacheProfileApplier(
        access: access,
        capabilities: _capabilities(resetValues: const {}),
      ).apply(_profile(PlaybackCacheRuntimeMode.memory));

      expect(result.actualMode, PlaybackCacheRuntimeMode.memory);
      expect(
        result.cacheEvidence,
        PlaybackCacheEvidence.memoryProfileConfirmed,
      );
      expect(access.values['cache'], 'yes');
      expect(access.values['cache-on-disk'], 'no');
      expect(result.readBack['cache'], 'yes');
      expect(result.readBack['cache-on-disk'], 'no');
      expect(access.values.keys, isNot(contains('demuxer-cache-dir')));
    },
  );

  test('memory profile confirms without directory or unlink options', () async {
    final access = _FakeNativeAccess();
    final capabilities = _capabilities(
      optionSupportOverride: {
        'cache': true,
        'cache-on-disk': true,
        'cache-secs': true,
        'demuxer-max-bytes': true,
        'demuxer-max-back-bytes': true,
      },
      resetValues: {
        'cache': 'no',
        'cache-on-disk': 'no',
        'cache-secs': '0',
        'demuxer-max-bytes': '0',
        'demuxer-max-back-bytes': '0',
      },
    );

    final result = await PlaybackCacheProfileApplier(
      access: access,
      capabilities: capabilities,
    ).apply(_profile(PlaybackCacheRuntimeMode.memory));

    expect(result.actualMode, PlaybackCacheRuntimeMode.memory);
    expect(result.cacheEvidence, PlaybackCacheEvidence.memoryProfileConfirmed);
    expect(access.values['cache'], 'yes');
    expect(access.values['cache-on-disk'], 'no');
    expect(access.values.keys, isNot(contains('demuxer-cache-dir')));
    expect(access.values.keys, isNot(contains('demuxer-cache-unlink-files')));
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

  test(
    'disabled profile writes cache-on-disk=no when that option is available',
    () async {
      final access = _FakeNativeAccess();
      final result = await PlaybackCacheProfileApplier(
        access: access,
        capabilities: _capabilities(),
      ).apply(_profile(PlaybackCacheRuntimeMode.disabled));

      expect(result.actualMode, PlaybackCacheRuntimeMode.disabled);
      expect(access.values['cache'], 'no');
      expect(access.values['cache-on-disk'], 'no');
      expect(result.readBack['cache-on-disk'], 'no');
    },
  );

  test(
    'disabled profile remains usable when cache-on-disk is unavailable',
    () async {
      final access = _FakeNativeAccess();
      final capabilities = _capabilities(
        optionSupportOverride: {
          'cache': true,
          'cache-secs': true,
          'demuxer-max-bytes': true,
          'demuxer-max-back-bytes': true,
        },
        resetValues: {
          'cache': 'no',
          'cache-secs': '0',
          'demuxer-max-bytes': '0',
          'demuxer-max-back-bytes': '0',
        },
      );

      final result = await PlaybackCacheProfileApplier(
        access: access,
        capabilities: capabilities,
      ).apply(_profile(PlaybackCacheRuntimeMode.disabled));

      expect(result.actualMode, PlaybackCacheRuntimeMode.disabled);
      expect(access.values['cache'], 'no');
      expect(access.values.keys, isNot(contains('cache-on-disk')));
    },
  );

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

  test('stale identity is discarded when a property read fails', () async {
    final propertyGate = Completer<void>();
    final access = _FakeNativeAccess(
      readGate: propertyGate.future,
      throwOnRead: 'cache-on-disk',
    )..nativeValues['demuxer-cache-state'] = {'file-cache-bytes': 1234};
    final engine = NativePlaybackCacheEngine(
      access: access,
      hasOpenedMedia: () => true,
    );
    final session = Object();
    final nativeEngine = Object();
    var current = true;
    final identity = PlaybackCacheReadIdentity(
      sessionIdentity: session,
      engineIdentity: nativeEngine,
      operationGeneration: 7,
    );

    final snapshot = engine.readCacheSnapshotForIdentity(
      identity: identity,
      isIdentityCurrent: (_) => current,
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    propertyGate.complete();

    expect(await snapshot, isNull);
    engine.dispose();
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

  test('disposed engine rejects new capability probes', () async {
    final access = _FakeNativeAccess();
    final engine = NativePlaybackCacheEngine(
      access: access,
      hasOpenedMedia: () => false,
    )..dispose();

    final result = await engine.probeCacheCapabilities();

    expect(
      result.profileSwitchStrategy,
      PlaybackCacheProfileSwitchStrategy.unsupported,
    );
    expect(access.values, isEmpty);
  });

  test(
    'disposed engine rejects cache configuration without native writes',
    () async {
      final access = _FakeNativeAccess();
      final engine = NativePlaybackCacheEngine(
        access: access,
        hasOpenedMedia: () => false,
      )..dispose();

      final result = await engine.configureCache(
        _profile(PlaybackCacheRuntimeMode.memory),
        _capabilities(),
      );

      expect(result.actualMode, PlaybackCacheRuntimeMode.unconfirmed);
      expect(
        result.fallbackReason,
        PlaybackCacheFallbackReason.actualModeUnconfirmed,
      );
      expect(access.values, isEmpty);
    },
  );
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
  Map<String, bool>? optionSupportOverride,
}) => PlaybackCacheEngineCapabilities(
  mpvVersionFingerprint: 'mpv-test',
  platform: 'test',
  optionSupport:
      optionSupportOverride ??
      {for (final option in playbackCacheOptionNames) option: true},
  propertySupport: {
    for (final property in playbackCachePropertyNames) property: true,
  },
  supportsImmediateUnlink: true,
  profileSwitchStrategy: strategy,
  resetValues: resetValues ?? _completeResetValues('reset-directory'),
  optionBindings: resolvePlaybackCacheOptionBindings(
    optionSupport:
        optionSupportOverride ??
        {for (final option in playbackCacheOptionNames) option: true},
    resetValues: resetValues ?? _completeResetValues('reset-directory'),
    requiredChoiceAvailable: {
      'demuxer-cache-unlink-files': true,
      'cache-unlink-files': true,
    },
    writeReadBackPassed: {
      'demuxer-cache-dir': true,
      'cache-dir': true,
      'demuxer-cache-unlink-files': true,
      'cache-unlink-files': true,
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

class _FakeNativeAccess implements NativePlaybackPropertyAccess {
  _FakeNativeAccess({
    this.failOnceOn,
    this.readMismatchOn,
    this.readGate,
    this.throwOnRead,
  });

  final String? failOnceOn;
  final String? readMismatchOn;
  final Future<void>? readGate;
  final String? throwOnRead;
  final Map<String, String> values = {};
  final Map<String, Object> nativeValues = {};
  bool _failed = false;

  @override
  Future<String?> getString(String name) async {
    await readGate;
    if (name == throwOnRead) throw StateError('fixed native read failure');
    return name == readMismatchOn ? 'mismatch' : values[name];
  }

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
