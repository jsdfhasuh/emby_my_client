import 'dart:io';
import 'dart:math';

import '../../models/emby_models.dart';
import 'playback_cache_capabilities.dart';
import 'playback_cache_settings.dart';
import 'playback_cache_storage.dart';

enum PlaybackCacheRuntimeMode {
  disabled,
  memory,
  disk,
  memoryFallback,
  unconfirmed,
}

enum PlaybackCacheReadAheadStrategy { boundedWindow, mediaEnd }

enum PlaybackCacheBudgetPolicy { boundedReopen, lowSpaceOnly }

enum PlaybackCacheSizeConfidence { serverDeclared, estimated, unknown }

enum PlaybackCacheFallbackReason {
  none,
  offlineMedia,
  liveOrUnknownLength,
  segmentedTransport,
  insufficientSpace,
  storageCapacityUnknown,
  directoryUnavailable,
  engineCapabilityUnavailable,
  mpvCacheCreateFailed,
  actualModeUnconfirmed,
  targetTooSmallForMinimumWindow,
  metadataBudgetLimited,
  sessionBudgetReached,
  fullReadAheadInsufficientSpace,
  lowSpace,
  memoryPressure,
}

class ResolvedPlaybackCacheProfile {
  const ResolvedPlaybackCacheProfile({
    required this.runtimeMode,
    required this.transportKind,
    required this.fallbackReason,
    required this.forwardTarget,
    required this.backwardTarget,
    required this.sessionTargetBytes,
    required this.reservedFreeBytes,
    required this.demuxerForwardMetadataBytes,
    required this.demuxerBackwardMetadataBytes,
    required this.metadataBudgetCapBytes,
    required this.streamBufferBytes,
    required this.donateBuffer,
    required this.sessionDirectory,
    this.readAheadStrategy = PlaybackCacheReadAheadStrategy.boundedWindow,
    this.budgetPolicy = PlaybackCacheBudgetPolicy.boundedReopen,
    this.sizeConfidence = PlaybackCacheSizeConfidence.unknown,
    this.readAheadAnchor = Duration.zero,
    this.estimatedSourceBytes,
  });

  final PlaybackCacheRuntimeMode runtimeMode;
  final PlaybackTransportKind transportKind;
  final PlaybackCacheFallbackReason fallbackReason;
  final Duration forwardTarget;
  final Duration backwardTarget;
  final int sessionTargetBytes;
  final int reservedFreeBytes;
  final int demuxerForwardMetadataBytes;
  final int demuxerBackwardMetadataBytes;
  final int metadataBudgetCapBytes;
  final int streamBufferBytes;
  final bool donateBuffer;
  final Directory? sessionDirectory;
  final PlaybackCacheReadAheadStrategy readAheadStrategy;
  final PlaybackCacheBudgetPolicy budgetPolicy;
  final PlaybackCacheSizeConfidence sizeConfidence;
  final Duration readAheadAnchor;
  final int? estimatedSourceBytes;

  int get totalMetadataBytes =>
      demuxerForwardMetadataBytes + demuxerBackwardMetadataBytes;

  ResolvedPlaybackCacheProfile copyWith({
    int? sessionTargetBytes,
    int? streamBufferBytes,
    PlaybackCacheReadAheadStrategy? readAheadStrategy,
    PlaybackCacheBudgetPolicy? budgetPolicy,
    PlaybackCacheSizeConfidence? sizeConfidence,
    Duration? readAheadAnchor,
    int? estimatedSourceBytes,
  }) => ResolvedPlaybackCacheProfile(
    runtimeMode: runtimeMode,
    transportKind: transportKind,
    fallbackReason: fallbackReason,
    forwardTarget: forwardTarget,
    backwardTarget: backwardTarget,
    sessionTargetBytes: sessionTargetBytes ?? this.sessionTargetBytes,
    reservedFreeBytes: reservedFreeBytes,
    demuxerForwardMetadataBytes: demuxerForwardMetadataBytes,
    demuxerBackwardMetadataBytes: demuxerBackwardMetadataBytes,
    metadataBudgetCapBytes: metadataBudgetCapBytes,
    streamBufferBytes: streamBufferBytes ?? this.streamBufferBytes,
    donateBuffer: donateBuffer,
    sessionDirectory: sessionDirectory,
    readAheadStrategy: readAheadStrategy ?? this.readAheadStrategy,
    budgetPolicy: budgetPolicy ?? this.budgetPolicy,
    sizeConfidence: sizeConfidence ?? this.sizeConfidence,
    readAheadAnchor: readAheadAnchor ?? this.readAheadAnchor,
    estimatedSourceBytes: estimatedSourceBytes ?? this.estimatedSourceBytes,
  );

