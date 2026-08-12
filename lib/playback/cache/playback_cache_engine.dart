import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'native_playback_property_access.dart';
import 'playback_cache_capabilities.dart';
import 'playback_cache_option_bindings.dart';
import 'playback_cache_policy.dart';
import 'playback_cache_telemetry.dart';

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
    this.telemetryStatus = PlaybackCacheTelemetryStatus.available,
  });

  final int? fileCacheBytes;
  final int? rawInputRateBytesPerSecond;
  final List<PlaybackCacheRange> seekableRanges;
  final bool? pausedForCache;
  final int? cacheBufferingPercent;
  final bool? cacheOnDisk;
  final PlaybackCacheTelemetryStatus telemetryStatus;
}

enum PlaybackCacheEvidence {
  diskDataObserved,
  diskConfiguredOnly,
  memoryProfileConfirmed,
  disabled,
  unconfirmed,
}

class PlaybackCacheProfileApplyPlan {
  const PlaybackCacheProfileApplyPlan({
    required this.criticalValues,
    required this.optionalValues,
    required this.criticalReadBack,
    required this.optionalReadBack,
  });

  final Map<PlaybackCacheLogicalOption, String> criticalValues;
  final Map<PlaybackCacheLogicalOption, String> optionalValues;
  final Set<PlaybackCacheLogicalOption> criticalReadBack;
  final Set<PlaybackCacheLogicalOption> optionalReadBack;
}

class PlaybackCacheApplyResult {
  const PlaybackCacheApplyResult({
    required this.requestedMode,
    required this.actualMode,
    required this.fallbackReason,
    required this.requiresPlayerRecreation,
    required this.readBack,
    this.optionalTuningDegraded = false,
    this.optionalTuningUnavailable = const {},
    this.cacheEvidence = PlaybackCacheEvidence.unconfirmed,
  });

  final PlaybackCacheRuntimeMode requestedMode;
  final PlaybackCacheRuntimeMode actualMode;
  final PlaybackCacheFallbackReason fallbackReason;
  final bool requiresPlayerRecreation;
  final Map<String, String> readBack;
  final bool optionalTuningDegraded;
  final Set<PlaybackCacheLogicalOption> optionalTuningUnavailable;
  final PlaybackCacheEvidence cacheEvidence;
}

abstract interface class PlaybackCacheEngine {
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities();

  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  );

  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot();
}

abstract interface class PlaybackCacheGenerationSnapshotReader {
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshotForGeneration({
    required int generation,
    required bool Function(int generation) isGenerationCurrent,
  });
}

