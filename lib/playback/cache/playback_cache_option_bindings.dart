enum PlaybackCacheLogicalOption {
  cache,
  cacheOnDisk,
  cacheDirectory,
  cacheUnlinkFiles,
  cacheSeconds,
  forwardMetadataBytes,
  backwardMetadataBytes,
  donateBuffer,
  seekableCache,
  cachePause,
  cachePauseWait,
  streamBufferSize,
}

enum PlaybackNativeOptionVariant { modern, legacy, unavailable }

enum PlaybackNativeOptionCandidateStatus {
  unavailable,
  presentButIncomplete,
  usable,
}

enum PlaybackNativeValueKind { boolean, number, enumValue, path, rawString }

class PlaybackNativeOptionCandidateEvidence {
  const PlaybackNativeOptionCandidateEvidence({
    required this.nativeName,
    required this.status,
    required this.optionExists,
    required this.resetAvailable,
    required this.requiredChoiceAvailable,
    required this.writeReadBackPassed,
  });

  final String nativeName;
  final PlaybackNativeOptionCandidateStatus status;
  final bool optionExists;
  final bool resetAvailable;
  final bool requiredChoiceAvailable;
  final bool writeReadBackPassed;
}

class ResolvedPlaybackCacheOptionBindings {
  ResolvedPlaybackCacheOptionBindings({
    required Map<PlaybackCacheLogicalOption, String> nativeNames,
    required Map<PlaybackCacheLogicalOption, String> resetValues,
    required Set<PlaybackCacheLogicalOption> supported,
    required Set<PlaybackCacheLogicalOption> optionalTuningUnavailable,
    required Map<
      PlaybackCacheLogicalOption,
      List<PlaybackNativeOptionCandidateEvidence>
    >
    evidence,
  }) : nativeNames = Map.unmodifiable(nativeNames),
       resetValues = Map.unmodifiable(resetValues),
       supported = Set.unmodifiable(supported),
       optionalTuningUnavailable = Set.unmodifiable(optionalTuningUnavailable),
       evidence =
           Map<
             PlaybackCacheLogicalOption,
             List<PlaybackNativeOptionCandidateEvidence>
           >.unmodifiable({
             for (final entry in evidence.entries)
               entry.key:
                   List<PlaybackNativeOptionCandidateEvidence>.unmodifiable(
                     entry.value,
                   ),
           });

  final Map<PlaybackCacheLogicalOption, String> nativeNames;
  final Map<PlaybackCacheLogicalOption, String> resetValues;
  final Set<PlaybackCacheLogicalOption> supported;
  final Set<PlaybackCacheLogicalOption> optionalTuningUnavailable;
  final Map<
    PlaybackCacheLogicalOption,
    List<PlaybackNativeOptionCandidateEvidence>
  >
  evidence;

  ResolvedPlaybackCacheOptionBindings withEvidence(
    Map<PlaybackCacheLogicalOption, List<PlaybackNativeOptionCandidateEvidence>>
    nextEvidence,
  ) => ResolvedPlaybackCacheOptionBindings(
    nativeNames: nativeNames,
    resetValues: resetValues,
    supported: supported,
    optionalTuningUnavailable: optionalTuningUnavailable,
    evidence: nextEvidence,
  );

  String? nativeName(PlaybackCacheLogicalOption option) => nativeNames[option];

  String? resetValue(PlaybackCacheLogicalOption option) => resetValues[option];

  String? resetValueForNative(String nativeName) {
    final option = playbackCacheLogicalOptionForNativeName(nativeName);
    return option == null ? null : resetValues[option];
  }

  bool supports(PlaybackCacheLogicalOption option) =>
      supported.contains(option);

  PlaybackNativeOptionVariant variantFor(PlaybackCacheLogicalOption option) {
    final name = nativeNames[option];
    if (name == null) return PlaybackNativeOptionVariant.unavailable;
    final candidates = playbackCacheNativeOptionCandidates[option]!;
    return candidates.first == name
        ? PlaybackNativeOptionVariant.modern
        : PlaybackNativeOptionVariant.legacy;
  }

  PlaybackNativeOptionCandidateStatus statusFor(
    PlaybackCacheLogicalOption option,
    int candidateIndex,
  ) {
    final candidates = evidence[option] ?? const [];
    if (candidateIndex < 0 || candidateIndex >= candidates.length) {
      return PlaybackNativeOptionCandidateStatus.unavailable;
    }
    return candidates[candidateIndex].status;
  }

