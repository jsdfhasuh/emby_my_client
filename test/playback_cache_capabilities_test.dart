import 'dart:async';

import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_option_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'probe records required options, choices, resets, and strategy',
    () async {
      final access = _FakeNativeAccess.complete();
      final experiment = _FakeExperiment(
        PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      );

      final result = await PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment: experiment,
      ).probe();

      expect(result.mpvVersionFingerprint, 'mpv-0.40.0');
      expect(result.platform, 'iPadOS');
      expect(result.supportsDiskCache, isTrue);
      expect(result.supportsCacheDirectory, isTrue);
      expect(result.supportsImmediateUnlink, isTrue);
      expect(result.supportsNativeCacheState, isTrue);
      expect(result.supportsStreamBufferSize, isTrue);
      expect(
        result.profileSwitchStrategy,
        PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      );
      expect(result.resetValues['demuxer-cache-dir'], '');
      expect(result.diskGatePassed, isTrue);
      expect(experiment.calls, 1);
      expect(
        result.toSafeDiagnosticManifest().keys,
        isNot(contains(anyOf('path', 'url', 'itemId', 'deviceId'))),
      );
      expect(
        result.toSafeDiagnosticManifest().keys,
        isNot(contains('property_demuxer_cache_state')),
      );
    },
  );

  test(
    'probe requires reset read-back after restoring a native option',
    () async {
      final access = _FakeNativeAccess.complete()..failResetReadBack = true;
      final result = await PlaybackCacheCapabilityProbe(access: access).probe();

      expect(
        result.bindings.statusFor(PlaybackCacheLogicalOption.cacheDirectory, 0),
        PlaybackNativeOptionCandidateStatus.presentButIncomplete,
      );
      expect(result.supportsCacheDirectory, isFalse);
    },
  );

  test('probe restores reset value after a native read failure', () async {
    final access = _FakeNativeAccess.complete()
      ..throwPropertyReadOnce = 'cache';

    final result = await PlaybackCacheCapabilityProbe(access: access).probe();

    expect(access.strings['cache'], 'no');
    expect(
      result.bindings.statusFor(PlaybackCacheLogicalOption.cache, 0),
      PlaybackNativeOptionCandidateStatus.presentButIncomplete,
    );
  });

  test('probe rejects an option whose reported name does not match', () async {
    final access = _FakeNativeAccess.complete()
      ..strings['option-info/demuxer-cache-dir/name'] = 'cache-dir';

    final result = await PlaybackCacheCapabilityProbe(access: access).probe();

    expect(
      result.bindings.statusFor(PlaybackCacheLogicalOption.cacheDirectory, 0),
      PlaybackNativeOptionCandidateStatus.unavailable,
    );
    expect(
      result.bindings.supports(PlaybackCacheLogicalOption.cacheDirectory),
      isFalse,
    );
  });

  test(
    'missing immediate choice blocks disk without running experiment',
    () async {
      final access = _FakeNativeAccess.complete()
        ..nativeValues['option-info/demuxer-cache-unlink-files/choices'] = [
          'no',
          'whendone',
        ];
      final experiment = _FakeExperiment(
        PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      );

      final result = await PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment: experiment,
      ).probe();

      expect(result.supportsImmediateUnlink, isFalse);
      expect(result.diskGatePassed, isFalse);
      expect(
        result.profileSwitchStrategy,
        PlaybackCacheProfileSwitchStrategy.unsupported,
      );
      expect(experiment.calls, 0);
    },
  );

  test('safe manifest revalidates constructor-provided identity strings', () {
    final capabilities = PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint:
          'Bearer secret-token https://private.example/media-title',
      platform: 'username@host:8096',
      optionSupport: const {},
      propertySupport: const {},
      supportsImmediateUnlink: false,
      profileSwitchStrategy: PlaybackCacheProfileSwitchStrategy.unsupported,
      resetValues: const {},
    );

    final manifest = capabilities.toSafeDiagnosticManifest();

    expect(manifest['mpvVersionFingerprint'], 'unavailable');
    expect(manifest['platform'], 'unsupported');
    final encoded = manifest.toString().toLowerCase();
    expect(encoded, isNot(contains('secret-token')));
    expect(encoded, isNot(contains('private.example')));
    expect(encoded, isNot(contains('username')));
  });

  test('safe manifest requires a numeric mpv version fingerprint', () {
    for (final identity in ['mpv', 'mpv-test']) {
      final capabilities = PlaybackCacheEngineCapabilities(
        mpvVersionFingerprint: identity,
        platform: 'iPadOS',
        optionSupport: const {},
        propertySupport: const {},
        supportsImmediateUnlink: false,
        profileSwitchStrategy: PlaybackCacheProfileSwitchStrategy.unsupported,
        resetValues: const {},
      );

      expect(
        capabilities.toSafeDiagnosticManifest()['mpvVersionFingerprint'],
        'unavailable',
        reason: identity,
      );
    }
  });

  test('probe rejects non-prefix and oversized mpv identities', () async {
    for (final identity in ['Copyright mpv 0.40.0', 'mpv 1.2-${'a' * 60}']) {
      final access = _FakeNativeAccess.complete()
        ..strings['mpv-version'] = identity;

      final result = await PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment: _FakeExperiment(
          PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
        ),
      ).probe();

      expect(result.mpvVersionFingerprint, 'unavailable', reason: identity);
    }
  });

  test('recreation-only switch remains an approved disk strategy', () async {
    final result = await PlaybackCacheCapabilityProbe(
      access: _FakeNativeAccess.complete(),
      profileSwitchExperiment: _FakeExperiment(
        PlaybackCacheProfileSwitchStrategy.requiresPlayerRecreation,
      ),
    ).probe();

    expect(
      result.profileSwitchStrategy,
      PlaybackCacheProfileSwitchStrategy.requiresPlayerRecreation,
    );
    expect(result.diskGatePassed, isTrue);
  });

  test(
    'missing telemetry blocks disk but preserves memory capability',
    () async {
      final access = _FakeNativeAccess.complete()
        ..supportedProperties.remove('demuxer-cache-state');
      final result = await PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment: _FakeExperiment(
          PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
        ),
      ).probe();

      expect(result.supportsDiskCache, isTrue);
      expect(result.supportsNativeCacheState, isFalse);
      expect(result.diskGatePassed, isFalse);
    },
  );

  test('missing any complete profile option blocks the disk gate', () async {
    final access = _FakeNativeAccess.complete()
      ..supportedOptions.remove('stream-buffer-size');
    final experiment = _FakeExperiment(
      PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
    );

    final result = await PlaybackCacheCapabilityProbe(
      access: access,
      profileSwitchExperiment: experiment,
    ).probe();

    expect(result.supportsDiskCache, isTrue);
    expect(result.diskGatePassed, isTrue);
    expect(
      result.bindings.optionalTuningUnavailable,
      contains(PlaybackCacheLogicalOption.streamBufferSize),
    );
    expect(experiment.calls, 1);
  });

  test(
    'missing optional reset evidence degrades tuning without blocking disk',
    () async {
      final access = _FakeNativeAccess.complete()
        ..strings.remove('option-info/cache-pause-wait/default-value');
      final experiment = _FakeExperiment(
        PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      );

      final result = await PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment: experiment,
      ).probe();

      expect(result.optionSupport.keys, contains('cache-pause-wait'));
      expect(
        result.bindings.optionalTuningUnavailable,
        contains(PlaybackCacheLogicalOption.cachePauseWait),
      );
      expect(result.hasCompleteResetValues, isFalse);
      expect(result.diskGatePassed, isTrue);
      expect(
        result.profileSwitchStrategy,
        PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      );
      expect(experiment.calls, 1);
      expect(result.toSafeDiagnosticManifest()['resetValuesComplete'], isFalse);
    },
  );

  test('native operations have a fixed timeout', () async {
    final pending = Completer<void>();
    NativePlaybackOperationKind? reported;

    await expectLater(
      withNativePlaybackTimeout(
        pending.future,
        operation: NativePlaybackOperationKind.propertyRead,
        timeout: const Duration(milliseconds: 5),
        onTimeout: (operation) => reported = operation,
      ),
      throwsA(
        isA<NativePlaybackOperationTimeout>().having(
          (error) => error.operation,
          'operation',
          NativePlaybackOperationKind.propertyRead,
        ),
      ),
    );
    expect(reported, NativePlaybackOperationKind.propertyRead);
  });

  test(
    'runtime experiment applies disk memory and disabled around stop',
    () async {
      final access = _FakeNativeAccess.complete();

      final result = await PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment:
            const RuntimePlaybackCacheProfileSwitchExperiment(),
      ).probe();

      expect(
        result.profileSwitchStrategy,
        PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      );
      expect(access.commands, [
        ['loadfile', isA<String>(), 'replace'],
        ['stop'],
        ['loadfile', isA<String>(), 'replace'],
        ['stop'],
        ['loadfile', isA<String>(), 'replace'],
        ['stop'],
      ]);
      expect(access.profileCacheModes, ['yes/yes', 'yes/no', 'no/no']);
    },
  );
}

