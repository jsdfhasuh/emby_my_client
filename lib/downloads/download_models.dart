import 'dart:collection';

import '../core/server_scope.dart';
import '../models/emby_models.dart';
import 'download_integrity.dart';

enum DownloadStatus {
  queued,
  running,
  waitingForNetwork,
  waitingForStorage,
  paused,
  completed,
  failed,
  cancelling,
}

enum DownloadSourceKind { original }

enum OfflineAssetState { unknown, available, missing, failed, notProvided }

class OfflineMediaMetadata {
  OfflineMediaMetadata({
    required this.name,
    required this.itemType,
    required List<Map<String, dynamic>> mediaStreams,
    this.overview,
    this.seriesName,
    this.seasonName,
    this.runTimeTicks,
    this.indexNumber,
    this.parentIndexNumber,
    this.container,
    this.primaryImageTag,
    this.primaryImagePath,
    this.primaryImageState = OfflineAssetState.unknown,
    this.subtitleDiscoveryComplete = false,
  }) : mediaStreams = List.unmodifiable(mediaStreams);

  factory OfflineMediaMetadata.fromItem(
    EmbyItem item,
    PlaybackMediaSource source,
  ) => OfflineMediaMetadata(
    name: item.name,
    itemType: item.type,
    overview: item.overview,
    seriesName: item.seriesName,
    seasonName: item.seasonName,
    runTimeTicks: item.runTimeTicks,
    indexNumber: item.indexNumber,
    parentIndexNumber: item.parentIndexNumber,
    container: source.container,
    primaryImageTag: item.imageTags['Primary'],
    mediaStreams: source.mediaStreams
        .map((original) {
          final stream = Map<String, dynamic>.from(original);
          if (isExternalSubtitle(stream)) {
            // Discovery uses the active account, never persisted signed URLs.
            stream.remove('DeliveryUrl');
            stream.remove('Path');
          }
          return stream;
        })
        .toList(growable: false),
  );

  final String name;
  final String itemType;
  final String? overview;
  final String? seriesName;
  final String? seasonName;
  final int? runTimeTicks;
  final int? indexNumber;
  final int? parentIndexNumber;
  final String? container;
  final String? primaryImageTag;
  final String? primaryImagePath;
  final OfflineAssetState primaryImageState;
  final List<Map<String, dynamic>> mediaStreams;
  final bool subtitleDiscoveryComplete;

  static bool isExternalSubtitle(Map<String, dynamic> stream) =>
      stream['Type']?.toString().toLowerCase() == 'subtitle' &&
      (stream['IsExternal'] == true ||
          stream['DeliveryMethod']?.toString().trim().toLowerCase() ==
              'external');

  bool get subtitlesNeedRepair =>
      !subtitleDiscoveryComplete ||
      mediaStreams
          .where(isExternalSubtitle)
          .any(
            (stream) =>
                stream['OfflineSubtitleState'] != 'available' ||
                stream['OfflineSubtitleError'] != null,
          );

  String get subtitleStatusText {
    final external = mediaStreams.where(isExternalSubtitle).toList();
    final available = external
        .where((stream) => stream['OfflineSubtitleState'] == 'available')
        .length;
    if (!subtitleDiscoveryComplete) {
      return available > 0 ? '已保存 $available 条字幕，发现待重试' : '字幕待检查，可补下载';
    }
    final missing = external.length - available;
    if (missing > 0) return '已保存 $available 条，缺少 $missing 条字幕，可补下载';
    if (external.any((stream) => stream['OfflineSubtitleError'] != null)) {
      return '已保存 $available 条字幕，刷新失败，已保留原文件';
    }
    if (external.isNotEmpty) return '字幕已保存（$available 条）';
    return mediaStreams.any(
          (s) => s['Type']?.toString().toLowerCase() == 'subtitle',
        )
        ? '内嵌字幕随原视频保存'
        : '服务器未提供字幕';
  }

  String get coverStatusText => switch (primaryImageState) {
    OfflineAssetState.available => '封面已保存',
    OfflineAssetState.missing => '封面文件缺失',
    OfflineAssetState.failed => '封面不可用',
    OfflineAssetState.notProvided => '服务器未提供封面',
    OfflineAssetState.unknown => '封面待检查',
  };

  List<Map<String, dynamic>> get playbackStreams => mediaStreams
      .where(
        (stream) =>
            !isExternalSubtitle(stream) ||
            (stream['OfflineSubtitleState'] == 'available' &&
                isLocalAssetPath(stream['DeliveryUrl'])) ||
            (stream['OfflineSubtitleState'] == null &&
                isLocalAssetPath(stream['DeliveryUrl'])),
      )
      .toList(growable: false);