  ResolvedPlaybackCacheProfile memoryFallback(
    PlaybackCacheFallbackReason reason, {
    int maximumMetadataBytes = 64 * 1024 * 1024,
    PlaybackCacheSizeConfidence sizeConfidence =
        PlaybackCacheSizeConfidence.unknown,
    Duration readAheadAnchor = Duration.zero,
    int? estimatedSourceBytes,
  }) {
    final forwardBytes = min(
      demuxerForwardMetadataBytes,
      min(64 * 1024 * 1024, maximumMetadataBytes - 8 * 1024 * 1024),
    );
    final backwardBytes = min(
      min(demuxerBackwardMetadataBytes, 16 * 1024 * 1024),
      max(0, maximumMetadataBytes - forwardBytes),
    );
    return ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
      transportKind: transportKind,
      fallbackReason: reason,
      forwardTarget: forwardTarget > const Duration(seconds: 60)
          ? const Duration(seconds: 60)
          : forwardTarget,
      backwardTarget: backwardTarget > const Duration(seconds: 30)
          ? const Duration(seconds: 30)
          : backwardTarget,
      sessionTargetBytes: 0,
      reservedFreeBytes: reservedFreeBytes,
      demuxerForwardMetadataBytes: forwardBytes,
      demuxerBackwardMetadataBytes: backwardBytes,
      metadataBudgetCapBytes: min(metadataBudgetCapBytes, maximumMetadataBytes),
      streamBufferBytes: streamBufferBytes,
      donateBuffer: donateBuffer,
      sessionDirectory: null,
      readAheadStrategy: PlaybackCacheReadAheadStrategy.boundedWindow,
      budgetPolicy: PlaybackCacheBudgetPolicy.boundedReopen,
      sizeConfidence: sizeConfidence,
      readAheadAnchor: readAheadAnchor,
      estimatedSourceBytes: estimatedSourceBytes,
    );
  }
}

PlaybackTransportKind classifyPlaybackTransport({
  required PlayMethod method,
  required Uri uri,
  required String? sourceProtocol,
  required String? container,
  required String? liveStreamId,
  required Duration duration,
  Uri? sourceUri,
}) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'file') return PlaybackTransportKind.offlineLocal;
  if ((liveStreamId?.trim().isNotEmpty ?? false) || duration <= Duration.zero) {
    return PlaybackTransportKind.live;
  }
  if (scheme != 'http' && scheme != 'https') {
    return PlaybackTransportKind.unknown;
  }

  final normalizedContainer = container?.trim().toLowerCase() ?? '';
  final uriEvidence = [uri, ?sourceUri].map(_decodedLowercaseUri);
  final segmented =
      method == PlayMethod.transcode ||
      normalizedContainer == 'm3u8' ||
      normalizedContainer == 'hls' ||
      normalizedContainer == 'dash' ||
      normalizedContainer == 'mpd' ||
      uriEvidence.any(
        (candidate) =>
            candidate.contains('.m3u8') || candidate.contains('.mpd'),
      );
  if (segmented) return PlaybackTransportKind.segmentedHttp;

  final protocol = sourceProtocol?.trim().toLowerCase();
  if (protocol == null ||
      protocol.isEmpty ||
      protocol == 'http' ||
      protocol == 'https' ||
      protocol == 'file') {
    return PlaybackTransportKind.progressiveHttp;
  }
  return PlaybackTransportKind.unknown;
}

String _decodedLowercaseUri(Uri uri) {
  final raw = uri.toString().toLowerCase();
  try {
    return Uri.decodeFull(raw);
  } catch (_) {
    return raw;
  }
}

bool isFullReadAheadEligible(PlaybackPlan plan) =>
    plan.transportKind == PlaybackTransportKind.progressiveHttp &&
    (plan.duration ?? Duration.zero) > Duration.zero;

