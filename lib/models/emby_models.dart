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
    this.unplayedItemCount = 0,
    this.playCount = 0,
  });

  final int playbackPositionTicks;
  final double playedPercentage;
  final bool isPlayed;
  final bool isFavorite;
  final int unplayedItemCount;
  final int playCount;

  factory EmbyUserData.fromJson(Map<String, dynamic> json) => EmbyUserData(
    playbackPositionTicks: _asInt(json['PlaybackPositionTicks']) ?? 0,
    playedPercentage: _asDouble(json['PlayedPercentage']) ?? 0,
    isPlayed: json['Played'] as bool? ?? false,
    isFavorite: json['IsFavorite'] as bool? ?? false,
    unplayedItemCount: _asInt(json['UnplayedItemCount']) ?? 0,
    playCount: _asInt(json['PlayCount']) ?? 0,
  );

  EmbyUserData copyWith({
    int? playbackPositionTicks,
    double? playedPercentage,
    bool? isPlayed,
    bool? isFavorite,
    int? unplayedItemCount,
    int? playCount,
  }) => EmbyUserData(
    playbackPositionTicks: playbackPositionTicks ?? this.playbackPositionTicks,
    playedPercentage: playedPercentage ?? this.playedPercentage,
    isPlayed: isPlayed ?? this.isPlayed,
    isFavorite: isFavorite ?? this.isFavorite,
    unplayedItemCount: unplayedItemCount ?? this.unplayedItemCount,
    playCount: playCount ?? this.playCount,
  );
}

class EmbyPerson {
  const EmbyPerson({
    required this.name,
    required this.type,
    this.id,
    this.role,
    this.primaryImageTag,
  });

  final String? id;
  final String name;
  final String type;
  final String? role;
  final String? primaryImageTag;

  bool get isCast {
    final normalizedType = type.trim().toLowerCase();
    return normalizedType == 'actor' || normalizedType == 'gueststar';
  }

  bool get isNavigable => id != null && id!.isNotEmpty;

  static EmbyPerson? fromJson(Map<String, dynamic> json) {
    final name = _personString(json['Name']);
    if (name == null) return null;
    return EmbyPerson(
      id: _personString(json['Id']),
      name: name,
      type: _personString(json['Type']) ?? '',
      role: _personString(json['Role']),
      primaryImageTag: _personString(json['PrimaryImageTag']),
    );
  }
}

