import 'dart:async';

import 'package:dio/dio.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import '../realtime/emby_websocket_client.dart';
import 'emby_session_service.dart';
import 'emby_user_data_service.dart';

class EmbyApiException implements Exception {
  const EmbyApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isAuthenticationFailure => statusCode == 401 || statusCode == 403;

  bool get allowsPlaybackInfoFallback =>
      statusCode == 400 || statusCode == 422 || statusCode == 500;

  @override
  String toString() => message;
}

class EmbyApi {
  EmbyApi(
    this.session, {
    Dio? dio,
    FutureOr<void> Function()? onSessionExpired,
    FutureOr<void> Function()? onRemoteCapabilitiesReported,
    FutureOr<void> Function()? onRealtimeConnected,
  }) : _dio = dio ?? _createDio(session),
       _onSessionExpired = onSessionExpired,
       _onRemoteCapabilitiesReported = onRemoteCapabilitiesReported,
       _onRealtimeConnected = onRealtimeConnected {
    if (dio != null) {
      _configureDio(dio, session);
    }
    userData = EmbyUserDataService(
      session: session,
      dio: _dio,
      execute: _request,
    );
    sessionControl = EmbySessionService(dio: _dio, execute: _request);
    realtime = EmbyWebSocketClient(
      session,
      onConnected: _handleRealtimeConnected,
    );
  }

  static const clientName = 'Emby Flutter Client';
  static const clientVersion = '1.0.0';
  static const _listItemFields =
      'PrimaryImageAspectRatio,DateCreated,OfficialRating,CommunityRating,'
      'RunTimeTicks,ProductionYear,ParentId,Path';
  static const _detailItemFields =
      'Overview,Genres,MediaSources,MediaStreams,PrimaryImageAspectRatio,'
      'DateCreated,OfficialRating,CommunityRating,RunTimeTicks,'
      'ProductionYear,ProviderIds,ParentId,Path,Chapters,Trickplay';

  final EmbySession session;
  final Dio _dio;
  final FutureOr<void> Function()? _onSessionExpired;
  final FutureOr<void> Function()? _onRemoteCapabilitiesReported;
  final FutureOr<void> Function()? _onRealtimeConnected;
  late final EmbyUserDataService userData;
  late final EmbySessionService sessionControl;
  late final EmbyWebSocketClient realtime;

  Map<String, String> get playbackHeaders => {
    'X-Emby-Token': session.accessToken,
    'X-Emby-Authorization': _authorizationHeader(
      session.deviceId,
      token: session.accessToken,
    ),
  };

  Map<String, String> get imageHeaders => playbackHeaders;

  List<Uri> originalDownloadUris({
    required String itemId,
    required String mediaSourceId,
  }) {
    final encodedItemId = Uri.encodeComponent(itemId);
    final mediaSourceQuery = {'MediaSourceId': mediaSourceId};
    return [
      Uri.parse(
        '${session.serverUrl}/Items/$encodedItemId/Download',
      ).replace(queryParameters: mediaSourceQuery),
      Uri.parse('${session.serverUrl}/Items/$encodedItemId/Download'),
      Uri.parse(
        '${session.serverUrl}/Items/$encodedItemId/File',
      ).replace(queryParameters: mediaSourceQuery),
      Uri.parse(
        '${session.serverUrl}/Videos/$encodedItemId/stream',
      ).replace(queryParameters: {...mediaSourceQuery, 'Static': 'true'}),
    ];
  }