  Map<String, Object> toSafeDiagnosticManifest() => {
    for (final option in playbackCacheLogicalOptions)
      'option_${option.name}': supports(option),
    'cacheDirectoryVariant': variantFor(
      PlaybackCacheLogicalOption.cacheDirectory,
    ).name,
    'cacheDirectoryModernStatus': statusFor(
      PlaybackCacheLogicalOption.cacheDirectory,
      0,
    ).name.replaceAll('presentButIncomplete', 'incomplete'),
    'cacheDirectoryLegacyStatus': statusFor(
      PlaybackCacheLogicalOption.cacheDirectory,
      1,
    ).name.replaceAll('presentButIncomplete', 'incomplete'),
    'cacheUnlinkVariant': variantFor(
      PlaybackCacheLogicalOption.cacheUnlinkFiles,
    ).name,
    'cacheUnlinkModernStatus': statusFor(
      PlaybackCacheLogicalOption.cacheUnlinkFiles,
      0,
    ).name.replaceAll('presentButIncomplete', 'incomplete'),
    'cacheUnlinkLegacyStatus': statusFor(
      PlaybackCacheLogicalOption.cacheUnlinkFiles,
      1,
    ).name.replaceAll('presentButIncomplete', 'incomplete'),
  };
}

const playbackCacheLogicalOptions = <PlaybackCacheLogicalOption>[
  PlaybackCacheLogicalOption.cache,
  PlaybackCacheLogicalOption.cacheOnDisk,
  PlaybackCacheLogicalOption.cacheDirectory,
  PlaybackCacheLogicalOption.cacheUnlinkFiles,
  PlaybackCacheLogicalOption.cacheSeconds,
  PlaybackCacheLogicalOption.forwardMetadataBytes,
  PlaybackCacheLogicalOption.backwardMetadataBytes,
  PlaybackCacheLogicalOption.donateBuffer,
  PlaybackCacheLogicalOption.seekableCache,
  PlaybackCacheLogicalOption.cachePause,
  PlaybackCacheLogicalOption.cachePauseWait,
  PlaybackCacheLogicalOption.streamBufferSize,
];

const playbackCacheOptionalTuningOptions = <PlaybackCacheLogicalOption>[
  PlaybackCacheLogicalOption.donateBuffer,
  PlaybackCacheLogicalOption.seekableCache,
  PlaybackCacheLogicalOption.cachePause,
  PlaybackCacheLogicalOption.cachePauseWait,
  PlaybackCacheLogicalOption.streamBufferSize,
];

const playbackCacheNativeOptionCandidates =
    <PlaybackCacheLogicalOption, List<String>>{
      PlaybackCacheLogicalOption.cache: ['cache'],
      PlaybackCacheLogicalOption.cacheOnDisk: ['cache-on-disk'],
      PlaybackCacheLogicalOption.cacheDirectory: [
        'demuxer-cache-dir',
        'cache-dir',
      ],
      PlaybackCacheLogicalOption.cacheUnlinkFiles: [
        'demuxer-cache-unlink-files',
        'cache-unlink-files',
      ],
      PlaybackCacheLogicalOption.cacheSeconds: ['cache-secs'],
      PlaybackCacheLogicalOption.forwardMetadataBytes: ['demuxer-max-bytes'],
      PlaybackCacheLogicalOption.backwardMetadataBytes: [
        'demuxer-max-back-bytes',
      ],
      PlaybackCacheLogicalOption.donateBuffer: ['demuxer-donate-buffer'],
      PlaybackCacheLogicalOption.seekableCache: ['demuxer-seekable-cache'],
      PlaybackCacheLogicalOption.cachePause: ['cache-pause'],
      PlaybackCacheLogicalOption.cachePauseWait: ['cache-pause-wait'],
      PlaybackCacheLogicalOption.streamBufferSize: ['stream-buffer-size'],
    };

