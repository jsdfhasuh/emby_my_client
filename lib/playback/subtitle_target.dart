import 'playback_engine.dart';

/// IDs from these namespaces must never be converted into one another.
sealed class SubtitleTarget {
  const SubtitleTarget();
}

final class ServerStream extends SubtitleTarget {
  const ServerStream(this.index);
  final int index;
}

class SubtitleInputBinding {
  const SubtitleInputBinding({
    required this.itemId,
    required this.itemSession,
    required this.engine,
    required this.generation,
    required this.inputEpoch,
  });
  final String itemId;
  final Object itemSession;
  final PlaybackEngine engine;
  final int generation;
  final int inputEpoch;
}

final class NativeSubtitleTrack extends SubtitleTarget {
  const NativeSubtitleTrack(this.track, this.binding);
  final EngineTrack track;
  final SubtitleInputBinding binding;
}

final class LocalExternalAsset extends SubtitleTarget {
  const LocalExternalAsset(this.index, this.uri, this.binding);
  final int index;
  final Uri uri;
  final SubtitleInputBinding binding;
}

enum SubtitleFailureReason {
  unsupportedDelivery,
  deliveryUnknown,
  externalLocationMissing,
  externalLoaderUnavailable,
  offlineNetworkForbidden,
  mappingUnconfirmed,
  nativeTrackUnavailable,
}

class SubtitleSelectionFailure implements Exception {
  const SubtitleSelectionFailure(this.reason);
  final SubtitleFailureReason reason;
  String get message => switch (reason) {
    SubtitleFailureReason.unsupportedDelivery => '暂不支持服务器返回的字幕交付方式',
    SubtitleFailureReason.deliveryUnknown => '服务器未提供可确认的字幕交付方式',
    SubtitleFailureReason.externalLocationMissing => '服务器未提供字幕下载地址',
    SubtitleFailureReason.externalLoaderUnavailable => '字幕下载器不可用，请重试',
    SubtitleFailureReason.offlineNetworkForbidden => '离线字幕文件不可用，请重新下载字幕',
    SubtitleFailureReason.mappingUnconfirmed => '无法确认服务器字幕对应的轨道，可尝试选择当前文件字幕',
    SubtitleFailureReason.nativeTrackUnavailable => '该字幕轨道已失效，请重新打开字幕列表',
  };
}
