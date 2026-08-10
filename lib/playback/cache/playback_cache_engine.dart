import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'native_playback_property_access.dart';
import 'playback_cache_capabilities.dart';
import 'playback_cache_policy.dart';

class PlaybackCacheRange {
  const PlaybackCacheRange({required this.start, required this.end});

  final Duration start;
  final Duration end;
}

class PlaybackCacheEngineSnapshot {
  const PlaybackCacheEngineSnapshot({
    required this.fileCacheBytes,
    required this.rawInputRateBytesPerSecond,
    required this.seekableRanges,
    required this.pausedForCache,
    required this.cacheBufferingPercent,
    required this.cacheOnDisk,
  });

  final int? fileCacheBytes;
  final int? rawInputRateBytesPerSecond;
  final List<PlaybackCacheRange> seekableRanges;
  final bool? pausedForCache;
  final int? cacheBufferingPercent;
  final bool? cacheOnDisk;
}

class PlaybackCacheApplyResult {
  const PlaybackCacheApplyResult({
    required this.requestedMode,
    required this.actualMode,
    required this.fallbackReason,
    required this.requiresPlayerRecreation,
    required this.readBack,
  });

  final PlaybackCacheRuntimeMode requestedMode;
  final PlaybackCacheRuntimeMode actualMode;
  final PlaybackCacheFallbackReason fallbackReason;
  final bool requiresPlayerRecreation;
  final Map<String, String> readBack;
}

abstract interface class PlaybackCacheEngine {
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities();

  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  );

  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot();
}

class NativePlaybackCacheEngine implements PlaybackCacheEngine {
  NativePlaybackCacheEngine({
    required this.access,
    required bool Function() hasOpenedMedia,
  }) : _hasOpenedMedia = hasOpenedMedia;

  final NativePlaybackPropertyAccess access;
  final bool Function() _hasOpenedMedia;
  Future<PlaybackCacheEngineCapabilities>? _capabilities;

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() =>
      _capabilities ??= PlaybackCacheCapabilityProbe(
        access: access,
        profileSwitchExperiment:
            const RuntimePlaybackCacheProfileSwitchExperiment(),
      ).probe();

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) async {
    if (_hasOpenedMedia() &&
        capabilities.profileSwitchStrategy ==
            PlaybackCacheProfileSwitchStrategy.requiresPlayerRecreation) {
      return PlaybackCacheApplyResult(
        requestedMode: profile.runtimeMode,
        actualMode: PlaybackCacheRuntimeMode.unconfirmed,
        fallbackReason: PlaybackCacheFallbackReason.actualModeUnconfirmed,
        requiresPlayerRecreation: true,
        readBack: const {},
      );
    }
    return PlaybackCacheProfileApplier(
      access: access,
      capabilities: capabilities,
    ).apply(profile);
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() async {
    try {
      final state = await access.getNative('demuxer-cache-state');
      final cacheOnDisk = _parseBoolean(
        await access.getString('cache-on-disk'),
      );
      final paused = _parseBoolean(await access.getString('paused-for-cache'));
      final buffering = _parseInteger(
        await access.getString('cache-buffering-state'),
      );
      if (state is! Map) {
        return PlaybackCacheEngineSnapshot(
          fileCacheBytes: null,
          rawInputRateBytesPerSecond: null,
          seekableRanges: const [],
          pausedForCache: paused,
          cacheBufferingPercent: buffering,
          cacheOnDisk: cacheOnDisk,
        );
      }
      return PlaybackCacheEngineSnapshot(
        fileCacheBytes: _parseInteger(state['file-cache-bytes']),
        rawInputRateBytesPerSecond: _parseInteger(state['raw-input-rate']),
        seekableRanges: _parseRanges(state['seekable-ranges']),
        pausedForCache: paused,
        cacheBufferingPercent: buffering,
        cacheOnDisk: cacheOnDisk,
      );
    } catch (_) {
      return null;
    }
  }
}

class PlaybackCacheProfileApplier {
  const PlaybackCacheProfileApplier({
    required this.access,
    required this.capabilities,
  });

  final NativePlaybackPropertyAccess access;
  final PlaybackCacheEngineCapabilities capabilities;

  static const _criticalReadBack = <String>[...playbackCacheOptionNames];