String? _personString(dynamic value) {
  if (value is! String) return null;
  final result = value.trim();
  return result.isEmpty ? null : result;
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
    this.tags = const [],
    this.people = const [],
    this.chapters = const [],
    this.mediaSources = const [],
    this.trickplay,
    this.mediaType,
    this.collectionType,
    this.parentId,
    this.path,
    this.container,
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
  final String? parentId;
  final String? path;
  final String? container;
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
  final List<String> tags;
  final List<EmbyPerson> people;
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

  bool get isFolder => isLibraryContainer;

  bool get isLibraryContainer =>
      type == 'Folder' || type == 'CollectionFolder' || type == 'PhotoAlbum';

  bool get isPhoto => type == 'Photo';

  bool get isPhotoContainer => isLibraryContainer;

  bool get isPhotoLibrary => collectionType?.toLowerCase() == 'photos';

  bool get isStrm =>
      _isStrmReference(path) ||
      _isStrmContainer(container) ||
      mediaSources.any(
        (source) =>
            _isStrmReference(source.path) || _isStrmContainer(source.container),
      );

  double get progress => (userData.playedPercentage / 100).clamp(0.0, 1.0);

  Duration get resumePosition =>
      Duration(microseconds: userData.playbackPositionTicks ~/ 10);

  String get subtitle {
    if (type == 'PhotoAlbum') return '相册';
    if (isFolder) return '目录';
    if (isPhoto) return '图片';
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
      parentId: _trimmedString(json['ParentId']),
      path: json['Path']?.toString(),
      container: json['Container']?.toString(),
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
      tags: _asStringList(json['Tags']),
      people: _parsePeople(json['People']),
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
    tags: tags,
    people: people,
    userData: userData ?? this.userData,
    chapters: chapters,
    mediaSources: mediaSources,
    trickplay: trickplay,
    mediaType: mediaType,
    collectionType: collectionType,
    parentId: parentId,
    path: path,
    container: container,
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

List<EmbyPerson> _parsePeople(dynamic value) {
  if (value is! List) return const [];
  final people = <EmbyPerson>[];
  final indexesById = <String, int>{};
  final seenAnonymous = <String>{};
  for (final entry in value.whereType<Map>()) {
    final person = EmbyPerson.fromJson(Map<String, dynamic>.from(entry));
    if (person == null) continue;
    final id = person.id;
    if (id != null) {
      final existingIndex = indexesById[id];
      if (existingIndex == null) {
        indexesById[id] = people.length;
        people.add(person);
      } else {
        people[existingIndex] = _mergePerson(people[existingIndex], person);
      }
      continue;
    }
    final key =
        '${_normalizePersonField(person.type)}\u0000'
        '${_normalizePersonField(person.name)}\u0000'
        '${_normalizePersonField(person.role ?? '')}';
    if (seenAnonymous.add(key)) people.add(person);
  }
  return List.unmodifiable(people);
}

EmbyPerson _mergePerson(EmbyPerson first, EmbyPerson later) {
  final preferred = !first.isCast && later.isCast ? later : first;
  final fallback = identical(preferred, first) ? later : first;
  final role =
      preferred.role ??
      (preferred.isCast && !fallback.isCast ? null : fallback.role);
  return EmbyPerson(
    id: first.id,
    name: preferred.name,
    type: preferred.type,
    role: role,
    primaryImageTag: preferred.primaryImageTag ?? fallback.primaryImageTag,
  );
}

String _normalizePersonField(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool _isStrmReference(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return false;
  return normalized.split(RegExp(r'[?#]')).first.endsWith('.strm');
}

bool _isStrmContainer(String? value) => value?.trim().toLowerCase() == 'strm';

enum SearchItemType {
  all('Movie,Series,Episode,Video,Photo,Folder,CollectionFolder,PhotoAlbum'),
  movie('Movie'),
  series('Series'),
  episode('Episode'),
  video('Video'),
  photo('Photo'),
  folder('Folder,CollectionFolder,PhotoAlbum');

  const SearchItemType(this.apiValue);

  final String apiValue;
}

enum PersonMediaFilter {
  all('Movie,Series'),
  movie('Movie'),
  series('Series');

  const PersonMediaFilter(this.apiValue);

  final String apiValue;
}

class EmbyItemPage {
  const EmbyItemPage({
    required this.items,
    this.totalRecordCount,
    int? rawItemCount,
  }) : _rawItemCount = rawItemCount;

  final List<EmbyItem> items;
  final int? totalRecordCount;
  final int? _rawItemCount;

  int get rawItemCount => _rawItemCount ?? items.length;
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

  EmbyTrickplaySelection? selectionFor(String? mediaSourceId) {
    if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
      final exact = sources[mediaSourceId];
      if (exact != null && exact.isNotEmpty) {
        return EmbyTrickplaySelection(
          mediaSourceId: mediaSourceId,
          resolution: _preferredResolution(exact),
          sourceMatch: EmbyTrickplaySourceMatch.exact,
        );
      }
    }

    if (sources.length != 1) return null;
    final entry = sources.entries.single;
    if (entry.value.isEmpty) return null;
    return EmbyTrickplaySelection(
      mediaSourceId: entry.key,
      resolution: _preferredResolution(entry.value),
      sourceMatch: EmbyTrickplaySourceMatch.singleFallback,
    );
  }

  EmbyTrickplayResolution? resolutionFor(String? mediaSourceId) {
    return selectionFor(mediaSourceId)?.resolution;
  }

  static EmbyTrickplayResolution _preferredResolution(
    List<EmbyTrickplayResolution> candidates,
  ) {
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
      if (source.key.isEmpty) continue;
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

enum EmbyTrickplaySourceMatch { exact, singleFallback }

class EmbyTrickplaySelection {
  const EmbyTrickplaySelection({
    required this.mediaSourceId,
    required this.resolution,
    required this.sourceMatch,
  });

  final String mediaSourceId;
  final EmbyTrickplayResolution resolution;
  final EmbyTrickplaySourceMatch sourceMatch;
}

class EmbyTrickplayResolution {
  const EmbyTrickplayResolution({
    required this.width,
    required this.height,
    required this.tileColumns,
    required this.tileRows,
    required this.intervalMilliseconds,
    this.thumbnailCount,
  });

  final int width;
  final int height;
  final int tileColumns;
  final int tileRows;
  final int intervalMilliseconds;
  final int? thumbnailCount;

  int get tilesPerImage => tileColumns * tileRows;

  static EmbyTrickplayResolution? fromJson(dynamic value) {
    final json = _asMap(value);
    final width = _asInt(json['Width']) ?? 0;
    final height = _asInt(json['Height']) ?? 0;
    final columns = _asInt(json['TileWidth']) ?? 0;
    final rows = _asInt(json['TileHeight']) ?? 0;
    final interval = _asInt(json['Interval']) ?? 0;
    final rawThumbnailCount = _asInt(json['ThumbnailCount']);
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
      thumbnailCount: rawThumbnailCount != null && rawThumbnailCount > 0
          ? rawThumbnailCount
          : null,
    );
  }
}

class HomeLatestSection {
  const HomeLatestSection({required this.library, required this.items});

  final EmbyItem library;
  final List<EmbyItem> items;
}

class HomeData {
  const HomeData({
    required this.views,
    required this.resume,
    required this.latestSections,
  });

  final List<EmbyItem> views;
  final List<EmbyItem> resume;
  final List<HomeLatestSection> latestSections;
}

enum PlayMethod {
  directPlay('DirectPlay'),
  directStream('DirectStream'),
  transcode('Transcode');

  const PlayMethod(this.serverValue);
  final String serverValue;
}

enum PlaybackTransportKind {
  offlineLocal,
  progressiveHttp,
  segmentedHttp,
  live,
  unknown,
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
    this.runTimeTicks,
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
  final int? runTimeTicks;
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
        size: _positiveInt(json['Size']),
        runTimeTicks: _asInt(json['RunTimeTicks']),
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
    required this.usesServerAuthentication,
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
    this.sourceProtocol,
    this.duration,
    this.transportKind = PlaybackTransportKind.unknown,
    this.sourceSizeBytes,
  });

  final Uri uri;
  final String mediaSourceId;
  final String? playSessionId;
  final PlayMethod method;
  final bool usesServerAuthentication;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final String? liveStreamId;
  final String? mediaSourceName;
  final String? container;
  final int? bitrate;
  final String? errorCode;
  final String? sourceProtocol;
  final Duration? duration;
  final PlaybackTransportKind transportKind;
  final int? sourceSizeBytes;
  final List<Map<String, dynamic>> mediaStreams;
  final List<String> transcodingReasons;
  final List<PlaybackMediaSource> availableMediaSources;

  PlaybackPlan copyWith({
    Uri? uri,
    String? mediaSourceId,
    String? playSessionId,
    bool clearPlaySessionId = false,
    PlayMethod? method,
    bool? usesServerAuthentication,
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
    String? sourceProtocol,
    Duration? duration,
    PlaybackTransportKind? transportKind,
    int? sourceSizeBytes,
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
    usesServerAuthentication:
        usesServerAuthentication ?? this.usesServerAuthentication,
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
    sourceProtocol: sourceProtocol ?? this.sourceProtocol,
    duration: duration ?? this.duration,
    transportKind: transportKind ?? this.transportKind,
    sourceSizeBytes: sourceSizeBytes ?? this.sourceSizeBytes,
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

int? _positiveInt(dynamic value) {
  final parsed = switch (value) {
    int number => number,
    num number when number.isFinite && number == number.truncateToDouble() =>
      number.toInt(),
    String text => _parseBoundedInt(text),
    _ => null,
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

int? _parseBoundedInt(String value) {
  final parsed = BigInt.tryParse(value.trim());
  if (parsed == null || parsed <= BigInt.zero) return null;
  const maximum = 9223372036854775807;
  final maximumValue = BigInt.from(maximum);
  return parsed > maximumValue ? null : parsed.toInt();
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

String? _trimmedString(dynamic value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}
