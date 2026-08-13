import 'dart:convert';

import 'native_playback_property_access.dart';
import 'playback_cache_option_bindings.dart';

enum PlaybackCacheProfileSwitchStrategy {
  inPlaceAfterMediaStop,
  requiresPlayerRecreation,
  unsupported,
}

enum PlaybackNativeValueAvailability {
  available,
  temporarilyUnavailable,
  unsupported,
}

class PlaybackNativeValue<T> {
  const PlaybackNativeValue._(this.availability, this.value);

  const PlaybackNativeValue.available(T value)
    : this._(PlaybackNativeValueAvailability.available, value);

  const PlaybackNativeValue.temporarilyUnavailable()
    : this._(PlaybackNativeValueAvailability.temporarilyUnavailable, null);

  const PlaybackNativeValue.unsupported()
    : this._(PlaybackNativeValueAvailability.unsupported, null);

  final PlaybackNativeValueAvailability availability;
  final T? value;
}

class PlaybackCacheEngineCapabilities {
  const PlaybackCacheEngineCapabilities({
    required this.mpvVersionFingerprint,
    required this.platform,
    required this.optionSupport,
    required this.propertySupport,
    required this.supportsImmediateUnlink,
    required this.profileSwitchStrategy,
    required this.resetValues,
    this.optionBindings,
  });

  factory PlaybackCacheEngineCapabilities.unsupported({
    String platform = 'unsupported',
  }) => PlaybackCacheEngineCapabilities(
    mpvVersionFingerprint: 'unavailable',
    platform: platform,
    optionSupport: const {},
    propertySupport: const {},
    supportsImmediateUnlink: false,
    profileSwitchStrategy: PlaybackCacheProfileSwitchStrategy.unsupported,
    resetValues: const {},
  );

  final String mpvVersionFingerprint;
  final String platform;
  final Map<String, bool> optionSupport;
  final Map<String, bool> propertySupport;
  final bool supportsImmediateUnlink;
  final PlaybackCacheProfileSwitchStrategy profileSwitchStrategy;
  final Map<String, String> resetValues;
  final ResolvedPlaybackCacheOptionBindings? optionBindings;

  ResolvedPlaybackCacheOptionBindings get bindings =>
      optionBindings ??
      bindingsFromNativeMaps(
        optionSupport: optionSupport,
        resetValues: resetValues,
      );

  bool get supportsDiskCache =>
      bindings.supports(PlaybackCacheLogicalOption.cache) &&
      bindings.supports(PlaybackCacheLogicalOption.cacheOnDisk);
  bool get supportsCacheDirectory =>
      bindings.supports(PlaybackCacheLogicalOption.cacheDirectory);
  bool get supportsNativeCacheState => _supportsProperty('demuxer-cache-state');
  bool get supportsSeekableRanges => supportsNativeCacheState;
  bool get supportsFileCacheBytes => supportsNativeCacheState;
  bool get supportsRawInputRate => supportsNativeCacheState;
  bool get supportsStreamBufferSize =>
      bindings.supports(PlaybackCacheLogicalOption.streamBufferSize);
  bool get hasCompleteResetValues => playbackCacheLogicalOptions.every(
    (option) =>
        bindings.supports(option) && bindings.resetValue(option) != null,
  );

  bool get diskGatePassed =>
      playbackCacheRequiredDiskLogicalOptions.every(bindings.supports) &&
      supportsImmediateUnlink &&
      supportsNativeCacheState &&
      supportsSeekableRanges &&
      supportsFileCacheBytes &&
      profileSwitchStrategy != PlaybackCacheProfileSwitchStrategy.unsupported;

  bool _supportsProperty(String name) => propertySupport[name] ?? false;

  Map<String, Object> toSafeDiagnosticManifest() => {
    'mpvVersionFingerprint': _safeFingerprint(mpvVersionFingerprint),
    'platform': _safePlatform(platform),
    ...bindings.toSafeDiagnosticManifest(),
    'cacheStatePropertySupported': supportsNativeCacheState,
    'seekableRangesSupported': supportsSeekableRanges,
    'fileCacheBytesSupported': supportsFileCacheBytes,
    'rawInputRateSupported': supportsRawInputRate,
    'supportsImmediateUnlink': supportsImmediateUnlink,
    'resetValuesComplete': hasCompleteResetValues,
    'profileSwitchStrategy': profileSwitchStrategy.name,
    'diskGatePassed': diskGatePassed,
  };
}

