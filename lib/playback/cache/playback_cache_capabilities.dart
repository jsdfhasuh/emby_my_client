import 'dart:convert';

import 'native_playback_property_access.dart';

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

  bool get supportsDiskCache =>
      _supportsOption('cache') && _supportsOption('cache-on-disk');
  bool get supportsCacheDirectory => _supportsOption('demuxer-cache-dir');
  bool get supportsNativeCacheState => _supportsProperty('demuxer-cache-state');
  bool get supportsSeekableRanges => supportsNativeCacheState;
  bool get supportsFileCacheBytes => supportsNativeCacheState;
  bool get supportsRawInputRate => supportsNativeCacheState;
  bool get supportsStreamBufferSize => _supportsOption('stream-buffer-size');

  bool get diskGatePassed =>
      supportsDiskCache &&
      supportsCacheDirectory &&
      _supportsOption('demuxer-cache-unlink-files') &&
      supportsImmediateUnlink &&
      supportsNativeCacheState &&
      supportsSeekableRanges &&
      supportsFileCacheBytes &&
      profileSwitchStrategy != PlaybackCacheProfileSwitchStrategy.unsupported;

  bool _supportsOption(String name) => optionSupport[name] ?? false;
  bool _supportsProperty(String name) => propertySupport[name] ?? false;

  Map<String, Object> toSafeDiagnosticManifest() => {
    'mpvVersionFingerprint': mpvVersionFingerprint,
    'platform': platform,
    for (final option in playbackCacheOptionNames)
      'option_${_safeKey(option)}': optionSupport[option] ?? false,
    for (final property in playbackCachePropertyNames)
      'property_${_safeKey(property)}': propertySupport[property] ?? false,
    'supportsImmediateUnlink': supportsImmediateUnlink,
    'profileSwitchStrategy': profileSwitchStrategy.name,
    'diskGatePassed': diskGatePassed,
  };
}

abstract interface class PlaybackCacheProfileSwitchExperiment {
  Future<PlaybackCacheProfileSwitchStrategy> run({
    required NativePlaybackPropertyAccess access,
    required Map<String, String> resetValues,
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
    for (final name in playbackCacheOptionNames) {
      options[name] = await access.hasOption(name);
    }

    final properties = <String, bool>{};
    for (final name in playbackCachePropertyNames) {
      properties[name] = await access.hasProperty(name);
    }

    final choices = await access.getNative(
      'option-info/demuxer-cache-unlink-files/choices',
    );
    final resetValues = <String, String>{};
    for (final name in playbackCacheProfileOptionNames) {
      if (options[name] != true) continue;
      final value = await access.getString('option-info/$name/default-value');
      if (value != null) resetValues[name] = value;
    }

    final requiredOptionsAvailable = playbackCacheRequiredDiskOptionNames.every(
      (name) => options[name] == true,
    );
    var switchStrategy = PlaybackCacheProfileSwitchStrategy.unsupported;
    if (requiredOptionsAvailable &&
        _containsChoice(choices, 'immediate') &&
        profileSwitchExperiment != null) {
      switchStrategy = await profileSwitchExperiment!.run(
        access: access,
        resetValues: Map.unmodifiable(resetValues),
      );
    }

    return PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: _safeFingerprint(
        await access.getString('mpv-version'),
      ),
      platform: _safePlatform(await access.getString('platform')),
      optionSupport: Map.unmodifiable(options),
      propertySupport: Map.unmodifiable(properties),
      supportsImmediateUnlink: _containsChoice(choices, 'immediate'),
      profileSwitchStrategy: switchStrategy,
      resetValues: Map.unmodifiable(resetValues),
    );
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

const playbackCacheProfileOptionNames = playbackCacheOptionNames;

const playbackCacheRequiredDiskOptionNames = <String>[
  'cache',
  'cache-on-disk',
  'demuxer-cache-dir',
  'demuxer-cache-unlink-files',
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
  final match = RegExp(
    r'[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}',
  ).firstMatch(value ?? '');
  return match?.group(0) ?? 'unavailable';
}

String _safePlatform(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'darwin' || 'ios' => 'iPadOS',
    'android' => 'Android',
    _ => 'unsupported',
  };
}

String _safeKey(String value) => value.replaceAll('-', '_');
