class EmbySession {
  const EmbySession({
    required this.serverUrl,
    required this.serverName,
    required this.serverId,
    required this.userId,
    required this.username,
    required this.accessToken,
    required this.deviceId,
    this.productName,
    this.serverVersion,
  });

  final String serverUrl;
  final String serverName;
  final String serverId;
  final String userId;
  final String username;
  final String accessToken;
  final String deviceId;
  final String? productName;
  final String? serverVersion;

  factory EmbySession.fromJson(Map<String, dynamic> json) => EmbySession(
    serverUrl: json['serverUrl'] as String,
    serverName: json['serverName'] as String? ?? 'Emby',
    serverId: json['serverId'] as String? ?? '',
    userId: json['userId'] as String,
    username: json['username'] as String,
    accessToken: json['accessToken'] as String,
    deviceId: json['deviceId'] as String,
    productName: json['productName'] as String?,
    serverVersion: json['serverVersion'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'serverName': serverName,
    'serverId': serverId,
    'userId': userId,
    'username': username,
    'accessToken': accessToken,
    'deviceId': deviceId,
    if (productName != null) 'productName': productName,
    if (serverVersion != null) 'serverVersion': serverVersion,
  };
}

class EmbyUserData {
  const EmbyUserData({
    this.playbackPositionTicks = 0,
    this.playedPercentage = 0,
    this.isPlayed = false,
    this.isFavorite = false,
  });

  final int playbackPositionTicks;
  final double playedPercentage;
  final bool isPlayed;
  final bool isFavorite;

  factory EmbyUserData.fromJson(Map<String, dynamic> json) => EmbyUserData(
    playbackPositionTicks: _asInt(json['PlaybackPositionTicks']) ?? 0,
    playedPercentage: _asDouble(json['PlayedPercentage']) ?? 0,
    isPlayed: json['Played'] as bool? ?? false,
    isFavorite: json['IsFavorite'] as bool? ?? false,
  );

  EmbyUserData copyWith({
    int? playbackPositionTicks,
    double? playedPercentage,
    bool? isPlayed,
    bool? isFavorite,
  }) => EmbyUserData(
    playbackPositionTicks: playbackPositionTicks ?? this.playbackPositionTicks,
    playedPercentage: playedPercentage ?? this.playedPercentage,
    isPlayed: isPlayed ?? this.isPlayed,
    isFavorite: isFavorite ?? this.isFavorite,
  );
}

class EmbyItem {
  const EmbyItem({
    required this.id,
    required this.name,
    required this.type,
    required this.imageTags,
    required this.backdropImageTags,
    required this.genres,
    required this.userData,
    this.chapters = const [],
    this.mediaSources = const [],
    this.trickplay,
    this.mediaType,
    this.collectionType,
    this.overview,
    this.seriesName,
    this.seasonName,
    this.productionYear,
    this.communityRating,
    this.runTimeTicks,
    this.indexNumber,
    this.parentIndexNumber,
    this.officialRating,
    this.primaryImageAspectRatio,
  });

  final String id;
  final String name;
  final String type;
  final String? mediaType;
  final String? collectionType;
  final String? overview;
  final String? seriesName;
  final String? seasonName;
  final int? productionYear;
  final double? communityRating;
  final int? runTimeTicks;
  final int? indexNumber;
  final int? parentIndexNumber;
  final String? officialRating;
  final double? primaryImageAspectRatio;
  final Map<String, String> imageTags;
  final List<String> backdropImageTags;
  final List<String> genres;
  final EmbyUserData userData;
  final List<EmbyChapter> chapters;
  final List<PlaybackMediaSource> mediaSources;
  final EmbyTrickplay? trickplay;

  bool get isPlayable =>
      mediaType == 'Video' ||
      type == 'Movie' ||
      type == 'Episode' ||
      type == 'Video';

  bool get isSeries => type == 'Series';

  double get progress => (userData.playedPercentage / 100).clamp(0.0, 1.0);

  Duration get resumePosition =>
      Duration(microseconds: userData.playbackPositionTicks ~/ 10);