class NativePlaybackCacheEngine
    implements PlaybackCacheEngine, PlaybackCacheGenerationSnapshotReader {
  NativePlaybackCacheEngine({
    required this.access,
    required bool Function() hasOpenedMedia,
    PlaybackCacheTelemetryReader? telemetryReader,
  }) : _hasOpenedMedia = hasOpenedMedia,
       _telemetry = PlaybackCacheTelemetryReadCoordinator(
         reader:
             telemetryReader ??
             NativePlaybackCacheTelemetryReader(access: access),
       );

  final NativePlaybackPropertyAccess access;
  final bool Function() _hasOpenedMedia;
  final PlaybackCacheTelemetryReadCoordinator _telemetry;
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
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() =>
      readCacheSnapshotForGeneration(
        generation: 0,
        isGenerationCurrent: (_) => true,
      );

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshotForGeneration({
    required int generation,
    required bool Function(int generation) isGenerationCurrent,
  }) async {
    final telemetry = await _telemetry.readForGeneration(
      generation: generation,
      isGenerationCurrent: isGenerationCurrent,
    );
    if (telemetry == null) return null;
    try {
      final cacheOnDisk = _parseBoolean(
        await access.getString('cache-on-disk'),
      );
      final paused = _parseBoolean(await access.getString('paused-for-cache'));
      final buffering = _parseInteger(
        await access.getString('cache-buffering-state'),
      );
      if (!isGenerationCurrent(generation)) return null;
      final state = telemetry.state;
      return PlaybackCacheEngineSnapshot(
        fileCacheBytes: state?.fileCacheBytes,
        rawInputRateBytesPerSecond: state?.rawInputRateBytesPerSecond,
        seekableRanges: [
          for (final range in state?.seekableRanges ?? const [])
            PlaybackCacheRange(start: range.start, end: range.end),
        ],
        pausedForCache: paused,
        cacheBufferingPercent: buffering,
        cacheOnDisk: cacheOnDisk,
        telemetryStatus: telemetry.status,
      );
    } catch (_) {
      return PlaybackCacheEngineSnapshot(
        fileCacheBytes: null,
        rawInputRateBytesPerSecond: null,
        seekableRanges: const [],
        pausedForCache: null,
        cacheBufferingPercent: null,
        cacheOnDisk: null,
        telemetryStatus: PlaybackCacheTelemetryStatus.readFailed,
      );
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

    final PlaybackCacheProfileApplyPlan plan;
    try {
      plan = PlaybackCacheProfileValues.fromProfile(
        profile,
        bindings: capabilities.bindings,
      ).plan;
    } catch (_) {
      return _unconfirmed(requestedMode);
    }
    final applied = await _writeAndReadBack(plan);
    if (applied != null) {
      return PlaybackCacheApplyResult(
        requestedMode: requestedMode,
        actualMode: requestedMode,
        fallbackReason: profile.fallbackReason,
        requiresPlayerRecreation: false,
        readBack: Map.unmodifiable(applied.readBack),
        optionalTuningDegraded: applied.optionalTuningDegraded,
        optionalTuningUnavailable: applied.optionalTuningUnavailable,
        cacheEvidence: _evidenceFor(requestedMode, applied.readBack),
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
    final PlaybackCacheProfileApplyPlan fallback;
    try {
      fallback = PlaybackCacheProfileValues.memoryFallback(
        original,
        bindings: capabilities.bindings,
      ).plan;
    } catch (_) {
      return _unconfirmed(original.runtimeMode);
    }
    final applied = await _writeAndReadBack(fallback);
    if (applied == null) {
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
      readBack: Map.unmodifiable(applied.readBack),
      optionalTuningDegraded: applied.optionalTuningDegraded,
      optionalTuningUnavailable: applied.optionalTuningUnavailable,
      cacheEvidence: _evidenceFor(
        PlaybackCacheRuntimeMode.memoryFallback,
        applied.readBack,
      ),
    );
  }

  PlaybackCacheApplyResult _unconfirmed(
    PlaybackCacheRuntimeMode requestedMode,
  ) => PlaybackCacheApplyResult(
    requestedMode: requestedMode,
    actualMode: PlaybackCacheRuntimeMode.unconfirmed,
    fallbackReason: PlaybackCacheFallbackReason.actualModeUnconfirmed,
    requiresPlayerRecreation: false,
    readBack: const {},
  );

  Future<_AppliedPlan?> _writeAndReadBack(
    PlaybackCacheProfileApplyPlan plan,
  ) async {
    final readBack = <String, String>{};
    for (final option in plan.criticalValues.keys) {
      final nativeName = capabilities.bindings.nativeName(option);
      final expected = plan.criticalValues[option];
      if (nativeName == null || expected == null) return null;
      try {
        await access.setString(nativeName, expected);
      } catch (_) {
        return null;
      }
    }
    for (final option in plan.criticalReadBack) {
      final nativeName = capabilities.bindings.nativeName(option);
      final expected = plan.criticalValues[option];
      if (nativeName == null || expected == null) return null;
      try {
        final value = await access.getString(nativeName);
        if (value == null || !_equivalent(option, value, expected)) {
          return null;
        }
        readBack[nativeName] = value;
      } catch (_) {
        return null;
      }
    }

    var optionalTuningDegraded = false;
    final unavailable = <PlaybackCacheLogicalOption>{
      ...capabilities.bindings.optionalTuningUnavailable,
    };
    for (final option in plan.optionalValues.keys) {
      final nativeName = capabilities.bindings.nativeName(option);
      final expected = plan.optionalValues[option];
      if (nativeName == null || expected == null) {
        optionalTuningDegraded = true;
        unavailable.add(option);
        continue;
      }
      try {
        await access.setString(nativeName, expected);
      } catch (_) {
        optionalTuningDegraded = true;
        unavailable.add(option);
      }
    }
    for (final option in plan.optionalReadBack) {
      final nativeName = capabilities.bindings.nativeName(option);
      final expected = plan.optionalValues[option];
      if (nativeName == null || expected == null) {
        optionalTuningDegraded = true;
        unavailable.add(option);
        continue;
      }
      try {
        final value = await access.getString(nativeName);
        if (value == null || !_equivalent(option, value, expected)) {
          optionalTuningDegraded = true;
          unavailable.add(option);
          continue;
        }
        readBack[nativeName] = value;
      } catch (_) {
        optionalTuningDegraded = true;
        unavailable.add(option);
      }
    }
    return _AppliedPlan(
      readBack: readBack,
      optionalTuningDegraded: optionalTuningDegraded,
      optionalTuningUnavailable: unavailable,
    );
  }

  bool _equivalent(
    PlaybackCacheLogicalOption option,
    String actual,
    String expected,
  ) => playbackNativeValueCanonicalizer.equivalent(option, actual, expected);

  static PlaybackCacheEvidence _evidenceFor(
    PlaybackCacheRuntimeMode mode,
    Map<String, String> readBack,
  ) {
    if (mode == PlaybackCacheRuntimeMode.disabled &&
        readBack['cache'] != null) {
      return PlaybackCacheEvidence.disabled;
    }
    if ((mode == PlaybackCacheRuntimeMode.memory ||
            mode == PlaybackCacheRuntimeMode.memoryFallback) &&
        _isEnabled(readBack['cache']) &&
        _isDisabled(readBack['cache-on-disk'])) {
      return PlaybackCacheEvidence.memoryProfileConfirmed;
    }
    if (mode == PlaybackCacheRuntimeMode.disk &&
        _isEnabled(readBack['cache-on-disk'])) {
      return PlaybackCacheEvidence.diskConfiguredOnly;
    }
    return PlaybackCacheEvidence.unconfirmed;
  }

  static bool _isEnabled(String? value) =>
      value != null &&
      const {'yes', 'true', '1'}.contains(value.trim().toLowerCase());

  static bool _isDisabled(String? value) =>
      value != null &&
      const {'no', 'false', '0'}.contains(value.trim().toLowerCase());
}

class _AppliedPlan {
  const _AppliedPlan({
    required this.readBack,
    required this.optionalTuningDegraded,
    required this.optionalTuningUnavailable,
  });

  final Map<String, String> readBack;
  final bool optionalTuningDegraded;
  final Set<PlaybackCacheLogicalOption> optionalTuningUnavailable;
}

class PlaybackCacheProfileValues {
  const PlaybackCacheProfileValues._(this.plan);

  final PlaybackCacheProfileApplyPlan plan;

  factory PlaybackCacheProfileValues.fromProfile(
    ResolvedPlaybackCacheProfile profile, {
    required ResolvedPlaybackCacheOptionBindings bindings,
  }) {
    return switch (profile.runtimeMode) {
      PlaybackCacheRuntimeMode.disk => PlaybackCacheProfileValues._(
        _diskValues(profile, bindings),
      ),
      PlaybackCacheRuntimeMode.disabled => PlaybackCacheProfileValues._(
        _disabledValues(profile, bindings),
      ),
      PlaybackCacheRuntimeMode.memory ||
      PlaybackCacheRuntimeMode.memoryFallback ||
      PlaybackCacheRuntimeMode.unconfirmed =>
        PlaybackCacheProfileValues.memoryFallback(profile, bindings: bindings),
    };
  }

  factory PlaybackCacheProfileValues.memoryFallback(
    ResolvedPlaybackCacheProfile profile, {
    required ResolvedPlaybackCacheOptionBindings bindings,
  }) => PlaybackCacheProfileValues._(_memoryValues(profile, bindings));

  static PlaybackCacheProfileApplyPlan _diskValues(
    ResolvedPlaybackCacheProfile profile,
    ResolvedPlaybackCacheOptionBindings bindings,
  ) => _valuesFor(
    bindings,
    critical: {
      PlaybackCacheLogicalOption.cache: 'yes',
      PlaybackCacheLogicalOption.cacheOnDisk: 'yes',
      PlaybackCacheLogicalOption.cacheDirectory: profile.sessionDirectory!.path,
      PlaybackCacheLogicalOption.cacheUnlinkFiles: 'immediate',
      PlaybackCacheLogicalOption.cacheSeconds: profile.forwardTarget.inSeconds
          .toString(),
      PlaybackCacheLogicalOption.forwardMetadataBytes: profile
          .demuxerForwardMetadataBytes
          .toString(),
      PlaybackCacheLogicalOption.backwardMetadataBytes: profile
          .demuxerBackwardMetadataBytes
          .toString(),
    },
    optional: _optionalValues(profile),
  );

  static PlaybackCacheProfileApplyPlan _memoryValues(
    ResolvedPlaybackCacheProfile profile,
    ResolvedPlaybackCacheOptionBindings bindings,
  ) => _valuesFor(
    bindings,
    critical: {
      PlaybackCacheLogicalOption.cache: 'yes',
      PlaybackCacheLogicalOption.cacheOnDisk: 'no',
      PlaybackCacheLogicalOption.cacheSeconds: profile.forwardTarget.inSeconds
          .clamp(30, 60)
          .toString(),
      PlaybackCacheLogicalOption.forwardMetadataBytes: min(
        profile.demuxerForwardMetadataBytes,
        64 * 1024 * 1024,
      ).toString(),
      PlaybackCacheLogicalOption.backwardMetadataBytes: min(
        profile.demuxerBackwardMetadataBytes,
        16 * 1024 * 1024,
      ).toString(),
    },
    optional: {..._optionalValues(profile), ..._resetOptionalValues(bindings)},
  );

  static PlaybackCacheProfileApplyPlan _disabledValues(
    ResolvedPlaybackCacheProfile profile,
    ResolvedPlaybackCacheOptionBindings bindings,
  ) => _valuesFor(
    bindings,
    critical: {PlaybackCacheLogicalOption.cache: 'no'},
    optional: {
      PlaybackCacheLogicalOption.cacheOnDisk: 'no',
      PlaybackCacheLogicalOption.cacheSeconds: '0',
      PlaybackCacheLogicalOption.forwardMetadataBytes: '${16 * 1024 * 1024}',
      PlaybackCacheLogicalOption.backwardMetadataBytes: '${8 * 1024 * 1024}',
      PlaybackCacheLogicalOption.cachePause: 'no',
      PlaybackCacheLogicalOption.streamBufferSize: '${128 * 1024}',
      ..._resetOptionalValues(bindings),
    },
  );

  static Map<PlaybackCacheLogicalOption, String> _optionalValues(
    ResolvedPlaybackCacheProfile profile,
  ) => {
    PlaybackCacheLogicalOption.donateBuffer: profile.donateBuffer
        ? 'yes'
        : 'no',
    PlaybackCacheLogicalOption.seekableCache: 'auto',
    PlaybackCacheLogicalOption.cachePause: 'yes',
    PlaybackCacheLogicalOption.cachePauseWait: '1',
    PlaybackCacheLogicalOption.streamBufferSize: profile.streamBufferBytes
        .toString(),
  };

  static Map<PlaybackCacheLogicalOption, String> _resetOptionalValues(
    ResolvedPlaybackCacheOptionBindings bindings,
  ) => {
    if (bindings.resetValue(PlaybackCacheLogicalOption.cacheDirectory) != null)
      PlaybackCacheLogicalOption.cacheDirectory: bindings.resetValue(
        PlaybackCacheLogicalOption.cacheDirectory,
      )!,
    if (bindings.resetValue(PlaybackCacheLogicalOption.cacheUnlinkFiles) !=
        null)
      PlaybackCacheLogicalOption.cacheUnlinkFiles: bindings.resetValue(
        PlaybackCacheLogicalOption.cacheUnlinkFiles,
      )!,
  };

  static PlaybackCacheProfileApplyPlan _valuesFor(
    ResolvedPlaybackCacheOptionBindings bindings, {
    required Map<PlaybackCacheLogicalOption, String> critical,
    required Map<PlaybackCacheLogicalOption, String> optional,
  }) {
    final availableCritical = <PlaybackCacheLogicalOption, String>{};
    for (final entry in critical.entries) {
      if (!bindings.supports(entry.key)) {
        throw StateError('Missing critical option');
      }
      availableCritical[entry.key] = entry.value;
    }
    final availableOptional = <PlaybackCacheLogicalOption, String>{};
    for (final entry in optional.entries) {
      if (bindings.supports(entry.key)) {
        availableOptional[entry.key] = entry.value;
      }
    }
    return PlaybackCacheProfileApplyPlan(
      criticalValues: availableCritical,
      optionalValues: availableOptional,
      criticalReadBack: availableCritical.keys.toSet(),
      optionalReadBack: availableOptional.keys.toSet(),
    );
  }
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
      final nativeNames = <PlaybackCacheLogicalOption, String>{};
      final logicalResetValues = <PlaybackCacheLogicalOption, String>{};
      for (final option in playbackCacheLogicalOptions) {
        for (final candidate in playbackCacheNativeOptionCandidates[option]!) {
          final reset = resetValues[candidate];
          if (reset == null) continue;
          nativeNames[option] = candidate;
          logicalResetValues[option] = reset;
          break;
        }
      }
      if (!playbackCacheRequiredDiskLogicalOptions.every(
        nativeNames.containsKey,
      )) {
        return PlaybackCacheProfileSwitchStrategy.unsupported;
      }
      root = await Directory.systemTemp.createTemp('emby-mpv-capability-');
      final media = File('${root.path}${Platform.pathSeparator}probe.wav');
      await media.writeAsBytes(_waveProbeData, flush: true);
      final profiles = _switchExperimentProfiles(
        cacheDirectory: root,
        nativeNames: nativeNames,
        directoryReset:
            logicalResetValues[PlaybackCacheLogicalOption.cacheDirectory]!,
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
  required Map<PlaybackCacheLogicalOption, String> nativeNames,
  required String directoryReset,
}) {
  final profiles = <Map<PlaybackCacheLogicalOption, String>>[
    {
      PlaybackCacheLogicalOption.cache: 'yes',
      PlaybackCacheLogicalOption.cacheOnDisk: 'yes',
      PlaybackCacheLogicalOption.cacheDirectory: cacheDirectory.path,
      PlaybackCacheLogicalOption.cacheUnlinkFiles: 'immediate',
      PlaybackCacheLogicalOption.cacheSeconds: '30',
      PlaybackCacheLogicalOption.forwardMetadataBytes: '16777216',
      PlaybackCacheLogicalOption.backwardMetadataBytes: '8388608',
      PlaybackCacheLogicalOption.donateBuffer: 'yes',
      PlaybackCacheLogicalOption.seekableCache: 'auto',
      PlaybackCacheLogicalOption.cachePause: 'yes',
      PlaybackCacheLogicalOption.cachePauseWait: '1',
      PlaybackCacheLogicalOption.streamBufferSize: '131072',
    },
    {
      PlaybackCacheLogicalOption.cache: 'yes',
      PlaybackCacheLogicalOption.cacheOnDisk: 'no',
      PlaybackCacheLogicalOption.cacheDirectory: directoryReset,
      PlaybackCacheLogicalOption.cacheUnlinkFiles: 'immediate',
      PlaybackCacheLogicalOption.cacheSeconds: '30',
      PlaybackCacheLogicalOption.forwardMetadataBytes: '16777216',
      PlaybackCacheLogicalOption.backwardMetadataBytes: '8388608',
      PlaybackCacheLogicalOption.donateBuffer: 'yes',
      PlaybackCacheLogicalOption.seekableCache: 'auto',
      PlaybackCacheLogicalOption.cachePause: 'yes',
      PlaybackCacheLogicalOption.cachePauseWait: '1',
      PlaybackCacheLogicalOption.streamBufferSize: '131072',
    },
    {
      PlaybackCacheLogicalOption.cache: 'no',
      PlaybackCacheLogicalOption.cacheOnDisk: 'no',
      PlaybackCacheLogicalOption.cacheDirectory: directoryReset,
      PlaybackCacheLogicalOption.cacheUnlinkFiles: 'immediate',
      PlaybackCacheLogicalOption.cacheSeconds: '0',
      PlaybackCacheLogicalOption.forwardMetadataBytes: '16777216',
      PlaybackCacheLogicalOption.backwardMetadataBytes: '8388608',
      PlaybackCacheLogicalOption.donateBuffer: 'yes',
      PlaybackCacheLogicalOption.seekableCache: 'auto',
      PlaybackCacheLogicalOption.cachePause: 'no',
      PlaybackCacheLogicalOption.cachePauseWait: '1',
      PlaybackCacheLogicalOption.streamBufferSize: '131072',
    },
  ];
  return [
    for (final profile in profiles)
      {
        for (final entry in profile.entries)
          if (nativeNames.containsKey(entry.key))
            nativeNames[entry.key]!: entry.value,
      },
  ];
}

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

int? _parseInteger(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is num && value.isFinite) {
    final rounded = value.round();
    return rounded >= 0 ? rounded : null;
  }
  final parsed = int.tryParse(value?.toString().trim() ?? '');
  return parsed != null && parsed >= 0 ? parsed : null;
}

bool? _parseBoolean(Object? value) {
  if (value is bool) return value;
  return switch (value?.toString().trim().toLowerCase()) {
    'yes' || 'true' || '1' => true,
    'no' || 'false' || '0' => false,
    _ => null,
  };
}