abstract interface class PlaybackCacheProfileSwitchExperiment {
  Future<PlaybackCacheProfileSwitchStrategy> run({
    required NativePlaybackPropertyAccess access,
    required ResolvedPlaybackCacheOptionBindings bindings,
  });
}

class PlaybackCacheCapabilityProbe {
  const PlaybackCacheCapabilityProbe({
    required this.access,
    this.profileSwitchExperiment,
  });

  final NativePlaybackPropertyAccess access;
  final PlaybackCacheProfileSwitchExperiment? profileSwitchExperiment;

  Future<PlaybackCacheEngineCapabilities> probe() async {
    final options = <String, bool>{};
    final optionNameMatches = <String, bool>{};
    for (final name in playbackCacheNativeOptionNames) {
      final exists = await access.hasOption(name);
      if (!exists) {
        optionNameMatches[name] = false;
        continue;
      }
      final reportedName = await access.getString('option-info/$name/name');
      final matches = reportedName == name;
      optionNameMatches[name] = matches;
      if (matches) options[name] = true;
    }

    final properties = <String, bool>{};
    for (final name in playbackCachePropertyNames) {
      properties[name] = await access.hasProperty(name);
    }

    final resetValues = <String, String>{};
    for (final name in playbackCacheNativeOptionNames) {
      if (options[name] != true) continue;
      final value = await access.getString('option-info/$name/default-value');
      if (value != null) resetValues[name] = value;
    }

    final choiceAvailability = <String, bool>{};
    for (final name in [
      ...playbackCacheNativeOptionCandidates[PlaybackCacheLogicalOption
          .cacheUnlinkFiles]!,
    ]) {
      if (options[name] != true) continue;
      final choices = await access.getNative('option-info/$name/choices');
      choiceAvailability[name] = _containsChoice(choices, 'immediate');
    }

    final writeReadBack = <String, bool>{};
    for (final name in playbackCacheNativeOptionNames) {
      final reset = resetValues[name];
      if (options[name] != true || reset == null) continue;
      writeReadBack[name] = await _writeAndReadBack(name, reset);
    }

    final bindings = resolvePlaybackCacheOptionBindings(
      optionSupport: options,
      resetValues: resetValues,
      optionNameMatches: optionNameMatches,
      requiredChoiceAvailable: choiceAvailability,
      writeReadBackPassed: writeReadBack,
    );

    final requiredOptionsAvailable = playbackCacheRequiredDiskLogicalOptions
        .every(bindings.supports);
    var switchStrategy = PlaybackCacheProfileSwitchStrategy.unsupported;
    if (requiredOptionsAvailable &&
        bindings.supports(PlaybackCacheLogicalOption.cacheUnlinkFiles) &&
        profileSwitchExperiment != null) {
      switchStrategy = await profileSwitchExperiment!.run(
        access: access,
        bindings: bindings,
      );
    }

    return PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: _safeFingerprint(
        await access.getString('mpv-version'),
      ),
      platform: _safePlatform(await access.getString('platform')),
      optionSupport: Map.unmodifiable(options),
      propertySupport: Map.unmodifiable(properties),
      supportsImmediateUnlink: bindings.supports(
        PlaybackCacheLogicalOption.cacheUnlinkFiles,
      ),
      profileSwitchStrategy: switchStrategy,
      resetValues: Map.unmodifiable(resetValues),
      optionBindings: bindings,
    );
  }

  Future<bool> _writeAndReadBack(String name, String reset) async {
    final logicalOption = playbackCacheLogicalOptionForNativeName(name);
    if (logicalOption == null) return false;
    final probeValue = _probeValue(logicalOption, reset);
    String? actual;
    var probeReadCompleted = false;
    try {
      await access.setString(name, probeValue);
      actual = await access.getString(name);
      probeReadCompleted = true;
    } catch (_) {
      // Restoration below is still required after a partial native failure.
    }

    String? resetActual;
    try {
      await access.setString(name, reset);
      resetActual = await access.getString(name);
    } catch (_) {
      return false;
    }
    if (!probeReadCompleted || actual == null || resetActual == null) {
      return false;
    }
    return playbackNativeValueCanonicalizer.equivalent(
          logicalOption,
          actual,
          probeValue,
        ) &&
        playbackNativeValueCanonicalizer.equivalent(
          logicalOption,
          resetActual,
          reset,
        );
  }

  String _probeValue(PlaybackCacheLogicalOption option, String reset) {
    return switch (option) {
      PlaybackCacheLogicalOption.cache => 'yes',
      PlaybackCacheLogicalOption.cacheOnDisk => 'no',
      PlaybackCacheLogicalOption.cacheDirectory => reset,
      PlaybackCacheLogicalOption.cacheUnlinkFiles => 'immediate',
      PlaybackCacheLogicalOption.cacheSeconds => '1',
      PlaybackCacheLogicalOption.forwardMetadataBytes => '1',
      PlaybackCacheLogicalOption.backwardMetadataBytes => '1',
      PlaybackCacheLogicalOption.donateBuffer => 'yes',
      PlaybackCacheLogicalOption.seekableCache => 'auto',
      PlaybackCacheLogicalOption.cachePause => 'yes',
      PlaybackCacheLogicalOption.cachePauseWait => '1',
      PlaybackCacheLogicalOption.streamBufferSize => '1',
    };
  }
}