  Future<PlaybackCacheApplyResult> apply(
    ResolvedPlaybackCacheProfile profile,
  ) async {
    final requestedMode = profile.runtimeMode;
    final diskRequested = requestedMode == PlaybackCacheRuntimeMode.disk;
    if (diskRequested && !capabilities.diskGatePassed) {
      return _applyMemoryFallback(
        profile,
        PlaybackCacheFallbackReason.engineCapabilityUnavailable,
      );
    }

    final values = PlaybackCacheProfileValues.fromProfile(
      profile,
      resetValues: capabilities.resetValues,
    );
    final readBack = await _writeAndReadBack(values.values);
    if (readBack != null) {
      return PlaybackCacheApplyResult(
        requestedMode: requestedMode,
        actualMode: requestedMode,
        fallbackReason: profile.fallbackReason,
        requiresPlayerRecreation: false,
        readBack: Map.unmodifiable(readBack),
      );
    }
    if (diskRequested) {
      return _applyMemoryFallback(
        profile,
        PlaybackCacheFallbackReason.engineCapabilityUnavailable,
      );
    }
    return PlaybackCacheApplyResult(
      requestedMode: requestedMode,
      actualMode: PlaybackCacheRuntimeMode.unconfirmed,
      fallbackReason: PlaybackCacheFallbackReason.actualModeUnconfirmed,
      requiresPlayerRecreation: false,
      readBack: const {},
    );
  }

  Future<PlaybackCacheApplyResult> _applyMemoryFallback(
    ResolvedPlaybackCacheProfile original,
    PlaybackCacheFallbackReason reason,
  ) async {
    final fallback = PlaybackCacheProfileValues.memoryFallback(
      original,
      resetValues: capabilities.resetValues,
    );
    final readBack = await _writeAndReadBack(fallback.values);
    if (readBack == null) {
      return PlaybackCacheApplyResult(
        requestedMode: original.runtimeMode,
        actualMode: PlaybackCacheRuntimeMode.unconfirmed,
        fallbackReason: PlaybackCacheFallbackReason.actualModeUnconfirmed,
        requiresPlayerRecreation: false,
        readBack: const {},
      );
    }
    return PlaybackCacheApplyResult(
      requestedMode: original.runtimeMode,
      actualMode: PlaybackCacheRuntimeMode.memoryFallback,
      fallbackReason: reason,
      requiresPlayerRecreation: false,
      readBack: Map.unmodifiable(readBack),
    );
  }

  Future<Map<String, String>?> _writeAndReadBack(
    Map<String, String> values,
  ) async {
    try {
      for (final entry in values.entries) {
        if (capabilities.optionSupport[entry.key] != true) continue;
        await access.setString(entry.key, entry.value);
      }
      final readBack = <String, String>{};
      for (final name in _criticalReadBack) {
        if (capabilities.optionSupport[name] != true) return null;
        final value = await access.getString(name);
        if (value == null || !_equivalent(value, values[name]!)) return null;
        readBack[name] = value;
      }
      return readBack;
    } catch (_) {
      return null;
    }
  }

  static bool _equivalent(String actual, String expected) =>
      _equivalentNativeValue(actual, expected);
}

class PlaybackCacheProfileValues {
  const PlaybackCacheProfileValues._(this.values);

  final Map<String, String> values;

  factory PlaybackCacheProfileValues.fromProfile(
    ResolvedPlaybackCacheProfile profile, {
    required Map<String, String> resetValues,
  }) {
    return switch (profile.runtimeMode) {
      PlaybackCacheRuntimeMode.disk => PlaybackCacheProfileValues._(
        _diskValues(profile),
      ),
      PlaybackCacheRuntimeMode.disabled => PlaybackCacheProfileValues._(
        _disabledValues(profile, resetValues),
      ),
      PlaybackCacheRuntimeMode.memory ||
      PlaybackCacheRuntimeMode.memoryFallback ||
      PlaybackCacheRuntimeMode.unconfirmed =>
        PlaybackCacheProfileValues.memoryFallback(
          profile,
          resetValues: resetValues,
        ),
    };
  }

  factory PlaybackCacheProfileValues.memoryFallback(
    ResolvedPlaybackCacheProfile profile, {
    required Map<String, String> resetValues,
  }) => PlaybackCacheProfileValues._(_memoryValues(profile, resetValues));