const playbackCacheLogicalValueKinds =
    <PlaybackCacheLogicalOption, PlaybackNativeValueKind>{
      PlaybackCacheLogicalOption.cache: PlaybackNativeValueKind.enumValue,
      PlaybackCacheLogicalOption.cacheOnDisk: PlaybackNativeValueKind.boolean,
      PlaybackCacheLogicalOption.cacheDirectory: PlaybackNativeValueKind.path,
      PlaybackCacheLogicalOption.cacheUnlinkFiles:
          PlaybackNativeValueKind.enumValue,
      PlaybackCacheLogicalOption.cacheSeconds: PlaybackNativeValueKind.number,
      PlaybackCacheLogicalOption.forwardMetadataBytes:
          PlaybackNativeValueKind.number,
      PlaybackCacheLogicalOption.backwardMetadataBytes:
          PlaybackNativeValueKind.number,
      PlaybackCacheLogicalOption.donateBuffer: PlaybackNativeValueKind.boolean,
      PlaybackCacheLogicalOption.seekableCache:
          PlaybackNativeValueKind.enumValue,
      PlaybackCacheLogicalOption.cachePause: PlaybackNativeValueKind.boolean,
      PlaybackCacheLogicalOption.cachePauseWait: PlaybackNativeValueKind.number,
      PlaybackCacheLogicalOption.streamBufferSize:
          PlaybackNativeValueKind.number,
    };

const _booleanValues = <String, String>{
  'yes': 'true',
  'true': 'true',
  '1': 'true',
  'no': 'false',
  'false': 'false',
  '0': 'false',
};

final class PlaybackNativeValueCanonicalizer {
  const PlaybackNativeValueCanonicalizer();

  String? canonicalize(PlaybackCacheLogicalOption option, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty &&
        playbackCacheLogicalValueKinds[option] !=
            PlaybackNativeValueKind.path) {
      return null;
    }
    if (trimmed.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return null;
    }
    return switch (playbackCacheLogicalValueKinds[option]) {
      PlaybackNativeValueKind.boolean => _booleanValues[trimmed.toLowerCase()],
      PlaybackNativeValueKind.number => _canonicalNumber(trimmed),
      PlaybackNativeValueKind.enumValue => _canonicalEnum(option, trimmed),
      PlaybackNativeValueKind.path => _canonicalPath(trimmed),
      PlaybackNativeValueKind.rawString => trimmed,
      null => null,
    };
  }

  bool equivalent(
    PlaybackCacheLogicalOption option,
    String actual,
    String expected,
  ) {
    final left = canonicalize(option, actual);
    final right = canonicalize(option, expected);
    return left != null && left == right;
  }
}

const playbackNativeValueCanonicalizer = PlaybackNativeValueCanonicalizer();

String? _canonicalNumber(String raw) {
  final parsed = double.tryParse(raw);
  if (parsed == null ||
      !parsed.isFinite ||
      parsed != parsed.truncateToDouble()) {
    return null;
  }
  return parsed.toInt().toString();
}

String? _canonicalEnum(PlaybackCacheLogicalOption option, String raw) {
  final value = raw.toLowerCase();
  final allowed = switch (option) {
    PlaybackCacheLogicalOption.cache => const {'auto', 'yes', 'no'},
    PlaybackCacheLogicalOption.cacheUnlinkFiles => const {
      'no',
      'whendone',
      'immediate',
    },
    PlaybackCacheLogicalOption.seekableCache => const {'auto', 'yes', 'no'},
    _ => const <String>{},
  };
  return allowed.contains(value) ? value : null;
}