const playbackCacheOptionNames = <String>[
  'cache',
  'cache-on-disk',
  'demuxer-cache-dir',
  'demuxer-cache-unlink-files',
  'cache-secs',
  'demuxer-max-bytes',
  'demuxer-max-back-bytes',
  'demuxer-donate-buffer',
  'demuxer-seekable-cache',
  'cache-pause',
  'cache-pause-wait',
  'stream-buffer-size',
];

const playbackCacheNativeOptionNames = <String>[
  ...playbackCacheOptionNames,
  'cache-dir',
  'cache-unlink-files',
];

const playbackCacheProfileOptionNames = playbackCacheOptionNames;

const playbackCacheRequiredDiskOptionNames = playbackCacheOptionNames;

const playbackCacheRequiredDiskLogicalOptions = <PlaybackCacheLogicalOption>[
  PlaybackCacheLogicalOption.cache,
  PlaybackCacheLogicalOption.cacheOnDisk,
  PlaybackCacheLogicalOption.cacheDirectory,
  PlaybackCacheLogicalOption.cacheUnlinkFiles,
  PlaybackCacheLogicalOption.cacheSeconds,
  PlaybackCacheLogicalOption.forwardMetadataBytes,
  PlaybackCacheLogicalOption.backwardMetadataBytes,
];

const playbackCachePropertyNames = <String>[
  'mpv-version',
  'platform',
  'property-list',
  'demuxer-cache-state',
];

bool _containsChoice(Object? value, String expected) {
  final target = expected.toLowerCase();
  if (value is Iterable) {
    return value.any((entry) => _containsChoice(entry, expected));
  }
  if (value is Map) {
    return value.entries.any(
      (entry) =>
          _containsChoice(entry.key, expected) ||
          _containsChoice(entry.value, expected),
    );
  }
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    if (!identical(decoded, value) && _containsChoice(decoded, expected)) {
      return true;
    }
  } catch (_) {
    // Native string formatting is allowed when a node value is unavailable.
  }
  return RegExp(
    r'(^|[^a-z0-9_-])' + RegExp.escape(target) + r'([^a-z0-9_-]|$)',
    caseSensitive: false,
  ).hasMatch(raw);
}

String _safeFingerprint(String? value) {
  final raw = value?.trim() ?? '';
  final versionMatch = RegExp(
    r'^mpv(?:\s+v?|[-_]v?)?([0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?)',
    caseSensitive: false,
  ).firstMatch(raw);
  final version = versionMatch?.group(1);
  if (version != null && version.length <= 59) return 'mpv-$version';
  return 'unavailable';
}

String _safePlatform(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'darwin' || 'ios' || 'ipados' => 'iPadOS',
    'android' => 'Android',
    _ => 'unsupported',
  };
}