  static Map<String, String> _diskValues(
    ResolvedPlaybackCacheProfile profile,
  ) => {
    'cache': 'yes',
    'cache-on-disk': 'yes',
    'demuxer-cache-dir': profile.sessionDirectory!.path,
    'demuxer-cache-unlink-files': 'immediate',
    'cache-secs': profile.forwardTarget.inSeconds.toString(),
    'demuxer-max-bytes': profile.demuxerForwardMetadataBytes.toString(),
    'demuxer-max-back-bytes': profile.demuxerBackwardMetadataBytes.toString(),
    'demuxer-donate-buffer': 'yes',
    'demuxer-seekable-cache': 'auto',
    'cache-pause': 'yes',
    'cache-pause-wait': '1',
    'stream-buffer-size': profile.streamBufferBytes.toString(),
  };

  static Map<String, String> _memoryValues(
    ResolvedPlaybackCacheProfile profile,
    Map<String, String> resetValues,
  ) => {
    'cache': 'yes',
    'cache-on-disk': 'no',
    'demuxer-cache-dir': resetValues['demuxer-cache-dir'] ?? '',
    'demuxer-cache-unlink-files': 'immediate',
    'cache-secs': profile.forwardTarget.inSeconds.clamp(30, 60).toString(),
    'demuxer-max-bytes': min(
      profile.demuxerForwardMetadataBytes,
      64 * 1024 * 1024,
    ).toString(),
    'demuxer-max-back-bytes': min(
      profile.demuxerBackwardMetadataBytes,
      16 * 1024 * 1024,
    ).toString(),
    'demuxer-donate-buffer': 'yes',
    'demuxer-seekable-cache': 'auto',
    'cache-pause': 'yes',
    'cache-pause-wait': '1',
    'stream-buffer-size': profile.streamBufferBytes.toString(),
  };

  static Map<String, String> _disabledValues(
    ResolvedPlaybackCacheProfile profile,
    Map<String, String> resetValues,
  ) => {
    'cache': 'no',
    'cache-on-disk': 'no',
    'demuxer-cache-dir': resetValues['demuxer-cache-dir'] ?? '',
    'demuxer-cache-unlink-files': 'immediate',
    'cache-secs': '0',
    'demuxer-max-bytes': (16 * 1024 * 1024).toString(),
    'demuxer-max-back-bytes': (8 * 1024 * 1024).toString(),
    'demuxer-donate-buffer': 'yes',
    'demuxer-seekable-cache': 'auto',
    'cache-pause': 'no',
    'cache-pause-wait': '1',
    'stream-buffer-size': (128 * 1024).toString(),
  };
}