class _FakeExperiment implements PlaybackCacheProfileSwitchExperiment {
  _FakeExperiment(this.result);

  final PlaybackCacheProfileSwitchStrategy result;
  int calls = 0;

  @override
  Future<PlaybackCacheProfileSwitchStrategy> run({
    required NativePlaybackPropertyAccess access,
    required ResolvedPlaybackCacheOptionBindings bindings,
  }) async {
    calls++;
    expect(bindings.supports(PlaybackCacheLogicalOption.cacheOnDisk), isTrue);
    return result;
  }
}

class _FakeNativeAccess implements NativePlaybackPropertyAccess {
  _FakeNativeAccess.complete()
    : supportedOptions = playbackCacheOptionNames.toSet(),
      supportedProperties = playbackCachePropertyNames.toSet(),
      strings = {
        'mpv-version': 'mpv 0.40.0 Copyright build path must not escape',
        'platform': 'darwin',
        for (final option in playbackCacheOptionNames)
          'option-info/$option/name': option,
        for (final option in playbackCacheOptionNames)
          'option-info/$option/default-value': _resetValue(option),
      },
      nativeValues = {
        'option-info/demuxer-cache-unlink-files/choices': [
          'no',
          'whendone',
          'immediate',
        ],
      };

  final Set<String> supportedOptions;
  final Set<String> supportedProperties;
  final Map<String, String> strings;
  final Map<String, Object> nativeValues;
  final List<List<Object>> commands = [];
  final List<String> profileCacheModes = [];
  bool failResetReadBack = false;
  String? throwPropertyReadOnce;

