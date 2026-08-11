import 'dart:async';

import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
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
    },
  );

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
    expect(result.diskGatePassed, isFalse);
    expect(experiment.calls, 0);
  });

  test(
    'missing reset evidence blocks disk without running experiment',
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

      expect(result.optionSupport.values, everyElement(isTrue));
      expect(result.hasCompleteResetValues, isFalse);
      expect(result.diskGatePassed, isFalse);
      expect(
        result.profileSwitchStrategy,
        PlaybackCacheProfileSwitchStrategy.unsupported,
      );
      expect(experiment.calls, 0);
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
    required Map<String, String> resetValues,
  }) async {
    calls++;
    expect(resetValues, contains('cache-on-disk'));
    return result;
  }
}

class _FakeNativeAccess implements NativePlaybackPropertyAccess {
  _FakeNativeAccess.complete()
    : supportedOptions = playbackCacheOptionNames.toSet(),
      supportedProperties = playbackCachePropertyNames.toSet(),
      strings = {
        'mpv-version': 'mpv-0.40.0 Copyright build path must not escape',
        'platform': 'darwin',
        for (final option in playbackCacheOptionNames)
          'option-info/$option/default-value': option == 'demuxer-cache-dir'
              ? ''
              : 'auto',
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

  @override
  Future<String?> getString(String name) async => strings[name];

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