String? _canonicalPath(String raw) {
  if (raw.isEmpty) return '';
  final unified = raw.replaceAll('\\', '/');
  final prefix = unified.startsWith('/') ? '/' : '';
  final segments = <String>[];
  for (final segment in unified.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty && segments.last != '..') {
        segments.removeLast();
      } else if (prefix.isEmpty) {
        segments.add(segment);
      }
      continue;
    }
    segments.add(segment);
  }
  final normalized = '$prefix${segments.join('/')}';
  if (normalized.isEmpty) return prefix.isEmpty ? '' : '/';
  if (normalized.length > 1 && normalized.endsWith('/')) {
    return normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

PlaybackNativeOptionCandidateStatus _candidateStatus({
  required PlaybackCacheLogicalOption option,
  required bool optionExists,
  required bool resetAvailable,
  required bool requiredChoiceAvailable,
  required bool writeReadBackPassed,
}) {
  if (!optionExists) return PlaybackNativeOptionCandidateStatus.unavailable;
  final resetRequired =
      option == PlaybackCacheLogicalOption.cacheDirectory ||
      option == PlaybackCacheLogicalOption.cacheUnlinkFiles;
  if ((resetRequired && !resetAvailable) ||
      (option == PlaybackCacheLogicalOption.cacheUnlinkFiles &&
          !requiredChoiceAvailable) ||
      !writeReadBackPassed) {
    return PlaybackNativeOptionCandidateStatus.presentButIncomplete;
  }
  return PlaybackNativeOptionCandidateStatus.usable;
}

ResolvedPlaybackCacheOptionBindings resolvePlaybackCacheOptionBindings({
  required Map<String, bool> optionSupport,
  required Map<String, String> resetValues,
  Map<String, bool> requiredChoiceAvailable = const {},
  Map<String, bool> writeReadBackPassed = const {},
}) {
  final nativeNames = <PlaybackCacheLogicalOption, String>{};
  final selectedResets = <PlaybackCacheLogicalOption, String>{};
  final supported = <PlaybackCacheLogicalOption>{};
  final optionalUnavailable = <PlaybackCacheLogicalOption>{};
  final allEvidence =
      <
        PlaybackCacheLogicalOption,
        List<PlaybackNativeOptionCandidateEvidence>
      >{};

  for (final option in playbackCacheLogicalOptions) {
    final candidates = playbackCacheNativeOptionCandidates[option]!;
    final evidence = <PlaybackNativeOptionCandidateEvidence>[];
    for (final candidate in candidates) {
      final exists = optionSupport[candidate] == true;
      final hasReset = resetValues.containsKey(candidate);
      final choice = requiredChoiceAvailable[candidate] ?? true;
      final resetRequired =
          option == PlaybackCacheLogicalOption.cacheDirectory ||
          option == PlaybackCacheLogicalOption.cacheUnlinkFiles;
      final readBack =
          writeReadBackPassed[candidate] ??
          (exists && (!resetRequired || hasReset));
      evidence.add(
        PlaybackNativeOptionCandidateEvidence(
          nativeName: candidate,
          status: _candidateStatus(
            option: option,
            optionExists: exists,
            resetAvailable: hasReset,
            requiredChoiceAvailable: choice,
            writeReadBackPassed: readBack,
          ),
          optionExists: exists,
          resetAvailable: hasReset,
          requiredChoiceAvailable: choice,
          writeReadBackPassed: readBack,
        ),
      );
      if (nativeNames.containsKey(option)) continue;
      if (evidence.last.status == PlaybackNativeOptionCandidateStatus.usable &&
          (playbackCacheOptionalTuningOptions.contains(option) ||
              option == PlaybackCacheLogicalOption.cache ||
              option == PlaybackCacheLogicalOption.cacheOnDisk ||
              option == PlaybackCacheLogicalOption.cacheDirectory ||
              option == PlaybackCacheLogicalOption.cacheUnlinkFiles ||
              option == PlaybackCacheLogicalOption.cacheSeconds ||
              option == PlaybackCacheLogicalOption.forwardMetadataBytes ||
              option == PlaybackCacheLogicalOption.backwardMetadataBytes)) {
        nativeNames[option] = candidate;
        final reset = resetValues[candidate];
        if (reset != null) selectedResets[option] = reset;
        supported.add(option);
      }
    }
    if (supported.contains(option) &&
        playbackCacheOptionalTuningOptions.contains(option)) {
      final selectedName = nativeNames[option];
      if (selectedName == null || !resetValues.containsKey(selectedName)) {
        optionalUnavailable.add(option);
      }
    }
    if (!supported.contains(option) &&
        playbackCacheOptionalTuningOptions.contains(option)) {
      optionalUnavailable.add(option);
    }
    allEvidence[option] = evidence;
  }

  return ResolvedPlaybackCacheOptionBindings(
    nativeNames: nativeNames,
    resetValues: selectedResets,
    supported: supported,
    optionalTuningUnavailable: optionalUnavailable,
    evidence: allEvidence,
  );
}

ResolvedPlaybackCacheOptionBindings bindingsFromNativeMaps({
  required Map<String, bool> optionSupport,
  required Map<String, String> resetValues,
}) => resolvePlaybackCacheOptionBindings(
  optionSupport: optionSupport,
  resetValues: resetValues,
);

String? nativeNameFor(
  PlaybackCacheLogicalOption option,
  Map<PlaybackCacheLogicalOption, String> names,
) => names[option];

String safeOptionVariant(PlaybackNativeOptionVariant variant) => variant.name;

PlaybackCacheLogicalOption? playbackCacheLogicalOptionForNativeName(
  String nativeName,
) {
  for (final entry in playbackCacheNativeOptionCandidates.entries) {
    if (entry.value.contains(nativeName)) return entry.key;
  }
  return null;
}
