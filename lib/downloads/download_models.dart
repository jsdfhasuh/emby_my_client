import 'dart:collection';

import '../core/server_scope.dart';
import '../models/emby_models.dart';

enum DownloadStatus { queued, running, paused, completed, failed, cancelling }

enum DownloadSourceKind { original }

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
    mediaStreams: source.mediaStreams,
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
  final List<Map<String, dynamic>> mediaStreams;

  List<String> get assetPaths {
    final result = <String>[];
    final imagePath = primaryImagePath;
    if (imagePath != null) result.add(imagePath);
    for (final stream in mediaStreams) {
      final deliveryUrl = stream['DeliveryUrl'];
      if (stream['Type']?.toString().toLowerCase() == 'subtitle' &&
          stream['IsExternal'] == true &&
          deliveryUrl is String) {
        result.add(deliveryUrl);
      }
    }
    return result;
  }

  OfflineMediaMetadata copyWith({
    List<Map<String, dynamic>>? mediaStreams,
    String? primaryImagePath,
    bool clearPrimaryImagePath = false,
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
    mediaStreams: mediaStreams ?? this.mediaStreams,
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
    'mediaStreams': mediaStreams,
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
  final String? lastErrorCode;

  String get displayName => metadata.name;
  String get itemType => metadata.itemType;
  String? get container => metadata.container;

  double? get progress {
    final total = expectedBytes;
    if (total == null || total <= 0) return null;
    return (downloadedBytes / total).clamp(0, 1);
  }

  bool get canPause => status == DownloadStatus.running;
  bool get canResume =>
      status == DownloadStatus.paused || status == DownloadStatus.failed;
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
    this.progress,
  });

  final ServerScope scope;
  final String itemId;
  final String mediaSourceId;
  final OfflineMediaMetadata metadata;
  final String localMediaPath;
  final DateTime completedAt;
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
          mediaStreams: metadata.mediaStreams,
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

String? _string(dynamic value) {
  final result = value?.toString();
  return result == null || result.isEmpty ? null : result;
}

int? _integer(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
