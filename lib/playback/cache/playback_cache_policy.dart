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

  int get totalMetadataBytes =>
      demuxerForwardMetadataBytes + demuxerBackwardMetadataBytes;

  ResolvedPlaybackCacheProfile memoryFallback(
    PlaybackCacheFallbackReason reason, {
    int maximumMetadataBytes = 64 * 1024 * 1024,
  }) {
    final forwardBytes = min(
      demuxerForwardMetadataBytes,
      maximumMetadataBytes - 8 * 1024 * 1024,
    );
    final backwardBytes = min(
      demuxerBackwardMetadataBytes,
      maximumMetadataBytes - forwardBytes,
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
  final rawUri = uri.toString().toLowerCase();
  String decodedUri;
  try {
    decodedUri = Uri.decodeFull(rawUri);
  } catch (_) {
    decodedUri = rawUri;
  }
  final segmented =
      method == PlayMethod.transcode ||
      normalizedContainer == 'm3u8' ||
      normalizedContainer == 'hls' ||
      normalizedContainer == 'dash' ||
      normalizedContainer == 'mpd' ||
      decodedUri.contains('.m3u8') ||
      decodedUri.contains('.mpd');
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

class PlaybackCacheProfileResolver {
  const PlaybackCacheProfileResolver();

  static const int _mib = 1024 * 1024;
  static const int _gib = 1024 * 1024 * 1024;
  static const int defaultBitrate = 8 * 1000 * 1000;
  static const int defaultStreamBufferBytes = 128 * 1024;

  ResolvedPlaybackCacheProfile resolve({
    required PlaybackPlan plan,
    required PlaybackCacheSettings settings,
    required PlaybackCacheEngineCapabilities capabilities,
    required PlaybackCacheStorageSnapshot storage,
    bool memoryPressure = false,
  }) {
    final preset = _preset(settings, storage.freeBytes);
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
        settings: settings,
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
        settings: settings,
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
        settings: settings,
      );
    }
    return ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.disk,
      transportKind: plan.transportKind,
      fallbackReason: PlaybackCacheFallbackReason.none,
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
    );
  }

  ResolvedPlaybackCacheProfile _nonDiskProfile({
    required PlaybackTransportKind transportKind,
    required _CachePreset preset,
    required PlaybackCacheRuntimeMode runtimeMode,
    required PlaybackCacheFallbackReason reason,
    required PlaybackCacheSettings settings,
    int maximumMetadataBytes = 128 * _mib,
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
    return ResolvedPlaybackCacheProfile(
      runtimeMode: runtimeMode,
      transportKind: transportKind,
      fallbackReason: reason,
      forwardTarget: Duration(seconds: preset.forwardSeconds),
      backwardTarget: Duration(seconds: preset.backwardSeconds),
      sessionTargetBytes: 0,
      reservedFreeBytes: settings.reservedFreeBytes,
      demuxerForwardMetadataBytes: metadata?.forwardBytes ?? 16 * _mib,
      demuxerBackwardMetadataBytes: metadata?.backwardBytes ?? 8 * _mib,
      metadataBudgetCapBytes: metadata?.capBytes ?? 32 * _mib,
      streamBufferBytes: defaultStreamBufferBytes,
      donateBuffer: true,
      sessionDirectory: null,
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
      PlaybackCacheMode.automatic => _automaticPreset(availableBytes),
    };
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