  Future<Response<ResponseBody>> openDownload(
    Uri uri, {
    required CancelToken cancelToken,
    int offset = 0,
    String? etag,
  }) async {
    final headers = <String, String>{
      'Accept-Encoding': 'identity',
      if (offset > 0) 'Range': 'bytes=$offset-',
      if (offset > 0 && etag != null && etag.isNotEmpty) 'If-Range': etag,
    };
    try {
      return await _dio.getUri<ResponseBody>(
        uri,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          validateStatus: (status) =>
              status == 200 || status == 206 || status == 416,
        ),
      );
    } on DioException catch (error) {
      DiagnosticLog.instance.error(
        'download',
        'GET ${error.requestOptions.uri} failed with '
            'HTTP ${error.response?.statusCode ?? 'none'}',
        error: error.message,
      );
      final friendly = _friendlyError(error);
      if (friendly.isAuthenticationFailure && _onSessionExpired != null) {
        unawaited(Future<void>.sync(_onSessionExpired));
      }
      throw friendly;
    }
  }

  static Future<EmbySession> authenticate({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final normalized = normalizeServerUrl(serverUrl);
    DiagnosticLog.instance.info('auth', 'Connecting to $normalized');
    final dio = Dio(
      BaseOptions(
        baseUrl: normalized,
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        headers: {
          'Accept': 'application/json',
          'X-Emby-Authorization': _authorizationHeader(deviceId),
        },
      ),
    );

    try {
      final infoResponse = await dio.get<dynamic>('/System/Info/Public');
      final info = _map(infoResponse.data);
      final response = await dio.post<dynamic>(
        '/Users/AuthenticateByName',
        data: {'Username': username, 'Pw': password},
      );
      final body = _map(response.data);
      final user = _map(body['User']);
      final token = body['AccessToken']?.toString();
      final userId = user['Id']?.toString();
      if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
        throw const EmbyApiException('服务器没有返回有效的登录会话');
      }
      DiagnosticLog.instance.info('auth', 'Authentication succeeded');
      return EmbySession(
        serverUrl: normalized,
        serverName: info['ServerName']?.toString() ?? 'Emby',
        serverId: body['ServerId']?.toString() ?? info['Id']?.toString() ?? '',
        userId: userId,
        username: user['Name']?.toString() ?? username,
        accessToken: token,
        deviceId: deviceId,
        productName: info['ProductName']?.toString(),
        serverVersion: info['Version']?.toString(),
      );
    } on EmbyApiException {
      rethrow;
    } on DioException catch (error) {
      throw _friendlyError(error, duringLogin: true);
    } on FormatException {
      throw const EmbyApiException('服务器返回了无法识别的数据');
    }
  }

  static String normalizeServerUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) {
      throw const EmbyApiException('请输入 Emby 服务器地址');
    }
    if (!value.contains('://')) value = 'http://$value';

    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const EmbyApiException('服务器地址必须是有效的 HTTP 或 HTTPS 地址');
    }

    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final webIndex = path.toLowerCase().indexOf('/web');
    if (webIndex >= 0) path = path.substring(0, webIndex);
    return '${uri.scheme}://${uri.authority}$path';
  }

  static Dio _createDio(EmbySession session) => Dio(
    BaseOptions(
      baseUrl: session.serverUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      sendTimeout: const Duration(seconds: 20),
      headers: {
        'Accept': 'application/json',
        'X-Emby-Token': session.accessToken,
        'X-Emby-Authorization': _authorizationHeader(
          session.deviceId,
          token: session.accessToken,
        ),
      },
    ),
  );

  static void _configureDio(Dio dio, EmbySession session) {
    if (dio.options.baseUrl.isEmpty) {
      dio.options.baseUrl = session.serverUrl;
    }
    dio.options.headers.addAll({
      'Accept': 'application/json',
      'X-Emby-Token': session.accessToken,
      'X-Emby-Authorization': _authorizationHeader(
        session.deviceId,
        token: session.accessToken,
      ),
    });
  }

  static String _authorizationHeader(String deviceId, {String? token}) {
    final safeId = deviceId.replaceAll('"', '');
    return 'MediaBrowser Client="$clientName", Device="Android", '
        'DeviceId="$safeId", Version="$clientVersion"'
        '${token == null ? '' : ', Token="$token"'}';
  }

  Future<void> logout() async {
    await _request(() => _dio.post<dynamic>('/Sessions/Logout'));
  }

  Future<void> _reportRemoteCapabilities() async {
    await sessionControl.reportCapabilities();
    final callback = _onRemoteCapabilitiesReported;
    if (callback != null) await Future<void>.sync(callback);
  }

  Future<void> _handleRealtimeConnected() async {
    final operations = <Future<void>>[
      _runConnectedAction(
        _reportRemoteCapabilities,
        'Failed to report WebSocket session capabilities',
      ),
    ];
    final callback = _onRealtimeConnected;
    if (callback != null) {
      operations.add(
        _runConnectedAction(
          () => Future<void>.sync(callback),
          'Failed to handle WebSocket reconnect',
        ),
      );
    }
    await Future.wait(operations);
  }

  Future<void> _runConnectedAction(
    Future<void> Function() action,
    String failureMessage,
  ) async {
    try {
      await action();
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'realtime',
        failureMessage,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> dispose() async {
    await realtime.dispose();
    _dio.close(force: true);
  }

  Future<HomeData> getHome() async {
    final base = await getHomeBase();
    final latestSections = <HomeLatestSection>[];
    const concurrency = 4;
    for (var start = 0; start < base.views.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, base.views.length);
      final batch = await Future.wait(
        base.views.sublist(start, end).map(getHomeLatestSection),
      );
      latestSections.addAll(batch.whereType<HomeLatestSection>());
    }
    return HomeData(
      views: base.views,
      resume: base.resume,
      latestSections: latestSections,
    );
  }

  Future<HomeData> getHomeBase() async {
    final result = await Future.wait<List<EmbyItem>>([
      getViews(),
      getResumeItems(),
    ]);
    return HomeData(
      views: result[0],
      resume: result[1],
      latestSections: const [],
    );
  }

  Future<HomeLatestSection?> getHomeLatestSection(EmbyItem library) async {
    try {
      final items = await getLatestItems(parentId: library.id, limit: 18);
      if (items.isEmpty) return null;
      return HomeLatestSection(library: library, items: items);
    } catch (error) {
      DiagnosticLog.instance.warning(
        'home',
        'Skipped latest shelf library=${library.id}: $error',
      );
      return null;
    }
  }

  Future<List<EmbyItem>> getViews() => _getItemPage(
    '/Users/${session.userId}/Views',
    query: {'Fields': _listItemFields},
  );

  Future<List<EmbyItem>> getResumeItems({int limit = 20}) => _getItemPage(
    '/Users/${session.userId}/Items/Resume',
    query: {
      'Limit': limit,
      'MediaTypes': 'Video',
      'Recursive': true,
      'Fields': _listItemFields,
      'EnableUserData': true,
      'EnableImages': true,
    },
  );

  Future<List<EmbyItem>> getLatestItems({String? parentId, int limit = 24}) =>
      _getItemPage(
        '/Users/${session.userId}/Items/Latest',
        query: {
          'ParentId': ?parentId,
          'Limit': limit,
          'IncludeItemTypes': 'Movie,Series,Episode,Video',
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'GroupItems': true,
        },
      );

  Future<EmbyItemPage> getLibraryItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryBrowseOptions options = const LibraryBrowseOptions(),
  }) async {
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': options.itemType.recursive,
          'IncludeItemTypes': options.itemType.apiValue,
          'SortBy': options.sortBy.apiValue,
          'SortOrder': options.sortOrder.apiValue,
          'Filters': ?options.playedFilter.apiValue,
          if (options.favoriteOnly) 'IsFavorite': true,
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    final data = _map(response.data);
    final rawItems = data['Items'] as List<dynamic>? ?? const [];
    final items = rawItems
        .whereType<Map>()
        .map((item) => EmbyItem.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
    final rawTotal = data['TotalRecordCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return EmbyItemPage(items: items, totalRecordCount: total);
  }

  Future<EmbyItemPage> search(
    String term, {
    int startIndex = 0,
    int limit = 60,
    SearchItemType itemType = SearchItemType.all,
  }) async {
    final query = term.trim();
    if (query.isEmpty) {
      return const EmbyItemPage(items: [], totalRecordCount: 0);
    }
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'SearchTerm': query,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': true,
          'IncludeItemTypes': itemType.apiValue,
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    final data = _map(response.data);
    final rawItems = data['Items'] as List<dynamic>? ?? const [];
    final items = rawItems
        .whereType<Map>()
        .map((item) => EmbyItem.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
    final rawTotal = data['TotalRecordCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return EmbyItemPage(items: items, totalRecordCount: total);
  }

  Future<EmbyItem> getItem(String itemId) async {
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items/$itemId',
        queryParameters: {'Fields': _detailItemFields},
      ),
    );
    return EmbyItem.fromJson(_map(response.data));
  }

  Future<List<EmbyItem>> getSeasons(String seriesId) => _getItemPage(
    '/Shows/$seriesId/Seasons',
    query: {
      'UserId': session.userId,
      'Fields': _listItemFields,
      'EnableUserData': true,
    },
  );

  Future<List<EmbyItem>> getEpisodes(String seriesId, {String? seasonId}) =>
      _getItemPage(
        '/Shows/$seriesId/Episodes',
        query: {
          'UserId': session.userId,
          'SeasonId': ?seasonId,
          'Fields': _listItemFields,
          'EnableUserData': true,
        },
      );

  Future<Map<String, EmbyUserData>> getUserDataForItems(
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const {};
    final items = await _getItemPage(
      '/Users/${Uri.encodeComponent(session.userId)}/Items',
      query: {
        'Ids': ids.join(','),
        'Fields': 'UserData',
        'EnableUserData': true,
      },
    );
    return {for (final item in items) item.id: item.userData};
  }

  String? imageUrl(
    EmbyItem item, {
    String type = 'Primary',
    int maxWidth = 600,
    int quality = 90,
  }) {
    final tag = type == 'Backdrop'
        ? item.backdropImageTags.firstOrNull
        : item.imageTags[type];
    if (tag == null || tag.isEmpty) return null;
    return Uri.parse('${session.serverUrl}/Items/${item.id}/Images/$type')
        .replace(
          queryParameters: {
            'tag': tag,
            'maxWidth': maxWidth.toString(),
            'quality': quality.toString(),
          },
        )
        .toString();
  }

  Future<PlaybackPlan> getPlaybackPlan(
    EmbyItem item, {
    int? mediaSourceIndex,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async {
    DiagnosticLog.instance.info(
      'playback',
      'Requesting PlaybackInfo item=${item.id} '
          'resumeTicks=${item.userData.playbackPositionTicks} '
          'forceTranscode=$forceTranscode',
    );

    final info = await getPlaybackInfo(
      item,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      maxStreamingBitrate: maxStreamingBitrate,
      forceTranscode: forceTranscode,
    );
    final sources = info.mediaSources;
    if (sources.isEmpty) {
      final suffix = info.errorCode == null ? '' : '（${info.errorCode}）';
      throw EmbyApiException('服务器没有提供可播放的媒体源$suffix');
    }
    DiagnosticLog.instance.info(
      'playback',
      'PlaybackInfo returned ${sources.length} source(s): '
          '${sources.map((source) => '${source.id}'
              '(direct=${source.supportsDirectPlay},'
              'stream=${source.supportsDirectStream},'
              'transcode=${source.supportsTranscoding})').join(', ')}',
    );

    PlaybackMediaSource? preferredSource;
    if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
      preferredSource = sources
          .where((source) => source.id == mediaSourceId)
          .firstOrNull;
      if (preferredSource == null) {
        DiagnosticLog.instance.warning(
          'playback',
          'Requested media source $mediaSourceId is unavailable; '
              'using server selection',
        );
      }
    } else if (mediaSourceIndex != null &&
        mediaSourceIndex >= 0 &&
        mediaSourceIndex < sources.length) {
      preferredSource = sources[mediaSourceIndex];
    }

    final source =
        preferredSource != null &&
            (!forceTranscode ||
                (preferredSource.supportsTranscoding &&
                    preferredSource.transcodingUrl != null))
        ? preferredSource
        : _bestSource(sources, forceTranscode: forceTranscode);

    late final Uri uri;
    late final PlayMethod method;
    if (forceTranscode) {
      if (!source.supportsTranscoding || source.transcodingUrl == null) {
        throw const EmbyApiException('服务器没有提供可用的转码流');
      }
      uri = _streamUri(
        source.transcodingUrl!,
        audioStreamIndex: audioStreamIndex ?? source.defaultAudioStreamIndex,
        subtitleStreamIndex:
            subtitleStreamIndex ?? source.defaultSubtitleStreamIndex,
      );
      method = PlayMethod.transcode;
    } else if (_isStrmSource(source)) {
      uri = _streamUri(
        '${session.serverUrl}/Videos/${item.id}/stream?'
        'MediaSourceId=${Uri.encodeQueryComponent(source.id)}&Static=true',
        audioStreamIndex: audioStreamIndex ?? source.defaultAudioStreamIndex,
        subtitleStreamIndex:
            subtitleStreamIndex ?? source.defaultSubtitleStreamIndex,
      );
      method = PlayMethod.directPlay;
    } else if (source.supportsDirectPlay) {
      uri = _streamUri(
        '${session.serverUrl}/Videos/${item.id}/stream?'
        'MediaSourceId=${Uri.encodeQueryComponent(source.id)}&Static=true',
        audioStreamIndex: audioStreamIndex ?? source.defaultAudioStreamIndex,
        subtitleStreamIndex:
            subtitleStreamIndex ?? source.defaultSubtitleStreamIndex,
      );
      method = PlayMethod.directPlay;
    } else if (source.supportsDirectStream && source.directStreamUrl != null) {
      uri = _streamUri(
        source.directStreamUrl!,
        audioStreamIndex: audioStreamIndex ?? source.defaultAudioStreamIndex,
        subtitleStreamIndex:
            subtitleStreamIndex ?? source.defaultSubtitleStreamIndex,
      );
      method = PlayMethod.directStream;
    } else if (source.supportsTranscoding && source.transcodingUrl != null) {
      uri = _streamUri(
        source.transcodingUrl!,
        audioStreamIndex: audioStreamIndex ?? source.defaultAudioStreamIndex,
        subtitleStreamIndex:
            subtitleStreamIndex ?? source.defaultSubtitleStreamIndex,
      );
      method = PlayMethod.transcode;
    } else {
      throw const EmbyApiException('媒体源没有可用的播放地址');
    }

    final selectedAudio = audioStreamIndex ?? source.defaultAudioStreamIndex;
    final selectedSubtitle =
        subtitleStreamIndex ?? source.defaultSubtitleStreamIndex;
    _logPlaybackDecision(
      source,
      method: method,
      uri: uri,
      maxStreamingBitrate: maxStreamingBitrate,
      audioStreamIndex: selectedAudio,
      subtitleStreamIndex: selectedSubtitle,
      errorCode: info.errorCode,
    );
    return PlaybackPlan(
      uri: uri,
      mediaSourceId: source.id,
      playSessionId: info.playSessionId,
      method: method,
      usesServerAuthentication: _usesServerAuthentication(uri),
      audioStreamIndex: selectedAudio,
      subtitleStreamIndex: selectedSubtitle,
      liveStreamId: source.liveStreamId,
      mediaSourceName: source.name,
      container: source.container,
      bitrate: source.bitrate,
      errorCode: info.errorCode,
      mediaStreams: source.mediaStreams,
      transcodingReasons: source.transcodingReasons,
      availableMediaSources: sources,
    );
  }

  Uri resolveMediaUrl(String rawUrl) => _streamUri(rawUrl);

  Uri trickplayTileUrl({
    required String itemId,
    required int width,
    required int imageIndex,
    String? mediaSourceId,
  }) => Uri.parse(
    '${session.serverUrl}/Videos/$itemId/Trickplay/$width/$imageIndex.jpg',
  ).replace(queryParameters: {'MediaSourceId': ?mediaSourceId});

  Future<PlaybackInfoResult> getPlaybackInfo(
    EmbyItem item, {
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async {
    final commonBody = <String, dynamic>{
      'UserId': session.userId,
      'StartTimeTicks': item.userData.playbackPositionTicks,
      'MaxStreamingBitrate': maxStreamingBitrate,
      'AudioStreamIndex': audioStreamIndex,
      'SubtitleStreamIndex': subtitleStreamIndex,
      'EnableDirectPlay': !forceTranscode,
      'EnableDirectStream': !forceTranscode,
      'EnableTranscoding': true,
      'AllowVideoStreamCopy': true,
      'AllowAudioStreamCopy': true,
      'AutoOpenLiveStream': true,
    }..removeWhere((_, value) => value == null);

    final fullBody = Map<String, dynamic>.from(commonBody)
      ..['DeviceProfile'] = _androidDeviceProfile(maxStreamingBitrate);
    final minimalBody = <String, dynamic>{
      'UserId': session.userId,
      'StartTimeTicks': item.userData.playbackPositionTicks,
      if (forceTranscode) ...{
        'EnableDirectPlay': false,
        'EnableDirectStream': false,
        'EnableTranscoding': true,
      },
    };
    final attempts = [fullBody, commonBody, minimalBody];

    for (var index = 0; index < attempts.length; index++) {
      try {
        final response = await _request(
          () => _dio.post<dynamic>(
            '/Items/${item.id}/PlaybackInfo',
            data: attempts[index],
            queryParameters: {
              'UserId': session.userId,
              'StartTimeTicks': item.userData.playbackPositionTicks,
            },
          ),
        );
        return PlaybackInfoResult.fromJson(_map(response.data));
      } on EmbyApiException catch (error) {
        final hasFallback = index < attempts.length - 1;
        if (!hasFallback || !error.allowsPlaybackInfoFallback) rethrow;
        DiagnosticLog.instance.warning(
          'playback',
          'PlaybackInfo attempt ${index + 1} failed with '
              'HTTP ${error.statusCode}; trying compatibility payload '
              '${index + 2}',
        );
      }
    }
    throw const EmbyApiException('服务器没有返回播放信息');
  }

  Future<void> reportPlaybackStart(
    EmbyItem item,
    PlaybackPlan plan, {
    Duration position = Duration.zero,
  }) => _report('/Sessions/Playing', item, plan, position, false);

  Future<void> reportPlaybackProgress(
    EmbyItem item,
    PlaybackPlan plan, {
    required Duration position,
    required bool isPaused,
  }) => _report('/Sessions/Playing/Progress', item, plan, position, isPaused);

  Future<void> reportPlaybackStopped(
    EmbyItem item,
    PlaybackPlan plan, {
    required Duration position,
  }) => _report('/Sessions/Playing/Stopped', item, plan, position, true);

  Future<void> reportOfflineProgress({
    required String itemId,
    required String mediaSourceId,
    required int positionTicks,
  }) async {
    await _request(
      () => _dio.post<dynamic>(
        '/Sessions/Playing/Stopped',
        data: {
          'ItemId': itemId,
          'MediaSourceId': mediaSourceId,
          'PlayMethod': PlayMethod.directPlay.serverValue,
          'PositionTicks': positionTicks,
          'IsPaused': true,
          'IsMuted': false,
          'CanSeek': true,
        },
      ),
    );
  }

  Future<void> _report(
    String path,
    EmbyItem item,
    PlaybackPlan plan,
    Duration position,
    bool isPaused,
  ) async {
    await _request(
      () => _dio.post<dynamic>(
        path,
        data: {
          'ItemId': item.id,
          'MediaSourceId': plan.mediaSourceId,
          if (plan.playSessionId != null) 'PlaySessionId': plan.playSessionId,
          'PlayMethod': plan.method.serverValue,
          'PositionTicks': position.inMicroseconds * 10,
          'IsPaused': isPaused,
          'IsMuted': false,
          'CanSeek': true,
          if (plan.audioStreamIndex != null)
            'AudioStreamIndex': plan.audioStreamIndex,
          if (plan.subtitleStreamIndex != null)
            'SubtitleStreamIndex': plan.subtitleStreamIndex,
        },
      ),
    );
  }

  Future<void> stopActiveEncoding(PlaybackPlan plan) async {
    final playSessionId = plan.playSessionId;
    if (plan.method != PlayMethod.transcode ||
        playSessionId == null ||
        playSessionId.isEmpty) {
      return;
    }
    await _request(
      () => _dio.delete<dynamic>(
        '/Videos/ActiveEncodings',
        queryParameters: {
          'deviceId': session.deviceId,
          'playSessionId': playSessionId,
        },
      ),
    );
  }

  Future<void> closeLiveStream(PlaybackPlan plan) async {
    final liveStreamId = plan.liveStreamId;
    if (liveStreamId == null || liveStreamId.isEmpty) return;
    await _request(
      () => _dio.post<dynamic>(
        '/LiveStreams/Close',
        queryParameters: {'LiveStreamId': liveStreamId},
      ),
    );
  }

  Future<List<EmbyItem>> _getItemPage(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final response = await _request(
      () => _dio.get<dynamic>(path, queryParameters: query),
    );
    final data = response.data;
    final rawItems = data is List
        ? data
        : (_map(data)['Items'] as List<dynamic>? ?? const []);
    return rawItems
        .whereType<Map>()
        .map((e) => EmbyItem.fromJson(Map<String, dynamic>.from(e)))
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<Response<dynamic>> _request(
    Future<Response<dynamic>> Function() action,
  ) async {
    try {
      return await action();
    } on DioException catch (error) {
      DiagnosticLog.instance.error(
        'network',
        '${error.requestOptions.method} ${error.requestOptions.uri} '
            'failed with HTTP ${error.response?.statusCode ?? 'none'}',
        error: error.message,
      );
      final friendly = _friendlyError(error);
      if (friendly.isAuthenticationFailure && _onSessionExpired != null) {
        unawaited(Future<void>.sync(_onSessionExpired));
      }
      throw friendly;
    }
  }

  PlaybackMediaSource _bestSource(
    List<PlaybackMediaSource> sources, {
    bool forceTranscode = false,
  }) {
    if (forceTranscode) {
      for (final source in sources) {
        if (source.supportsTranscoding && source.transcodingUrl != null) {
          return source;
        }
      }
      return sources.first;
    }
    for (final source in sources) {
      if (source.supportsDirectPlay) return source;
    }
    for (final source in sources) {
      if (source.supportsDirectStream && source.directStreamUrl != null) {
        return source;
      }
    }
    for (final source in sources) {
      if (_isStrmSource(source)) return source;
    }
    for (final source in sources) {
      if (source.supportsTranscoding && source.transcodingUrl != null) {
        return source;
      }
    }
    return sources.first;
  }

  bool _isStrmSource(PlaybackMediaSource source) =>
      source.container?.toLowerCase() == 'strm';

  bool _usesServerAuthentication(Uri uri) {
    if (!uri.hasAuthority) return false;
    final server = Uri.parse(session.serverUrl);
    return uri.scheme.toLowerCase() == server.scheme.toLowerCase() &&
        uri.host.toLowerCase() == server.host.toLowerCase() &&
        uri.port == server.port;
  }

  Uri _streamUri(
    String rawUrl, {
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) {
    late Uri uri;
    if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
      uri = Uri.parse(rawUrl);
    } else {
      final prefix = rawUrl.startsWith('/') ? '' : '/';
      uri = Uri.parse('${session.serverUrl}$prefix$rawUrl');
    }

    final parameters = <String, String>{};
    for (final entry in uri.queryParametersAll.entries) {
      final key = entry.key.toLowerCase();
      if (key == 'api_key' ||
          key == 'x-emby-token' ||
          key == 'audiostreamindex' ||
          key == 'subtitlestreamindex') {
        continue;
      }
      if (entry.value.isNotEmpty) parameters[entry.key] = entry.value.last;
    }
    if (audioStreamIndex != null) {
      parameters['AudioStreamIndex'] = audioStreamIndex.toString();
    }
    if (subtitleStreamIndex != null) {
      parameters['SubtitleStreamIndex'] = subtitleStreamIndex.toString();
    }
    return uri.replace(queryParameters: parameters);
  }

  void _logPlaybackDecision(
    PlaybackMediaSource source, {
    required PlayMethod method,
    required Uri uri,
    required int maxStreamingBitrate,
    required int? audioStreamIndex,
    required int? subtitleStreamIndex,
    required String? errorCode,
  }) {
    Map<String, dynamic>? streamOfType(String type) {
      for (final stream in source.mediaStreams) {
        if (stream['Type']?.toString().toLowerCase() == type) return stream;
      }
      return null;
    }

    final video = streamOfType('video');
    final audio = source.mediaStreams
        .where(
          (stream) =>
              stream['Type']?.toString().toLowerCase() == 'audio' &&
              (audioStreamIndex == null ||
                  stream['Index']?.toString() == audioStreamIndex.toString()),
        )
        .firstOrNull;
    final subtitle = source.mediaStreams
        .where(
          (stream) =>
              stream['Type']?.toString().toLowerCase() == 'subtitle' &&
              (subtitleStreamIndex == null ||
                  stream['Index']?.toString() ==
                      subtitleStreamIndex.toString()),
        )
        .firstOrNull;

    final uriForLog = _usesServerAuthentication(uri)
        ? uri.toString()
        : '${uri.scheme}://${uri.host}'
              '${uri.hasPort ? ':${uri.port}' : ''}/<remote>';
    DiagnosticLog.instance.info(
      'playback',
      'Selected ${method.serverValue} source=${source.id} '
          'container=${source.container ?? 'unknown'} '
          'bitrate=${source.bitrate ?? 'unknown'} maxBitrate=$maxStreamingBitrate '
          'video=${video?['Codec'] ?? 'unknown'}/'
          '${video?['Profile'] ?? 'unknown'}/L${video?['Level'] ?? 'unknown'} '
          '${video?['Width'] ?? '?'}x${video?['Height'] ?? '?'} '
          'hdr=${video?['VideoRangeType'] ?? video?['VideoRange'] ?? 'SDR'} '
          'audio=$audioStreamIndex:${audio?['Codec'] ?? 'unknown'}/'
          '${audio?['Channels'] ?? '?'}ch '
          'subtitle=$subtitleStreamIndex:${subtitle?['Codec'] ?? 'off'} '
          'external=${subtitle?['IsExternal'] ?? false} '
          'errorCode=${errorCode ?? 'none'} '
          'transcodingReasons=${source.transcodingReasons.join('|')} '
          'uri=$uriForLog',
    );
  }

  static Map<String, dynamic> _androidDeviceProfile(
    int maxStreamingBitrate,
  ) => {
    'Name': 'Flutter libmpv',
    'MaxStreamingBitrate': maxStreamingBitrate,
    'MaxStaticBitrate': maxStreamingBitrate,
    'MusicStreamingTranscodingBitrate': 384000,
    'DirectPlayProfiles': [
      {
        'Container': 'mp4,mkv,webm,mov,m4v,ts,mpegts,m2ts',
        'Type': 'Video',
        'VideoCodec': 'h264,hevc,vp8,vp9,av1,mpeg2video,mpeg4',
        'AudioCodec': 'aac,ac3,eac3,mp3,opus,vorbis,flac,alac,dts,pcm_s16le',
      },
      {'Container': 'mp3,aac,m4a,flac,ogg,opus,wav,wma,ape', 'Type': 'Audio'},
    ],
    'TranscodingProfiles': [
      {
        'Container': 'ts',
        'Type': 'Video',
        'VideoCodec': 'h264',
        'AudioCodec': 'aac',
        'Protocol': 'hls',
        'Context': 'Streaming',
        'MaxAudioChannels': '2',
        'MinSegments': 1,
        'BreakOnNonKeyFrames': true,
      },
    ],
    'CodecProfiles': [
      {
        'Type': 'Video',
        'Codec': 'h264',
        'Conditions': [
          {
            'Condition': 'LessThanEqual',
            'Property': 'VideoLevel',
            'Value': '52',
            'IsRequired': false,
          },
          {
            'Condition': 'LessThanEqual',
            'Property': 'Width',
            'Value': '4096',
            'IsRequired': true,
          },
          {
            'Condition': 'LessThanEqual',
            'Property': 'Height',
            'Value': '2160',
            'IsRequired': true,
          },
        ],
      },
      {
        'Type': 'Video',
        'Codec': 'hevc',
        'Conditions': [
          {
            'Condition': 'LessThanEqual',
            'Property': 'VideoLevel',
            'Value': '153',
            'IsRequired': false,
          },
          {
            'Condition': 'LessThanEqual',
            'Property': 'Width',
            'Value': '4096',
            'IsRequired': true,
          },
          {
            'Condition': 'LessThanEqual',
            'Property': 'Height',
            'Value': '2160',
            'IsRequired': true,
          },
        ],
      },
      {
        'Type': 'VideoAudio',
        'Conditions': [
          {
            'Condition': 'LessThanEqual',
            'Property': 'AudioChannels',
            'Value': '8',
            'IsRequired': true,
          },
        ],
      },
    ],
    'SubtitleProfiles': [
      {'Format': 'srt', 'Method': 'External'},
      {'Format': 'ass', 'Method': 'External'},
      {'Format': 'ssa', 'Method': 'External'},
      {'Format': 'vtt', 'Method': 'External'},
      {'Format': 'sub', 'Method': 'Embed'},
      {'Format': 'pgs', 'Method': 'Embed'},
    ],
  };

  static EmbyApiException _friendlyError(
    DioException error, {
    bool duringLogin = false,
  }) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      return EmbyApiException(
        duringLogin ? '用户名或密码错误，或账号没有登录权限' : '登录已失效，请重新登录',
        statusCode: status,
      );
    }
    if (status != null) {
      final serverMessage = _serverErrorMessage(error.response?.data);
      return EmbyApiException(
        serverMessage ?? '服务器请求失败（HTTP $status）',
        statusCode: status,
      );
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => const EmbyApiException(
        '连接服务器超时，请检查地址和网络',
      ),
      DioExceptionType.badCertificate => const EmbyApiException(
        '服务器 HTTPS 证书无效',
      ),
      _ => const EmbyApiException('无法连接 Emby 服务器，请检查地址和网络'),
    };
  }

  static String? _serverErrorMessage(dynamic data) {
    if (data is Map) {
      final message = data['Message'] ?? data['message'] ?? data['Error'];
      if (message != null && message.toString().isNotEmpty) {
        return message.toString();
      }
    }
    if (data is String && data.isNotEmpty && data.length < 160) return data;
    return null;
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }
}