  String get subtitle {
    if (type == 'Episode') {
      final season = parentIndexNumber?.toString().padLeft(2, '0');
      final episode = indexNumber?.toString().padLeft(2, '0');
      final number = season != null && episode != null
          ? 'S${season}E$episode'
          : '';
      return [
        number,
        seriesName,
      ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    }
    return productionYear?.toString() ?? type;
  }

  String? get runtimeLabel {
    final ticks = runTimeTicks;
    if (ticks == null || ticks <= 0) return null;
    final minutes = Duration(microseconds: ticks ~/ 10).inMinutes;
    if (minutes < 60) return '$minutes 分钟';
    return '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
  }

  factory EmbyItem.fromJson(Map<String, dynamic> json) {
    final rawTags = _asMap(json['ImageTags']);
    return EmbyItem(
      id: json['Id']?.toString() ?? '',
      name: json['Name']?.toString() ?? '未命名',
      type: json['Type']?.toString() ?? 'Unknown',
      mediaType: json['MediaType']?.toString(),
      collectionType: json['CollectionType']?.toString(),
      overview: json['Overview']?.toString(),
      seriesName: json['SeriesName']?.toString(),
      seasonName: json['SeasonName']?.toString(),
      productionYear: _asInt(json['ProductionYear']),
      communityRating: _asDouble(json['CommunityRating']),
      runTimeTicks: _asInt(json['RunTimeTicks']),
      indexNumber: _asInt(json['IndexNumber']),
      parentIndexNumber: _asInt(json['ParentIndexNumber']),
      officialRating: json['OfficialRating']?.toString(),
      primaryImageAspectRatio: _asDouble(json['PrimaryImageAspectRatio']),
      imageTags: rawTags.map((key, value) => MapEntry(key, value.toString())),
      backdropImageTags: _asStringList(json['BackdropImageTags']),
      genres: _asStringList(json['Genres']),
      userData: EmbyUserData.fromJson(_asMap(json['UserData'])),
      chapters: (json['Chapters'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (chapter) =>
                EmbyChapter.fromJson(Map<String, dynamic>.from(chapter)),
          )
          .toList(growable: false),
      mediaSources: (json['MediaSources'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (source) =>
                PlaybackMediaSource.fromJson(Map<String, dynamic>.from(source)),
          )
          .where((source) => source.id.isNotEmpty)
          .toList(growable: false),
      trickplay: EmbyTrickplay.fromJson(json['Trickplay']),
    );
  }

  EmbyItem copyWith({EmbyUserData? userData}) => EmbyItem(
    id: id,
    name: name,
    type: type,
    imageTags: imageTags,
    backdropImageTags: backdropImageTags,
    genres: genres,
    userData: userData ?? this.userData,
    chapters: chapters,
    mediaSources: mediaSources,
    trickplay: trickplay,
    mediaType: mediaType,
    collectionType: collectionType,
    overview: overview,
    seriesName: seriesName,
    seasonName: seasonName,
    productionYear: productionYear,
    communityRating: communityRating,
    runTimeTicks: runTimeTicks,
    indexNumber: indexNumber,
    parentIndexNumber: parentIndexNumber,
    officialRating: officialRating,
    primaryImageAspectRatio: primaryImageAspectRatio,
  );
}

class EmbyChapter {
  const EmbyChapter({
    required this.name,
    required this.startPositionTicks,
    this.markerType,
    this.imageTag,
  });

  final String name;
  final int startPositionTicks;
  final String? markerType;
  final String? imageTag;

  Duration get position => Duration(microseconds: startPositionTicks ~/ 10);

  factory EmbyChapter.fromJson(Map<String, dynamic> json) => EmbyChapter(
    name: json['Name']?.toString() ?? '章节',
    startPositionTicks: _asInt(json['StartPositionTicks']) ?? 0,
    markerType: _nonEmptyString(json['MarkerType']),
    imageTag: _nonEmptyString(json['ImageTag']),
  );
}

class EmbyTrickplay {
  const EmbyTrickplay(this.sources);

  final Map<String, List<EmbyTrickplayResolution>> sources;

  EmbyTrickplayResolution? resolutionFor(String? mediaSourceId) {
    final candidates =
        (mediaSourceId == null ? null : sources[mediaSourceId]) ??
        sources.values.firstOrNull;
    if (candidates == null || candidates.isEmpty) return null;
    final sorted = List<EmbyTrickplayResolution>.of(candidates)
      ..sort(
        (left, right) =>
            (left.width - 320).abs().compareTo((right.width - 320).abs()),
      );
    return sorted.first;
  }

  static EmbyTrickplay? fromJson(dynamic value) {
    final rawSources = _asMap(value);
    if (rawSources.isEmpty) return null;
    final parsed = <String, List<EmbyTrickplayResolution>>{};
    for (final source in rawSources.entries) {
      final rawResolutions = _asMap(source.value);
      final resolutions = rawResolutions.values
          .map(EmbyTrickplayResolution.fromJson)
          .whereType<EmbyTrickplayResolution>()
          .toList(growable: false);
      if (resolutions.isNotEmpty) parsed[source.key] = resolutions;
    }
    return parsed.isEmpty ? null : EmbyTrickplay(parsed);
  }
}

class EmbyTrickplayResolution {
  const EmbyTrickplayResolution({
    required this.width,
    required this.height,
    required this.tileColumns,
    required this.tileRows,
    required this.intervalMilliseconds,
  });

  final int width;
  final int height;
  final int tileColumns;
  final int tileRows;
  final int intervalMilliseconds;

  int get tilesPerImage => tileColumns * tileRows;

  static EmbyTrickplayResolution? fromJson(dynamic value) {
    final json = _asMap(value);
    final width = _asInt(json['Width']) ?? 0;
    final height = _asInt(json['Height']) ?? 0;
    final columns = _asInt(json['TileWidth']) ?? 0;
    final rows = _asInt(json['TileHeight']) ?? 0;
    final interval = _asInt(json['Interval']) ?? 0;
    if (width <= 0 ||
        height <= 0 ||
        columns <= 0 ||
        rows <= 0 ||
        interval <= 0) {
      return null;
    }
    return EmbyTrickplayResolution(
      width: width,
      height: height,
      tileColumns: columns,
      tileRows: rows,
      intervalMilliseconds: interval,
    );
  }
}

class HomeData {
  const HomeData({
    required this.views,
    required this.resume,
    required this.latest,
  });

  final List<EmbyItem> views;
  final List<EmbyItem> resume;
  final List<EmbyItem> latest;
}

enum PlayMethod {
  directPlay('DirectPlay'),
  directStream('DirectStream'),
  transcode('Transcode');

  const PlayMethod(this.serverValue);
  final String serverValue;
}

class PlaybackMediaSource {
  const PlaybackMediaSource({
    required this.id,
    required this.supportsDirectPlay,
    required this.supportsDirectStream,
    required this.supportsTranscoding,
    required this.mediaStreams,
    required this.transcodingReasons,
    this.name,
    this.path,
    this.protocol,
    this.container,
    this.bitrate,
    this.size,
    this.directStreamUrl,
    this.transcodingUrl,
    this.liveStreamId,
    this.defaultAudioStreamIndex,
    this.defaultSubtitleStreamIndex,
  });

  final String id;
  final bool supportsDirectPlay;
  final bool supportsDirectStream;
  final bool supportsTranscoding;
  final String? name;
  final String? path;
  final String? protocol;
  final String? container;
  final int? bitrate;
  final int? size;
  final String? directStreamUrl;
  final String? transcodingUrl;
  final String? liveStreamId;
  final int? defaultAudioStreamIndex;
  final int? defaultSubtitleStreamIndex;
  final List<Map<String, dynamic>> mediaStreams;
  final List<String> transcodingReasons;

  factory PlaybackMediaSource.fromJson(Map<String, dynamic> json) =>
      PlaybackMediaSource(
        id: json['Id']?.toString() ?? '',
        supportsDirectPlay: json['SupportsDirectPlay'] as bool? ?? false,
        supportsDirectStream: json['SupportsDirectStream'] as bool? ?? false,
        supportsTranscoding: json['SupportsTranscoding'] as bool? ?? false,
        name: json['Name']?.toString(),
        path: json['Path']?.toString(),
        protocol: json['Protocol']?.toString(),
        container: json['Container']?.toString(),
        bitrate: _asInt(json['Bitrate']),
        size: _asInt(json['Size']),
        directStreamUrl: json['DirectStreamUrl']?.toString(),
        transcodingUrl: json['TranscodingUrl']?.toString(),
        liveStreamId: json['LiveStreamId']?.toString(),
        defaultAudioStreamIndex: _asInt(json['DefaultAudioStreamIndex']),
        defaultSubtitleStreamIndex: _asInt(json['DefaultSubtitleStreamIndex']),
        mediaStreams: (json['MediaStreams'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        transcodingReasons: _asStringList(json['TranscodingReasons']),
      );
}

class PlaybackInfoResult {
  const PlaybackInfoResult({
    required this.mediaSources,
    this.playSessionId,
    this.errorCode,
  });

  final List<PlaybackMediaSource> mediaSources;
  final String? playSessionId;
  final String? errorCode;

  factory PlaybackInfoResult.fromJson(
    Map<String, dynamic> json,
  ) => PlaybackInfoResult(
    mediaSources: (json['MediaSources'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (source) =>
              PlaybackMediaSource.fromJson(Map<String, dynamic>.from(source)),
        )
        .toList(growable: false),
    playSessionId: _nonEmptyString(json['PlaySessionId']),
    errorCode: _nonEmptyString(json['ErrorCode']),
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.uri,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.method,
    required this.mediaStreams,
    required this.transcodingReasons,
    required this.availableMediaSources,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.liveStreamId,
    this.mediaSourceName,
    this.container,
    this.bitrate,
    this.errorCode,
  });

  final Uri uri;
  final String mediaSourceId;
  final String? playSessionId;
  final PlayMethod method;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final String? liveStreamId;
  final String? mediaSourceName;
  final String? container;
  final int? bitrate;
  final String? errorCode;
  final List<Map<String, dynamic>> mediaStreams;
  final List<String> transcodingReasons;
  final List<PlaybackMediaSource> availableMediaSources;

  PlaybackPlan copyWith({
    Uri? uri,
    String? mediaSourceId,
    String? playSessionId,
    bool clearPlaySessionId = false,
    PlayMethod? method,
    int? audioStreamIndex,
    bool clearAudioStreamIndex = false,
    int? subtitleStreamIndex,
    bool clearSubtitleStreamIndex = false,
    String? liveStreamId,
    bool clearLiveStreamId = false,
    String? mediaSourceName,
    String? container,
    int? bitrate,
    String? errorCode,
    List<Map<String, dynamic>>? mediaStreams,
    List<String>? transcodingReasons,
    List<PlaybackMediaSource>? availableMediaSources,
  }) => PlaybackPlan(
    uri: uri ?? this.uri,
    mediaSourceId: mediaSourceId ?? this.mediaSourceId,
    playSessionId: clearPlaySessionId
        ? null
        : playSessionId ?? this.playSessionId,
    method: method ?? this.method,
    audioStreamIndex: clearAudioStreamIndex
        ? null
        : audioStreamIndex ?? this.audioStreamIndex,
    subtitleStreamIndex: clearSubtitleStreamIndex
        ? null
        : subtitleStreamIndex ?? this.subtitleStreamIndex,
    liveStreamId: clearLiveStreamId ? null : liveStreamId ?? this.liveStreamId,
    mediaSourceName: mediaSourceName ?? this.mediaSourceName,
    container: container ?? this.container,
    bitrate: bitrate ?? this.bitrate,
    errorCode: errorCode ?? this.errorCode,
    mediaStreams: mediaStreams ?? this.mediaStreams,
    transcodingReasons: transcodingReasons ?? this.transcodingReasons,
    availableMediaSources: availableMediaSources ?? this.availableMediaSources,
  );
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

List<String> _asStringList(dynamic value) =>
    value is List ? value.map((e) => e.toString()).toList() : const [];

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _asDouble(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String? _nonEmptyString(dynamic value) {
  final result = value?.toString();
  return result == null || result.isEmpty ? null : result;
}