class RuntimePlaybackCacheProfileSwitchExperiment
    implements PlaybackCacheProfileSwitchExperiment {
  const RuntimePlaybackCacheProfileSwitchExperiment();

  @override
  Future<PlaybackCacheProfileSwitchStrategy> run({
    required NativePlaybackPropertyAccess access,
    required Map<String, String> resetValues,
  }) async {
    Directory? root;
    try {
      if (!playbackCacheProfileOptionNames.every(resetValues.containsKey)) {
        return PlaybackCacheProfileSwitchStrategy.unsupported;
      }
      root = await Directory.systemTemp.createTemp('emby-mpv-capability-');
      final media = File('${root.path}${Platform.pathSeparator}probe.wav');
      await media.writeAsBytes(_waveProbeData, flush: true);
      final profiles = _switchExperimentProfiles(
        cacheDirectory: root,
        directoryReset: resetValues['demuxer-cache-dir']!,
      );
      for (final profile in profiles) {
        for (final entry in profile.entries) {
          await access.setString(entry.key, entry.value);
        }
        for (final entry in profile.entries) {
          final readBack = await access.getString(entry.key);
          if (readBack == null ||
              !_equivalentNativeValue(readBack, entry.value)) {
            return PlaybackCacheProfileSwitchStrategy.unsupported;
          }
        }
        await access.command(['loadfile', media.path, 'replace']);
        if (!await _waitForIdle(access, expected: false)) {
          return PlaybackCacheProfileSwitchStrategy.unsupported;
        }
        await access.command(const ['stop']);
        if (!await _waitForIdle(access, expected: true)) {
          return PlaybackCacheProfileSwitchStrategy.unsupported;
        }
      }
      return PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop;
    } catch (_) {
      return PlaybackCacheProfileSwitchStrategy.unsupported;
    } finally {
      if (root != null) {
        try {
          await root.delete(recursive: true);
        } catch (_) {
          // A probe residue must not affect playback capability fallback.
        }
      }
    }
  }

  static Future<bool> _waitForIdle(
    NativePlaybackPropertyAccess access, {
    required bool expected,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      final idle = _parseBoolean(await access.getString('idle-active'));
      if (idle == expected) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }
}

List<Map<String, String>> _switchExperimentProfiles({
  required Directory cacheDirectory,
  required String directoryReset,
}) => [
  {
    'cache': 'yes',
    'cache-on-disk': 'yes',
    'demuxer-cache-dir': cacheDirectory.path,
    'demuxer-cache-unlink-files': 'immediate',
    'cache-secs': '30',
    'demuxer-max-bytes': '16777216',
    'demuxer-max-back-bytes': '8388608',
    'demuxer-donate-buffer': 'yes',
    'demuxer-seekable-cache': 'auto',
    'cache-pause': 'yes',
    'cache-pause-wait': '1',
    'stream-buffer-size': '131072',
  },
  {
    'cache': 'yes',
    'cache-on-disk': 'no',
    'demuxer-cache-dir': directoryReset,
    'demuxer-cache-unlink-files': 'immediate',
    'cache-secs': '30',
    'demuxer-max-bytes': '16777216',
    'demuxer-max-back-bytes': '8388608',
    'demuxer-donate-buffer': 'yes',
    'demuxer-seekable-cache': 'auto',
    'cache-pause': 'yes',
    'cache-pause-wait': '1',
    'stream-buffer-size': '131072',
  },
  {
    'cache': 'no',
    'cache-on-disk': 'no',
    'demuxer-cache-dir': directoryReset,
    'demuxer-cache-unlink-files': 'immediate',
    'cache-secs': '0',
    'demuxer-max-bytes': '16777216',
    'demuxer-max-back-bytes': '8388608',
    'demuxer-donate-buffer': 'yes',
    'demuxer-seekable-cache': 'auto',
    'cache-pause': 'no',
    'cache-pause-wait': '1',
    'stream-buffer-size': '131072',
  },
];

bool _equivalentNativeValue(String actual, String expected) {
  final normalizedActual = actual.trim().toLowerCase();
  final normalizedExpected = expected.trim().toLowerCase();
  if (normalizedActual == normalizedExpected) return true;
  final actualNumber = num.tryParse(normalizedActual);
  final expectedNumber = num.tryParse(normalizedExpected);
  return actualNumber != null &&
      expectedNumber != null &&
      actualNumber == expectedNumber;
}

const _waveProbeData = <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x26,
  0x00,
  0x00,
  0x00,
  0x57,
  0x41,
  0x56,
  0x45,
  0x66,
  0x6d,
  0x74,
  0x20,
  0x10,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x40,
  0x1f,
  0x00,
  0x00,
  0x80,
  0x3e,
  0x00,
  0x00,
  0x02,
  0x00,
  0x10,
  0x00,
  0x64,
  0x61,
  0x74,
  0x61,
  0x02,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
];

List<PlaybackCacheRange> _parseRanges(Object? value) {
  if (value is! Iterable) return const [];
  final ranges = <PlaybackCacheRange>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final start = _parseFiniteDouble(entry['start']);
    final end = _parseFiniteDouble(entry['end']);
    if (start == null || end == null || start < 0 || end <= start) continue;
    ranges.add(
      PlaybackCacheRange(
        start: Duration(microseconds: (start * 1000000).round()),
        end: Duration(microseconds: (end * 1000000).round()),
      ),
    );
  }
  ranges.sort((left, right) => left.start.compareTo(right.start));
  return List.unmodifiable(ranges);
}

int? _parseInteger(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is num && value.isFinite) {
    final rounded = value.round();
    return rounded >= 0 ? rounded : null;
  }
  final parsed = int.tryParse(value?.toString().trim() ?? '');
  return parsed != null && parsed >= 0 ? parsed : null;
}

double? _parseFiniteDouble(Object? value) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString().trim() ?? '');
  return parsed != null && parsed.isFinite ? parsed : null;
}

bool? _parseBoolean(Object? value) {
  if (value is bool) return value;
  return switch (value?.toString().trim().toLowerCase()) {
    'yes' || 'true' || '1' => true,
    'no' || 'false' || '0' => false,
    _ => null,
  };
}