  static String _resetValue(String option) => switch (option) {
    'demuxer-cache-dir' => '',
    'cache' ||
    'cache-on-disk' ||
    'demuxer-donate-buffer' ||
    'cache-pause' => 'no',
    'demuxer-cache-unlink-files' => 'whendone',
    'demuxer-seekable-cache' => 'auto',
    'cache-secs' ||
    'demuxer-max-bytes' ||
    'demuxer-max-back-bytes' ||
    'cache-pause-wait' ||
    'stream-buffer-size' => '0',
    _ => '0',
  };

  @override
  Future<String?> getString(String name) async {
    if (throwPropertyReadOnce == name) {
      throwPropertyReadOnce = null;
      throw StateError('fixture native read failure');
    }
    return strings[name];
  }

  @override
  Future<Object?> getNative(String name) async =>
      nativeValues[name] ?? strings[name];

  @override
  Future<bool> hasOption(String name) async => supportedOptions.contains(name);

  @override
  Future<bool> hasProperty(String name) async =>
      supportedProperties.contains(name);

  @override
  Future<void> setString(String name, String value) async {
    if (failResetReadBack && name == 'demuxer-cache-dir' && value == '') {
      strings[name] = 'unexpected-reset';
      return;
    }
    strings[name] = value;
  }

  @override
  Future<void> command(List<String> command) async {
    commands.add(List<Object>.of(command));
    if (command.first == 'loadfile') {
      profileCacheModes.add('${strings['cache']}/${strings['cache-on-disk']}');
      strings['idle-active'] = 'no';
    } else if (command.first == 'stop') {
      strings['idle-active'] = 'yes';
    }
  }
}