int fullReadAheadLowSpaceGuardBytes({
  required int? mediaBitrate,
  int? rawInputRateBytesPerSecond,
  required Duration pollInterval,
  required Duration expectedCloseLatency,
}) {
  const mib = 1024 * 1024;
  final derivedRate = max(((mediaBitrate ?? 0) / 8 * 2).round(), 8 * mib);
  final rate =
      rawInputRateBytesPerSecond != null && rawInputRateBytesPerSecond > 0
      ? rawInputRateBytesPerSecond
      : derivedRate;
  final elapsedSeconds =
      max(0, (pollInterval + expectedCloseLatency).inMilliseconds) / 1000;
  final rawGuard = (rate * elapsedSeconds).ceil();
  return rawGuard.clamp(64 * mib, 512 * mib).toInt();
}

class _PlaybackCacheSizeEvidence {
  const _PlaybackCacheSizeEvidence(this.confidence, this.bytes);

  final PlaybackCacheSizeConfidence confidence;
  final int? bytes;
}

class PlaybackCacheProfileResolver {
  const PlaybackCacheProfileResolver();

  static const int _mib = 1024 * 1024;
  static const int _gib = 1024 * 1024 * 1024;
  static const int _maxInt = 9223372036854775807;
  static const int defaultBitrate = 8 * 1000 * 1000;
  static const int defaultStreamBufferBytes = 128 * 1024;