  static bool isLocalAssetPath(Object? value) =>
      value is String &&
      (value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value));

  List<String> get assetPaths {
    final result = <String>[];
    final imagePath = primaryImagePath;
    if (imagePath != null) result.add(imagePath);
    for (final stream in mediaStreams) {
      final deliveryUrl = stream['DeliveryUrl'];
      if (isExternalSubtitle(stream) &&
          deliveryUrl is String &&
          (isLocalAssetPath(deliveryUrl) ||
              (!deliveryUrl.contains('://') && !deliveryUrl.contains('?')))) {
        result.add(deliveryUrl);
      }
    }
    return result;
  }

  OfflineMediaMetadata copyWith({
    List<Map<String, dynamic>>? mediaStreams,
    String? primaryImagePath,
    bool clearPrimaryImagePath = false,
    OfflineAssetState? primaryImageState,
    bool? subtitleDiscoveryComplete,
  }) => OfflineMediaMetadata(
    name: name,
    itemType: itemType,
    overview: overview,
    seriesName: seriesName,
    seasonName: seasonName,
    runTimeTicks: runTimeTicks,
    indexNumber: indexNumber,
    parentIndexNumber: parentIndexNumber,
    container: container,
    primaryImageTag: primaryImageTag,
    primaryImagePath: clearPrimaryImagePath
        ? null
        : primaryImagePath ?? this.primaryImagePath,
    primaryImageState: primaryImageState ?? this.primaryImageState,
    mediaStreams: mediaStreams ?? this.mediaStreams,
    subtitleDiscoveryComplete:
        subtitleDiscoveryComplete ?? this.subtitleDiscoveryComplete,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'itemType': itemType,
    if (overview != null) 'overview': overview,
    if (seriesName != null) 'seriesName': seriesName,
    if (seasonName != null) 'seasonName': seasonName,
    if (runTimeTicks != null) 'runTimeTicks': runTimeTicks,
    if (indexNumber != null) 'indexNumber': indexNumber,
    if (parentIndexNumber != null) 'parentIndexNumber': parentIndexNumber,
    if (container != null) 'container': container,
    if (primaryImageTag != null) 'primaryImageTag': primaryImageTag,
    if (primaryImagePath != null) 'primaryImagePath': primaryImagePath,
    'primaryImageState': primaryImageState.name,
    'mediaStreams': mediaStreams,
    'subtitleDiscoveryComplete': subtitleDiscoveryComplete,
  };

  factory OfflineMediaMetadata.fromJson(Map<String, dynamic> json) =>
      OfflineMediaMetadata(
        name: json['name']?.toString() ?? '未命名下载',
        itemType: json['itemType']?.toString() ?? 'Video',
        overview: _string(json['overview']),
        seriesName: _string(json['seriesName']),
        seasonName: _string(json['seasonName']),
        runTimeTicks: _integer(json['runTimeTicks']),
        indexNumber: _integer(json['indexNumber']),
        parentIndexNumber: _integer(json['parentIndexNumber']),
        container: _string(json['container']),
        primaryImageTag: _string(json['primaryImageTag']),
        primaryImagePath: _string(json['primaryImagePath']),
        primaryImageState:
            OfflineAssetState.values
                .where((state) => state.name == json['primaryImageState'])
                .firstOrNull ??
            OfflineAssetState.unknown,
        subtitleDiscoveryComplete: json['subtitleDiscoveryComplete'] == true,
        mediaStreams: (json['mediaStreams'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((stream) => Map<String, dynamic>.from(stream))
            .toList(growable: false),
      );
}

class DownloadTaskRecord {
  const DownloadTaskRecord({
    required this.id,
    required this.scope,
    required this.itemId,
    required this.mediaSourceId,
    required this.sourceKind,
    required this.sourceFingerprint,
    required this.status,
    required this.downloadedBytes,
    required this.retryCount,
    required this.tempPath,
    required this.finalPath,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
    this.etag,
    this.expectedBytes,
    this.integrity,
    this.lastErrorCode,
  });

  final String id;
  final ServerScope scope;
  final String itemId;
  final String mediaSourceId;
  final DownloadSourceKind sourceKind;
  final String sourceFingerprint;
  final DownloadStatus status;
  final int downloadedBytes;
  final int retryCount;
  final String tempPath;
  final String finalPath;
  final OfflineMediaMetadata metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? etag;
  final int? expectedBytes;
  final DownloadIntegrity? integrity;
  final String? lastErrorCode;

  String get displayName => metadata.name;
  String get itemType => metadata.itemType;
  String? get container => metadata.container;

  double? get progress {
    final total = expectedBytes;
    if (total == null || total <= 0) return null;
    return (downloadedBytes / total).clamp(0, 1);
  }

  bool get canPause =>
      status == DownloadStatus.running ||
      status == DownloadStatus.waitingForNetwork ||
      status == DownloadStatus.waitingForStorage;
  bool get canResume =>
      status == DownloadStatus.paused || status == DownloadStatus.failed;
  bool get requiresFreshDownload =>
      status == DownloadStatus.failed &&
      switch (lastErrorCode) {
        'checksumMismatch' ||
        'invalidLocalPath' ||
        'localMediaCorrupt' ||
        'missingFile' => true,
        _ => false,
      };
  bool get isComplete => status == DownloadStatus.completed;

  DownloadTaskRecord copyWith({
    DownloadStatus? status,
    int? downloadedBytes,
    int? retryCount,
    String? tempPath,
    String? finalPath,
    String? etag,
    bool clearEtag = false,
    int? expectedBytes,
    bool clearExpectedBytes = false,
    DownloadIntegrity? integrity,
    bool clearIntegrity = false,
    String? lastErrorCode,
    bool clearLastErrorCode = false,
    OfflineMediaMetadata? metadata,
    DateTime? updatedAt,
  }) => DownloadTaskRecord(
    id: id,
    scope: scope,
    itemId: itemId,
    mediaSourceId: mediaSourceId,
    sourceKind: sourceKind,
    sourceFingerprint: sourceFingerprint,
    status: status ?? this.status,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    retryCount: retryCount ?? this.retryCount,
    tempPath: tempPath ?? this.tempPath,
    finalPath: finalPath ?? this.finalPath,
    metadata: metadata ?? this.metadata,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    etag: clearEtag ? null : etag ?? this.etag,
    expectedBytes: clearExpectedBytes
        ? null
        : expectedBytes ?? this.expectedBytes,
    integrity: clearIntegrity ? null : integrity ?? this.integrity,
    lastErrorCode: clearLastErrorCode
        ? null
        : lastErrorCode ?? this.lastErrorCode,
  );
}

class OfflineProgressRecord {
  const OfflineProgressRecord({
    required this.scope,
    required this.itemId,
    required this.positionTicks,
    required this.played,
    required this.updatedAt,
    required this.syncStatus,
    this.retryAfter,
  });

  final ServerScope scope;
  final String itemId;
  final int positionTicks;
  final bool played;
  final DateTime updatedAt;
  final String syncStatus;
  final DateTime? retryAfter;

  OfflineProgressRecord copyWith({
    int? positionTicks,
    bool? played,
    DateTime? updatedAt,
    String? syncStatus,
    DateTime? retryAfter,
    bool clearRetryAfter = false,
  }) => OfflineProgressRecord(
    scope: scope,
    itemId: itemId,
    positionTicks: positionTicks ?? this.positionTicks,
    played: played ?? this.played,
    updatedAt: updatedAt ?? this.updatedAt,
    syncStatus: syncStatus ?? this.syncStatus,
    retryAfter: clearRetryAfter ? null : retryAfter ?? this.retryAfter,
  );
}

class OfflineMediaItem {
  const OfflineMediaItem({
    required this.scope,
    required this.itemId,
    required this.mediaSourceId,
    required this.metadata,
    required this.localMediaPath,
    required this.completedAt,
    this.expectedBytes,
    this.integrity,
    this.progress,
  });

  final ServerScope scope;
  final String itemId;
  final String mediaSourceId;
  final OfflineMediaMetadata metadata;
  final String localMediaPath;
  final DateTime completedAt;
  // Hydrated from the existing task manifest; absent on legacy standalone items.
  final int? expectedBytes;
  final DownloadIntegrity? integrity;
  final OfflineProgressRecord? progress;

  EmbyItem toEmbyItem() {
    final offlineProgress = progress;
    return EmbyItem(
      id: itemId,
      name: metadata.name,
      type: metadata.itemType,
      mediaType: 'Video',
      overview: metadata.overview,
      seriesName: metadata.seriesName,
      seasonName: metadata.seasonName,
      runTimeTicks: metadata.runTimeTicks,
      indexNumber: metadata.indexNumber,
      parentIndexNumber: metadata.parentIndexNumber,
      imageTags: const {},
      backdropImageTags: const [],
      genres: const [],
      userData: EmbyUserData(
        playbackPositionTicks: offlineProgress?.positionTicks ?? 0,
        isPlayed: offlineProgress?.played ?? false,
      ),
      mediaSources: [
        PlaybackMediaSource(
          id: mediaSourceId,
          supportsDirectPlay: true,
          supportsDirectStream: false,
          supportsTranscoding: false,
          mediaStreams: metadata.playbackStreams,
          transcodingReasons: const [],
          container: metadata.container,
        ),
      ],
    );
  }
}

class DownloadSnapshot {
  DownloadSnapshot(Iterable<DownloadTaskRecord> tasks)
    : tasks = UnmodifiableListView(
        tasks.toList(growable: false)
          ..sort((left, right) => right.createdAt.compareTo(left.createdAt)),
      );

  final List<DownloadTaskRecord> tasks;
}

class DownloadCacheClearReport {
  const DownloadCacheClearReport({
    required this.totalTasks,
    required this.requestedTasks,
    required this.failedTasks,
    required this.estimatedBytes,
  });

  final int totalTasks;
  final int requestedTasks;
  final int failedTasks;
  final int estimatedBytes;

  bool get hasFailures => failedTasks > 0;
}

String? _string(dynamic value) {
  final result = value?.toString();
  return result == null || result.isEmpty ? null : result;
}

int? _integer(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