  ResolvedPlaybackCacheProfile resolve({
    required PlaybackPlan plan,
    required PlaybackCacheSettings settings,
    required PlaybackCacheEngineCapabilities capabilities,
    required PlaybackCacheStorageSnapshot storage,
    bool memoryPressure = false,
    Duration readAheadAnchor = Duration.zero,
    int? rawInputRateBytesPerSecond,
    Duration spacePollInterval = const Duration(seconds: 10),
    Duration expectedCloseLatency = const Duration(seconds: 2),
  }) {
    final preset = _preset(settings, storage.freeBytes);
    final anchor = _normalizedAnchor(plan.duration, readAheadAnchor);
    final sizeEvidence = _sizeEvidence(plan);
    if (plan.transportKind == PlaybackTransportKind.offlineLocal) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.disabled,
        reason: PlaybackCacheFallbackReason.offlineMedia,
        settings: settings,
      );
    }
    if (settings.mode == PlaybackCacheMode.memoryOnly) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memory,
        reason: PlaybackCacheFallbackReason.none,
        settings: settings,
      );
    }
    if (plan.transportKind == PlaybackTransportKind.segmentedHttp) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.segmentedTransport,
        settings: settings,
      );
    }
    if (plan.transportKind != PlaybackTransportKind.progressiveHttp) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.liveOrUnknownLength,
        settings: settings,
      );
    }
    if (memoryPressure) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.memoryPressure,
        settings: settings,
        maximumMetadataBytes: 64 * _mib,
      );
    }
    if (!capabilities.diskGatePassed) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.engineCapabilityUnavailable,
        settings: settings,
      );
    }
    if (!storage.isAvailable) {
      final reason = switch (storage.failureReason) {
        PlaybackCacheStorageFailureReason.directoryUnavailable =>
          PlaybackCacheFallbackReason.directoryUnavailable,
        _ => PlaybackCacheFallbackReason.storageCapacityUnknown,
      };
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: reason,
        settings: settings,
      );
    }
    if (preset.targetBytes == 0) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.insufficientSpace,
        settings: settings,
      );
    }

    final fullReadAhead =
        settings.mode == PlaybackCacheMode.fullReadAhead &&
        isFullReadAheadEligible(plan);
    if (fullReadAhead) {
      return _resolveFullReadAhead(
        plan: plan,
        settings: settings,
        storage: storage,
        preset: preset,
        anchor: anchor,
        sizeEvidence: sizeEvidence,
        rawInputRateBytesPerSecond: rawInputRateBytesPerSecond,
        spacePollInterval: spacePollInterval,
        expectedCloseLatency: expectedCloseLatency,
      );
    }
    return _resolveBounded(
      plan: plan,
      settings: settings,
      storage: storage,
      preset: preset,
      anchor: anchor,
      sizeEvidence: sizeEvidence,
    );
  }

  ResolvedPlaybackCacheProfile _resolveFullReadAhead({
    required PlaybackPlan plan,
    required PlaybackCacheSettings settings,
    required PlaybackCacheStorageSnapshot storage,
    required _CachePreset preset,
    required Duration anchor,
    required _PlaybackCacheSizeEvidence sizeEvidence,
    required int? rawInputRateBytesPerSecond,
    required Duration spacePollInterval,
    required Duration expectedCloseLatency,
  }) {
    final safeSpendable = max(
      0,
      storage.freeBytes! -
          settings.reservedFreeBytes -
          fullReadAheadLowSpaceGuardBytes(
            mediaBitrate: plan.bitrate,
            rawInputRateBytesPerSecond: rawInputRateBytesPerSecond,
            pollInterval: spacePollInterval,
            expectedCloseLatency: expectedCloseLatency,
          ),
    );
    final requiredBytes = _requiredReadAheadBytes(
      plan: plan,
      anchor: anchor,
      sizeEvidence: sizeEvidence,
    );
    if (requiredBytes != null && requiredBytes <= safeSpendable) {
      return _fullDiskProfile(
        plan: plan,
        settings: settings,
        storage: storage,
        sessionTargetBytes: requiredBytes,
        anchor: anchor,
        sizeEvidence: sizeEvidence,
      );
    }
    if (requiredBytes == null && safeSpendable >= 512 * _mib) {
      return _fullDiskProfile(
        plan: plan,
        settings: settings,
        storage: storage,
        sessionTargetBytes: safeSpendable,
        anchor: anchor,
        sizeEvidence: sizeEvidence,
      );
    }
    return _resolveBounded(
      plan: plan,
      settings: settings,
      storage: storage,
      preset: preset,
      anchor: anchor,
      sizeEvidence: sizeEvidence,
      fallbackReasonOverride:
          PlaybackCacheFallbackReason.fullReadAheadInsufficientSpace,
    );
  }

  ResolvedPlaybackCacheProfile _fullDiskProfile({
    required PlaybackPlan plan,
    required PlaybackCacheSettings settings,
    required PlaybackCacheStorageSnapshot storage,
    required int sessionTargetBytes,
    required Duration anchor,
    required _PlaybackCacheSizeEvidence sizeEvidence,
  }) {
    final duration = plan.duration!;
    final metadata = _metadataBudget(
      forwardSeconds: max(1, duration.inSeconds),
      backwardSeconds: 0,
      sessionTargetBytes: sessionTargetBytes,
    );
    if (metadata == null) {
      return _resolveBounded(
        plan: plan,
        settings: settings,
        storage: storage,
        preset: _preset(settings, storage.freeBytes),
        anchor: anchor,
        sizeEvidence: sizeEvidence,
        fallbackReasonOverride:
            PlaybackCacheFallbackReason.fullReadAheadInsufficientSpace,
      );
    }
    return ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.disk,
      transportKind: plan.transportKind,
      fallbackReason: PlaybackCacheFallbackReason.none,
      forwardTarget: duration,
      backwardTarget: Duration.zero,
      sessionTargetBytes: sessionTargetBytes,
      reservedFreeBytes: settings.reservedFreeBytes,
      demuxerForwardMetadataBytes: metadata.forwardBytes,
      demuxerBackwardMetadataBytes: metadata.backwardBytes,
      metadataBudgetCapBytes: metadata.capBytes,
      streamBufferBytes: defaultStreamBufferBytes,
      donateBuffer: true,
      sessionDirectory: storage.session!.directory,
      readAheadStrategy: PlaybackCacheReadAheadStrategy.mediaEnd,
      budgetPolicy: PlaybackCacheBudgetPolicy.lowSpaceOnly,
      sizeConfidence: sizeEvidence.confidence,
      readAheadAnchor: anchor,
      estimatedSourceBytes: sizeEvidence.bytes,
    );
  }

  ResolvedPlaybackCacheProfile _resolveBounded({
    required PlaybackPlan plan,
    required PlaybackCacheSettings settings,
    required PlaybackCacheStorageSnapshot storage,
    required _CachePreset preset,
    required Duration anchor,
    required _PlaybackCacheSizeEvidence sizeEvidence,
    PlaybackCacheFallbackReason? fallbackReasonOverride,
  }) {
    final availableBytes = storage.freeBytes!;
    final safeSpendable = max(0, availableBytes - settings.reservedFreeBytes);
    final effectiveTarget = min(
      min(preset.targetBytes, (safeSpendable * 0.25).floor()),
      PlaybackCacheSettings.maxSessionTargetBytes,
    );
    if (effectiveTarget < PlaybackCacheSettings.minSessionTargetBytes) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.insufficientSpace,
        fallbackReasonOverride: fallbackReasonOverride,
        settings: settings,
        readAheadAnchor: anchor,
        sizeConfidence: sizeEvidence.confidence,
        estimatedSourceBytes: sizeEvidence.bytes,
      );
    }

    final bitrate = plan.bitrate != null && plan.bitrate! > 0
        ? plan.bitrate!
        : defaultBitrate;
    const minimumForward = 30;
    const minimumBackward = 15;
    final bytesPerSecond = bitrate / 8 * 1.25;
    final minimumWindowBytes =
        (bytesPerSecond * (minimumForward + minimumBackward)).ceil();
    if (minimumWindowBytes > effectiveTarget) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.targetTooSmallForMinimumWindow,
        fallbackReasonOverride: fallbackReasonOverride,
        settings: settings,
        readAheadAnchor: anchor,
        sizeConfidence: sizeEvidence.confidence,
        estimatedSourceBytes: sizeEvidence.bytes,
      );
    }

    var forwardSeconds = preset.forwardSeconds;
    var backwardSeconds = preset.backwardSeconds;
    final requestedBytes = (bytesPerSecond * (forwardSeconds + backwardSeconds))
        .ceil();
    if (requestedBytes > effectiveTarget) {
      final secondsBudget = (effectiveTarget / bytesPerSecond).floor();
      final totalRequested = forwardSeconds + backwardSeconds;
      forwardSeconds = (secondsBudget * forwardSeconds / totalRequested)
          .floor();
      backwardSeconds = secondsBudget - forwardSeconds;
      if (forwardSeconds < minimumForward) {
        forwardSeconds = minimumForward;
        backwardSeconds = secondsBudget - forwardSeconds;
      }
      if (backwardSeconds < minimumBackward) {
        backwardSeconds = minimumBackward;
        forwardSeconds = secondsBudget - backwardSeconds;
      }
    }

    final metadata = _metadataBudget(
      forwardSeconds: forwardSeconds,
      backwardSeconds: backwardSeconds,
      sessionTargetBytes: effectiveTarget,
    );
    if (metadata == null) {
      return _nonDiskProfile(
        transportKind: plan.transportKind,
        preset: preset,
        runtimeMode: PlaybackCacheRuntimeMode.memoryFallback,
        reason: PlaybackCacheFallbackReason.metadataBudgetLimited,
        fallbackReasonOverride: fallbackReasonOverride,
        settings: settings,
        readAheadAnchor: anchor,
        sizeConfidence: sizeEvidence.confidence,
        estimatedSourceBytes: sizeEvidence.bytes,
      );
    }
    return ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.disk,
      transportKind: plan.transportKind,
      fallbackReason:
          fallbackReasonOverride ?? PlaybackCacheFallbackReason.none,
      forwardTarget: Duration(seconds: forwardSeconds),
      backwardTarget: Duration(seconds: backwardSeconds),
      sessionTargetBytes: effectiveTarget,
      reservedFreeBytes: settings.reservedFreeBytes,
      demuxerForwardMetadataBytes: metadata.forwardBytes,
      demuxerBackwardMetadataBytes: metadata.backwardBytes,
      metadataBudgetCapBytes: metadata.capBytes,
      streamBufferBytes: defaultStreamBufferBytes,
      donateBuffer: true,
      sessionDirectory: storage.session!.directory,
      readAheadStrategy: PlaybackCacheReadAheadStrategy.boundedWindow,
      budgetPolicy: PlaybackCacheBudgetPolicy.boundedReopen,
      sizeConfidence: sizeEvidence.confidence,
      readAheadAnchor: anchor,
      estimatedSourceBytes: sizeEvidence.bytes,
    );
  }

  ResolvedPlaybackCacheProfile _nonDiskProfile({
    required PlaybackTransportKind transportKind,
    required _CachePreset preset,
    required PlaybackCacheRuntimeMode runtimeMode,
    required PlaybackCacheFallbackReason reason,
    required PlaybackCacheSettings settings,
    int maximumMetadataBytes = 64 * _mib,
    PlaybackCacheFallbackReason? fallbackReasonOverride,
    Duration readAheadAnchor = Duration.zero,
    PlaybackCacheSizeConfidence sizeConfidence =
        PlaybackCacheSizeConfidence.unknown,
    int? estimatedSourceBytes,
  }) {
    final metadata = _metadataBudget(
      forwardSeconds: preset.forwardSeconds,
      backwardSeconds: preset.backwardSeconds,
      sessionTargetBytes: max(
        PlaybackCacheSettings.minSessionTargetBytes,
        preset.targetBytes,
      ),
      maximumCapBytes: maximumMetadataBytes,
    );
    final forwardMetadataBytes = min(
      metadata?.forwardBytes ?? 16 * _mib,
      64 * _mib,
    );
    final backwardMetadataBytes = min(
      metadata?.backwardBytes ?? 8 * _mib,
      16 * _mib,
    );
    return ResolvedPlaybackCacheProfile(
      runtimeMode: runtimeMode,
      transportKind: transportKind,
      fallbackReason: fallbackReasonOverride ?? reason,
      forwardTarget: Duration(seconds: preset.forwardSeconds),
      backwardTarget: Duration(seconds: preset.backwardSeconds),
      sessionTargetBytes: 0,
      reservedFreeBytes: settings.reservedFreeBytes,
      demuxerForwardMetadataBytes: forwardMetadataBytes,
      demuxerBackwardMetadataBytes: backwardMetadataBytes,
      metadataBudgetCapBytes: max(
        forwardMetadataBytes + backwardMetadataBytes,
        metadata?.capBytes ?? 32 * _mib,
      ),
      streamBufferBytes: defaultStreamBufferBytes,
      donateBuffer: true,
      sessionDirectory: null,
      readAheadAnchor: readAheadAnchor,
      sizeConfidence: sizeConfidence,
      estimatedSourceBytes: estimatedSourceBytes,
    );
  }

  _CachePreset _preset(PlaybackCacheSettings settings, int? availableBytes) {
    return switch (settings.mode) {
      PlaybackCacheMode.memoryOnly => const _CachePreset(60, 30, 0),
      PlaybackCacheMode.spaceSaving => const _CachePreset(90, 60, 256 * _mib),
      PlaybackCacheMode.balanced => const _CachePreset(180, 120, 512 * _mib),
      PlaybackCacheMode.aggressive => const _CachePreset(600, 300, 2 * _gib),
      PlaybackCacheMode.custom => _CachePreset(
        settings.customForwardSeconds,
        settings.customBackwardSeconds,
        settings.customSessionTargetBytes,
      ),
      PlaybackCacheMode.fullReadAhead => const _CachePreset(
        180,
        120,
        512 * _mib,
      ),
      PlaybackCacheMode.automatic => _automaticPreset(availableBytes),
    };
  }

  _PlaybackCacheSizeEvidence _sizeEvidence(PlaybackPlan plan) {
    final declared = plan.sourceSizeBytes;
    if (declared != null && declared > 0) {
      return _PlaybackCacheSizeEvidence(
        PlaybackCacheSizeConfidence.serverDeclared,
        declared,
      );
    }
    final duration = plan.duration ?? Duration.zero;
    final bitrate = plan.bitrate;
    if (duration <= Duration.zero || bitrate == null || bitrate <= 0) {
      return const _PlaybackCacheSizeEvidence(
        PlaybackCacheSizeConfidence.unknown,
        null,
      );
    }
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    final estimated = bitrate / 8 * seconds * 1.25;
    if (!estimated.isFinite || estimated <= 0 || estimated > _maxInt) {
      return const _PlaybackCacheSizeEvidence(
        PlaybackCacheSizeConfidence.unknown,
        null,
      );
    }
    return _PlaybackCacheSizeEvidence(
      PlaybackCacheSizeConfidence.estimated,
      estimated.ceil(),
    );
  }

  Duration _normalizedAnchor(Duration? duration, Duration anchor) {
    final nonnegative = anchor < Duration.zero ? Duration.zero : anchor;
    if (duration == null || duration <= Duration.zero) return nonnegative;
    return nonnegative > duration ? duration : nonnegative;
  }

  int? _requiredReadAheadBytes({
    required PlaybackPlan plan,
    required Duration anchor,
    required _PlaybackCacheSizeEvidence sizeEvidence,
  }) {
    final sourceBytes = sizeEvidence.bytes;
    final duration = plan.duration;
    if (sourceBytes == null || duration == null || duration <= Duration.zero) {
      return null;
    }
    final durationMicros = duration.inMicroseconds;
    final remainingMicros = max(0, durationMicros - anchor.inMicroseconds);
    final remainingBytes = remainingMicros == 0
        ? 0
        : _saturatingAdd(
            _saturatingMultiply(sourceBytes ~/ durationMicros, remainingMicros),
            ((sourceBytes % durationMicros).toDouble() *
                    remainingMicros /
                    durationMicros)
                .ceil(),
          );
    final margin = ((remainingBytes ~/ 10) + (remainingBytes % 10 == 0 ? 0 : 1))
        .clamp(64 * _mib, _gib)
        .toInt();
    return _saturatingAdd(remainingBytes, margin);
  }

  int _saturatingAdd(int left, int right) {
    if (left >= _maxInt - right) return _maxInt;
    return left + right;
  }

  int _saturatingMultiply(int left, int right) {
    if (left == 0 || right == 0) return 0;
    if (left > _maxInt ~/ right) return _maxInt;
    return left * right;
  }

  _CachePreset _automaticPreset(int? availableBytes) {
    if (availableBytes == null || availableBytes < 2 * _gib) {
      return const _CachePreset(60, 30, 0);
    }
    if (availableBytes < 8 * _gib) {
      return const _CachePreset(90, 60, 256 * _mib);
    }
    if (availableBytes < 24 * _gib) {
      return const _CachePreset(180, 120, 512 * _mib);
    }
    if (availableBytes < 64 * _gib) {
      return const _CachePreset(300, 180, _gib);
    }
    return const _CachePreset(600, 300, 2 * _gib);
  }

  _MetadataBudget? _metadataBudget({
    required int forwardSeconds,
    required int backwardSeconds,
    required int sessionTargetBytes,
    int maximumCapBytes = 128 * _mib,
  }) {
    final cap = min(
      (sessionTargetBytes ~/ 8).clamp(32 * _mib, 128 * _mib),
      maximumCapBytes,
    );
    if (cap < 24 * _mib) return null;
    final requestedForward = switch (forwardSeconds) {
      <= 60 => 16 * _mib,
      <= 180 => 32 * _mib,
      <= 300 => 64 * _mib,
      <= 600 => 96 * _mib,
      _ => 128 * _mib,
    };
    final requestedBackward = switch (backwardSeconds) {
      <= 30 => 8 * _mib,
      <= 60 => 16 * _mib,
      <= 120 => 32 * _mib,
      <= 300 => 64 * _mib,
      _ => 96 * _mib,
    };
    if (requestedForward + requestedBackward <= cap) {
      return _MetadataBudget(requestedForward, requestedBackward, cap);
    }
    final totalSeconds = max(1, forwardSeconds + backwardSeconds);
    var forward = (cap * forwardSeconds / totalSeconds).floor();
    forward = forward.clamp(16 * _mib, cap - 8 * _mib);
    final backward = cap - forward;
    if (backward < 8 * _mib) return null;
    return _MetadataBudget(forward, backward, cap);
  }
}

class _CachePreset {
  const _CachePreset(
    this.forwardSeconds,
    this.backwardSeconds,
    this.targetBytes,
  );

  final int forwardSeconds;
  final int backwardSeconds;
  final int targetBytes;
}

class _MetadataBudget {
  const _MetadataBudget(this.forwardBytes, this.backwardBytes, this.capBytes);

  final int forwardBytes;
  final int backwardBytes;
  final int capBytes;
}
