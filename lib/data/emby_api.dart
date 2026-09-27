import '../core/strm_diagnostics.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/diagnostic_log.dart';
import '../core/server_scope.dart';
import '../images/emby_image_request.dart';
import '../library/library_alphabet_filter.dart';
import '../library/library_browse_state.dart' as browse;
import '../library/library_content_profile.dart';
import '../models/emby_models.dart';
import '../playback/cache/playback_cache_policy.dart';
import '../playback/strm_direct_play_policy.dart';
import '../playback/playback_resource_request.dart';
import '../realtime/emby_websocket_client.dart';
import 'emby_session_service.dart';
import 'emby_user_data_service.dart';

bool isLocalNetworkAddress(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return false;
  if (!value.contains('://')) value = 'http://$value';
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return false;

  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == 'localhost.') return true;
  final address = InternetAddress.tryParse(host.split('%').first);
  if (address == null) return false;

  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 127 ||
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  final isLoopback =
      bytes.take(15).every((value) => value == 0) && bytes.last == 1;
  final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
  return isLoopback || isLinkLocal || isUniqueLocal;
}

class EmbyApiException implements Exception {
  const EmbyApiException(
    this.message, {
    this.statusCode,
    this.serverUrl,
    this.isConnectionFailure = false,
  });

  final String message;
  final int? statusCode;
  final String? serverUrl;
  final bool isConnectionFailure;

  bool get isAuthenticationFailure => statusCode == 401 || statusCode == 403;

  bool get isLocalNetworkConnectionFailure =>
      isConnectionFailure &&
      serverUrl != null &&
      isLocalNetworkAddress(serverUrl!);

  bool get allowsPlaybackInfoFallback =>
      statusCode == 400 || statusCode == 422 || statusCode == 500;

  @override
  String toString() => message;
}

class EmbyApi {
  EmbyApi(
    this.session, {
    Dio? dio,
    String deviceName = 'Android',
    FutureOr<void> Function()? onSessionExpired,
    FutureOr<void> Function()? onRemoteCapabilitiesReported,
    FutureOr<void> Function()? onRealtimeConnected,
    EmbySocketConnector? realtimeConnector,
  }) : _deviceName = deviceName,
       _dio = dio ?? _createDio(session, deviceName),
       _onSessionExpired = onSessionExpired,
       _onRemoteCapabilitiesReported = onRemoteCapabilitiesReported,
       _onRealtimeConnected = onRealtimeConnected {
    if (dio != null) {
      _configureDio(dio, session, deviceName);
    }
    userData = EmbyUserDataService(
      session: session,
      dio: _dio,
      execute: _request,
    );
    sessionControl = EmbySessionService(dio: _dio, execute: _request);
    realtime = EmbyWebSocketClient(
      session,
      connector: realtimeConnector,
      onConnected: _handleRealtimeConnected,
    );
  }

  static const clientName = 'Emby Flutter Client';
  static const clientVersion = '1.0.0';
  static const _listItemFields =
      'PrimaryImageAspectRatio,DateCreated,OfficialRating,CommunityRating,'
      'RunTimeTicks,ProductionYear,ParentId,Path,Container,Tags';
  static const _detailItemFields =
      'Overview,Genres,Tags,People,MediaSources,MediaStreams,'
      'PrimaryImageAspectRatio,'
      'DateCreated,OfficialRating,CommunityRating,RunTimeTicks,'
      'ProductionYear,ProviderIds,ParentId,Path,Container,Chapters,Trickplay';

  final EmbySession session;
  final String _deviceName;
  final Dio _dio;
  final FutureOr<void> Function()? _onSessionExpired;
  final FutureOr<void> Function()? _onRemoteCapabilitiesReported;
  final FutureOr<void> Function()? _onRealtimeConnected;
  bool _imageAuthenticationFailureReported = false;
  bool _disposed = false;
  bool get isSessionActive => !_disposed;
  late final EmbyUserDataService userData;
  late final EmbySessionService sessionControl;
  late final EmbyWebSocketClient realtime;

  Map<String, String> get playbackHeaders => {
    'X-Emby-Token': session.accessToken,
    'X-Emby-Authorization': _authorizationHeader(
      session.deviceId,
      deviceName: _deviceName,
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
      if (!_disposed &&
          friendly.isAuthenticationFailure &&
          _onSessionExpired != null) {
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
    String deviceName = 'Android',
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
          'X-Emby-Authorization': _authorizationHeader(
            deviceId,
            deviceName: deviceName,
          ),
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
      throw _friendlyError(error, duringLogin: true, serverUrl: normalized);
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

  static Dio _createDio(EmbySession session, String deviceName) => Dio(
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
          deviceName: deviceName,
          token: session.accessToken,
        ),
      },
    ),
  );

  static void _configureDio(Dio dio, EmbySession session, String deviceName) {
    if (dio.options.baseUrl.isEmpty) {
      dio.options.baseUrl = session.serverUrl;
    }
    dio.options.headers.addAll({
      'Accept': 'application/json',
      'X-Emby-Token': session.accessToken,
      'X-Emby-Authorization': _authorizationHeader(
        session.deviceId,
        deviceName: deviceName,
        token: session.accessToken,
      ),
    });
  }

  static String _authorizationHeader(
    String deviceId, {
    required String deviceName,
    String? token,
  }) {
    final safeId = deviceId.replaceAll('"', '');
    final safeDeviceName = deviceName.replaceAll('"', '');
    return 'MediaBrowser Client="$clientName", Device="$safeDeviceName", '
        'DeviceId="$safeId", Version="$clientVersion"'
        '${token == null ? '' : ', Token="$token"'}';
  }

  Future<void> logout() async {
    await _request(() => _dio.post<dynamic>('/Sessions/Logout'));
  }

  Future<void> _reportRemoteCapabilities() async {
    await sessionControl.reportCapabilities();
    if (_disposed) return;
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
    if (_disposed) return;
    _disposed = true;
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
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'home',
        'Skipped latest shelf profile=${LibraryContentProfile.fromCollectionType(library.collectionType).kind.name}',
        error: error,
        stackTrace: stackTrace,
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
          'IncludeItemTypes': 'Movie,Series,Episode,Video,Photo',
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'GroupItems': true,
        },
      );

  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
    int startIndex = 0,
    int limit = 60,
    browse.LibraryMediaType mediaType = browse.LibraryMediaType.all,
    browse.LibraryPlayedFilter playedFilter = browse.LibraryPlayedFilter.all,
    bool favorites = false,
    browse.LibrarySortBy sortBy = browse.LibrarySortBy.name,
    browse.LibrarySortOrder sortOrder = browse.LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) async {
    if (genreId != null && tagId != null) {
      throw ArgumentError('genreId and tagId cannot both be set.');
    }
    final filters = <String>[
      if (favorites) 'IsFavorite',
      if (playedFilter.apiValue != null) playedFilter.apiValue!,
    ];
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': true,
          'IncludeItemTypes': profile.includeItemTypesFor(mediaType),
          'SortBy': sortBy.apiValue,
          'SortOrder': sortOrder.apiValue,
          if (filters.isNotEmpty) 'Filters': filters.join(','),
          'GenreIds': ?genreId,
          'TagIds': ?tagId,
          'NameStartsWith': ?alphabetFilter.nameStartsWith,
          'NameLessThan': ?alphabetFilter.nameLessThan,
          'Fields': '$_listItemFields,MediaSources',
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    return _parseLibraryPage(response.data);
  }

  Future<EmbyItemPage> getLocalMediaScanCandidates({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    browse.LibraryMediaType mediaType = browse.LibraryMediaType.all,
    browse.LibraryPlayedFilter playedFilter = browse.LibraryPlayedFilter.all,
    bool favorites = false,
    browse.LibrarySortBy sortBy = browse.LibrarySortBy.name,
    browse.LibrarySortOrder sortOrder = browse.LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) async {
    if (genreId != null && tagId != null) {
      throw ArgumentError('genreId and tagId cannot both be set.');
    }
    final includeItemTypes = switch (mediaType) {
      browse.LibraryMediaType.all => 'Movie,Episode,Video',
      browse.LibraryMediaType.movie => 'Movie',
      browse.LibraryMediaType.video => 'Video',
      browse.LibraryMediaType.series ||
      browse.LibraryMediaType.photo => throw ArgumentError.value(
        mediaType,
        'mediaType',
        'Media type does not expose source-bearing scan candidates',
      ),
    };
    final filters = <String>[
      if (favorites) 'IsFavorite',
      if (playedFilter.apiValue != null) playedFilter.apiValue!,
    ];
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': true,
          'IncludeItemTypes': includeItemTypes,
          'SortBy': sortBy.apiValue,
          'SortOrder': sortOrder.apiValue,
          if (filters.isNotEmpty) 'Filters': filters.join(','),
          'GenreIds': ?genreId,
          'TagIds': ?tagId,
          'NameStartsWith': ?alphabetFilter.nameStartsWith,
          'NameLessThan': ?alphabetFilter.nameLessThan,
          'Fields': '$_listItemFields,MediaSources',
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    return _parseLibraryPage(response.data);
  }

  Future<EmbyItemPage> getDirectoryChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    browse.LibrarySortBy sortBy = browse.LibrarySortBy.name,
    browse.LibrarySortOrder sortOrder = browse.LibrarySortOrder.ascending,
  }) async {
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': false,
          'IncludeItemTypes':
              'Folder,CollectionFolder,PhotoAlbum,Movie,Series,Episode,Video,Photo',
          'SortBy': sortBy.apiValue,
          'SortOrder': sortOrder.apiValue,
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    return _parseLibraryPage(response.data);
  }

  Future<EmbyItemPage> getLibraryFolders({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
  }) async {
    final items = await _getItemPage(
      '/Users/${session.userId}/Items',
      query: {
        'ParentId': parentId,
        'StartIndex': startIndex,
        'Limit': limit,
        'Recursive': false,
        'IncludeItemTypes': 'Folder',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'Fields': _listItemFields,
        'EnableUserData': true,
        'EnableImages': true,
      },
    );
    return EmbyItemPage(items: items);
  }

  Future<EmbyItemPage> getLibraryGenres({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
    int startIndex = 0,
    int limit = 60,
  }) => _getLibraryTerms(
    path: '/Genres',
    parentId: parentId,
    startIndex: startIndex,
    limit: limit,
    profile: profile,
  );

  Future<EmbyItemPage> getLibraryTags({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
    int startIndex = 0,
    int limit = 60,
  }) => _getLibraryTerms(
    path: '/Tags',
    parentId: parentId,
    startIndex: startIndex,
    limit: limit,
    profile: profile,
  );

  Future<EmbyItemPage> _getLibraryTerms({
    required String path,
    required String parentId,
    required int startIndex,
    required int limit,
    required LibraryContentProfile profile,
  }) async {
    final response = await _request(
      () => _dio.get<dynamic>(
        path,
        queryParameters: {
          'UserId': session.userId,
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': true,
          'IncludeItemTypes': profile.includeItemTypesFor(
            browse.LibraryMediaType.all,
          ),
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'Fields': _listItemFields,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    final data = _map(response.data);
    final rawItems = response.data is List
        ? response.data as List<dynamic>
        : data['Items'] as List<dynamic>? ?? const [];
    final items = rawItems
        .whereType<Map>()
        .map((item) => EmbyItem.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
    final rawTotal = data['TotalRecordCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return EmbyItemPage(
      items: items,
      totalRecordCount: total,
      rawItemCount: rawItems.length,
    );
  }

  EmbyItemPage _parseLibraryPage(dynamic responseData) {
    final data = _map(responseData);
    final rawItems = responseData is List
        ? responseData
        : data['Items'] as List<dynamic>? ?? const [];
    final items = rawItems
        .whereType<Map>()
        .map((item) => EmbyItem.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
    final rawTotal = data['TotalRecordCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return EmbyItemPage(
      items: items,
      totalRecordCount: total,
      rawItemCount: rawItems.length,
    );
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
    return EmbyItemPage(
      items: items,
      totalRecordCount: total,
      rawItemCount: rawItems.length,
    );
  }

  Future<EmbyItemPage> getPhotoItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    bool recursive = false,
    bool favorites = false,
    browse.LibrarySortBy sortBy = browse.LibrarySortBy.name,
    browse.LibrarySortOrder sortOrder = browse.LibrarySortOrder.ascending,
    String? genreId,
    String? tagId,
  }) async {
    if (genreId != null && tagId != null) {
      throw ArgumentError('genreId and tagId cannot both be set.');
    }
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': recursive,
          'IncludeItemTypes': 'Photo',
          'SortBy': sortBy.apiValue,
          'SortOrder': sortOrder.apiValue,
          if (favorites) 'Filters': 'IsFavorite',
          'GenreIds': ?genreId,
          'TagIds': ?tagId,
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    return _parseLibraryPage(response.data);
  }

  Future<EmbyItemPage> getPhotoChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
  }) async {
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'ParentId': parentId,
          'StartIndex': startIndex,
          'Limit': limit,
          'Recursive': false,
          'IncludeItemTypes': 'Photo,PhotoAlbum,Folder',
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'Fields': _listItemFields,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    return _parseLibraryPage(response.data);
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

  Future<EmbyItemPage> getPersonItems({
    required String personId,
    int startIndex = 0,
    int limit = 60,
    PersonMediaFilter filter = PersonMediaFilter.all,
  }) async {
    final normalizedPersonId = personId.trim();
    if (normalizedPersonId.isEmpty) {
      throw ArgumentError.value(personId, 'personId', '人物 ID 不能为空');
    }
    final response = await _request(
      () => _dio.get<dynamic>(
        '/Users/${session.userId}/Items',
        queryParameters: {
          'PersonIds': normalizedPersonId,
          'IncludeItemTypes': filter.apiValue,
          'Recursive': true,
          'SortBy': 'PremiereDate',
          'SortOrder': 'Descending',
          'StartIndex': startIndex,
          'Limit': limit,
          'Fields': _listItemFields,
          'EnableUserData': true,
          'EnableImages': true,
          'EnableTotalRecordCount': true,
        },
      ),
    );
    final data = _map(response.data);
    final rawItems = data['Items'] as List<dynamic>? ?? const [];
    final seen = <String>{};
    final items = rawItems
        .whereType<Map>()
        .map((item) => EmbyItem.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty && seen.add(item.id))
        .toList(growable: false);
    final rawTotal = data['TotalRecordCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return EmbyItemPage(
      items: items,
      totalRecordCount: total,
      rawItemCount: rawItems.length,
    );
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

  EmbyImageRequest? imageRequest(
    EmbyItem item, {
    String type = 'Primary',
    int maxWidth = 600,
    int? maxHeight,
    int quality = 90,
  }) {
    final tag = type == 'Backdrop'
        ? item.backdropImageTags.firstOrNull
        : item.imageTags[type];
    return imageRequestForTag(
      itemId: item.id,
      type: type,
      tag: tag,
      maxWidth: maxWidth,
      maxHeight:
          maxHeight ??
          _defaultImageHeight(item, type: type, maxWidth: maxWidth),
      quality: quality,
    );
  }

  EmbyImageRequest? imageRequestForTag({
    required String itemId,
    required String type,
    required String? tag,
    required int maxWidth,
    int? maxHeight,
    int quality = 90,
  }) {
    if (itemId.isEmpty || tag == null || tag.isEmpty) return null;
    final width = EmbyImageRequest.bucketWidth(maxWidth);
    final height = EmbyImageRequest.bucketWidth(maxHeight ?? maxWidth * 2);
    final scope = ServerScope.fromSession(session);
    final uri =
        Uri.parse(
          '${session.serverUrl}/Items/${Uri.encodeComponent(itemId)}'
          '/Images/${Uri.encodeComponent(type)}',
        ).replace(
          queryParameters: {
            'tag': tag,
            'maxWidth': width.toString(),
            'maxHeight': height.toString(),
            'quality': quality.toString(),
          },
        );
    return EmbyImageRequest(
      uri: uri,
      headers: Map.unmodifiable(playbackHeaders),
      cacheKey:
          'emby-image-v2:${scope.cacheNamespace}:$itemId:'
          '${type.toLowerCase()}:$tag:w$width:h$height:q$quality',
      decodeWidth: width,
      decodeHeight: height,
      errorListener: _handleImageError,
    );
  }

  int _defaultImageHeight(
    EmbyItem item, {
    required String type,
    required int maxWidth,
  }) {
    if (type == 'Backdrop') return maxWidth;
    final aspectRatio = item.primaryImageAspectRatio;
    if (aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0) {
      return (maxWidth / aspectRatio).ceil();
    }
    return maxWidth * 2;
  }

  void _handleImageError(Object error) {
    if (_disposed ||
        error is! HttpExceptionWithStatus ||
        (error.statusCode != 401 && error.statusCode != 403) ||
        _imageAuthenticationFailureReported) {
      return;
    }
    _imageAuthenticationFailureReported = true;
    final callback = _onSessionExpired;
    if (callback != null) unawaited(Future<void>.sync(callback));
  }

  /// Online entry point: classification and the fixed source precede every
  /// compatibility request. Unknown is never permission for server streaming.
  Future<PlaybackPlan> resolveOnlinePlayback(
    EmbyItem item, {
    required Object itemSession,
    required int generation,
    required CancelToken cancelToken,
    required bool Function() isCurrent,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
    bool knownStrm = false,
    StrmTrace? trace,
  }) async {
    trace ??= StrmTrace();
    final diagnosticTrace = trace;
    final clock = Stopwatch()..start();
    final timer = Timer(
      const Duration(seconds: 30),
      () => cancelToken.cancel('resolve_budget'),
    );
    void check() {
      if (_disposed || cancelToken.isCancelled || !isCurrent()) {
        throw const PlaybackResolveException(PlaybackResolveFailure.cancelled);
      }
    }

    Duration remaining() {
      check();
      final value = const Duration(seconds: 30) - clock.elapsed;
      if (value <= Duration.zero) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.budgetExceeded,
        );
      }
      return value;
    }

    EmbyItem? detail;
    Future<EmbyItem> fresh() async {
      if (detail != null) return detail!;
      final requestNumber = diagnosticTrace.nextRequest();
      final watch = Stopwatch()..start();
      diagnosticTrace.emit('strm_resolve', {
        'request': requestNumber,
        'group': 'detail',
        'outcome': 'started',
      });
      final response = await _request(
        () => _dio.get<dynamic>(
          '/Users/${session.userId}/Items/${Uri.encodeComponent(item.id)}',
          queryParameters: {'Fields': _detailItemFields},
          cancelToken: cancelToken,
          options: Options(
            sendTimeout: remaining(),
            receiveTimeout: remaining(),
          ),
        ),
      );
      check();
      diagnosticTrace.emit('strm_resolve', {
        'request': requestNumber,
        'group': 'detail',
        'outcome': 'succeeded',
        'http': response.statusCode,
        'elapsedMs': watch.elapsedMilliseconds,
      });
      detail = EmbyItem.fromJson(_map(response.data));
      if (detail!.id != item.id) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.sourceIdentityConflict,
        );
      }
      return detail!;
    }

    String? selectedId = mediaSourceId;
    PlaybackMediaSource? selected;
    PlaybackInfoResult? strictInfo;
    Future<PlaybackInfoResult> strict() async {
      if (strictInfo != null) return strictInfo!;
      final payloads = StrmDirectPlayPolicy.strictPayloads(
        userId: session.userId,
        deviceProfile: _androidDeviceProfile(maxStreamingBitrate),
        mediaSourceId: selectedId,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
        subtitleDisabled: subtitleDisabled,
        startTimeTicks: item.userData.playbackPositionTicks,
      );
      for (var attempt = 0; attempt < payloads.length; attempt++) {
        final requestNumber = diagnosticTrace.nextRequest();
        final watch = Stopwatch()..start();
        void event(String outcome, int? status) =>
            diagnosticTrace.emit('strm_resolve', {
              'request': requestNumber,
              'group': 'strict',
              'attempt': attempt + 1,
              'strict': true,
              'fixedSource': selectedId != null,
              'outcome': outcome,
              'http': status,
              'elapsedMs': watch.elapsedMilliseconds,
            });
        event('started', null);
        try {
          final response = await _request(
            () => _dio.post<dynamic>(
              '/Items/${Uri.encodeComponent(item.id)}/PlaybackInfo',
              data: payloads[attempt],
              cancelToken: cancelToken,
              options: Options(
                sendTimeout: remaining(),
                receiveTimeout: remaining(),
              ),
            ),
          );
          event('succeeded', response.statusCode);
          check();
          return strictInfo = PlaybackInfoResult.fromJson(_map(response.data));
        } on EmbyApiException catch (error) {
          event('failed', error.statusCode);
          check();
          if (attempt == payloads.length - 1 ||
              !error.allowsPlaybackInfoFallback) {
            rethrow;
          }
        }
      }
      throw const PlaybackResolveException(PlaybackResolveFailure.serverError);
    }

    try {
      check();
      if (item.mediaSources.isNotEmpty) {
        selected = StrmDirectPlayPolicy.selectOnce(
          item.mediaSources,
          requestedId: selectedId,
        );
        selectedId = selected.id;
      }
      var classification = knownStrm
          ? SourceClassification.confirmedStrm
          : selected == null
          ? SourceClassification.unknown
          : StrmDirectPlayPolicy.classify(selected);
      if (classification == SourceClassification.confirmedStrm) {
        StrmDirectPlayPolicy.requireDirectRequest(
          forceTranscode: forceTranscode,
        );
      } else {
        final value = await fresh();
        if (value.mediaSources.isNotEmpty) {
          selected = StrmDirectPlayPolicy.selectOnce(
            value.mediaSources,
            requestedId: selectedId,
          );
          selectedId = selected.id;
          classification = StrmDirectPlayPolicy.classify(
            selected,
            freshDetail: value,
          );
        } else if (selectedId != null) {
          throw const PlaybackResolveException(
            PlaybackResolveFailure.sourceMissing,
          );
        }
      }
      if (selected == null) {
        final identification = await strict();
        StrmDirectPlayPolicy.checkError(identification.errorCode);
        selected = StrmDirectPlayPolicy.selectOnce(
          identification.mediaSources,
          requestedId: selectedId,
        );
        selectedId = selected.id;
        classification = StrmDirectPlayPolicy.classify(selected);
      }
      diagnosticTrace.emit('strm_resolve', {
        'classification': switch (classification) {
          SourceClassification.confirmedStrm => 'strm',
          SourceClassification.confirmedRegular => 'regular',
          _ => 'unknown',
        },
        'fixedSource': selectedId != null,
        'conflict': false,
      });
      if (classification == SourceClassification.unknown) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.sourceIdentityUnresolved,
        );
      }
      if (classification == SourceClassification.confirmedRegular) {
        final info = await getPlaybackInfo(
          item,
          mediaSourceId: selectedId,
          audioStreamIndex: audioStreamIndex,
          subtitleStreamIndex: subtitleStreamIndex,
          subtitleDisabled: subtitleDisabled,
          maxStreamingBitrate: maxStreamingBitrate,
          forceTranscode: forceTranscode,
          cancelToken: cancelToken,
          timeout: remaining(),
          trace: diagnosticTrace,
        );
        check();
        StrmDirectPlayPolicy.checkError(info.errorCode);
        selected = StrmDirectPlayPolicy.fixedSource(
          info.mediaSources,
          selectedId!,
        );
        if (!StrmDirectPlayPolicy.hasStrmEvidence(selected)) {
          return getPlaybackPlan(
            item,
            mediaSourceId: selectedId,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            subtitleDisabled: subtitleDisabled,
            maxStreamingBitrate: maxStreamingBitrate,
            forceTranscode: forceTranscode,
            authorizedInfo: info,
          );
        }
        // The fixed source changed evidence; no server video is opened.
        classification = SourceClassification.confirmedStrm;
      }
      StrmDirectPlayPolicy.requireDirectRequest(forceTranscode: forceTranscode);
      final info = await strict();
      StrmDirectPlayPolicy.checkError(info.errorCode);
      selected = StrmDirectPlayPolicy.fixedSource(
        info.mediaSources,
        selectedId!,
      );
      StrmDirectPlayPolicy.requireNoServerResource(selected);
      if (selected.path == null ||
          !selected.path!.startsWith(RegExp(r'https?://'))) {
        selected = StrmDirectPlayPolicy.fixedSource(
          (await fresh()).mediaSources,
          selectedId,
        );
      }
      check();
      final snapshot = SelectedSourceSnapshot(
        trace: diagnosticTrace,
        isSessionActive: () => !_disposed,
        source: selected,
        identity: PlaybackResourceIdentity(
          scope: ServerScope.fromSession(session),
          apiSession: this,
          itemId: item.id,
          sourceId: selectedId,
          itemSession: itemSession,
          generation: generation,
        ),
        embyServer: Uri.parse(session.serverUrl),
        playSessionId: info.playSessionId,
      );
      return PlaybackPlan(
        uri: Uri.parse('embyinput://pending'),
        mediaSourceId: selectedId,
        playSessionId: snapshot.playSessionId,
        method: PlayMethod.directPlay,
        usesServerAuthentication: false,
        sourceRequest: snapshot.request,
        mediaStreams: snapshot.mediaStreams,
        transcodingReasons: const [],
        availableMediaSources: info.mediaSources,
        audioStreamIndex: audioStreamIndex ?? selected.defaultAudioStreamIndex,
        subtitleStreamIndex: subtitleDisabled
            ? null
            : subtitleStreamIndex ?? selected.defaultSubtitleStreamIndex,
        subtitleDisabled: subtitleDisabled,
        container: selected.container,
        duration: snapshot.duration,
        sourceSizeBytes: snapshot.sizeBytes,
        sourceProtocol: 'Http',
        transportKind: PlaybackTransportKind.unknown,
      );
    } finally {
      timer.cancel();
      clock.stop();
    }
  }

  /// Low-level snapshot entry for an already classified source. Online
  /// Bootstrap uses resolveOnlinePlayback to own classification and budgets.
  /// Snapshots must be opened through the controlled custom input adapter.
  Future<SelectedSourceSnapshot> getSourceDirectSnapshot(
    EmbyItem item, {
    required PlaybackResourceIdentity identity,
    required CancelToken cancelToken,
    required bool Function() isCurrent,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    bool forceTranscode = false,
  }) async {
    StrmDirectPlayPolicy.requireDirectRequest(forceTranscode: forceTranscode);
    if (!identical(identity.apiSession, this) ||
        identity.scope != ServerScope.fromSession(session) ||
        identity.itemId != item.id ||
        identity.sourceId.isEmpty) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceIdentityConflict,
      );
    }
    final requestCancellation = CancelToken();
    var expired = false;
    var finished = false;
    final clock = Stopwatch()..start();
    final timer = Timer(const Duration(seconds: 30), () {
      expired = true;
      requestCancellation.cancel('resolve_budget');
    });
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!finished) requestCancellation.cancel('resolve_cancelled');
      }),
    );
    void checkCurrent() {
      if (expired) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.budgetExceeded,
        );
      }
      if (_disposed || cancelToken.isCancelled || !isCurrent()) {
        requestCancellation.cancel('resolve_cancelled');
        throw const PlaybackResolveException(PlaybackResolveFailure.cancelled);
      }
    }

    Options options() {
      checkCurrent();
      final remaining = const Duration(seconds: 30) - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.budgetExceeded,
        );
      }
      return Options(sendTimeout: remaining, receiveTimeout: remaining);
    }

    EmbyItem? detail;
    Future<EmbyItem> readDetail() async {
      if (detail != null) return detail!;
      checkCurrent();
      final response = await _dio.get<dynamic>(
        '/Users/${session.userId}/Items/${Uri.encodeComponent(item.id)}',
        queryParameters: {'Fields': _detailItemFields},
        cancelToken: requestCancellation,
        options: options(),
      );
      checkCurrent();
      final value = EmbyItem.fromJson(_map(response.data));
      if (value.id != item.id) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.sourceIdentityConflict,
        );
      }
      return detail = value;
    }

    try {
      checkCurrent();
      var classification = SourceClassification.unknown;
      if (item.mediaSources.isNotEmpty) {
        final source = StrmDirectPlayPolicy.fixedSource(
          item.mediaSources,
          identity.sourceId,
        );
        classification = StrmDirectPlayPolicy.classify(source);
        if (item.mediaSources.length == 1 &&
            item.path?.toLowerCase().endsWith('.strm') == true) {
          classification = SourceClassification.confirmedStrm;
        }
      }
      if (classification != SourceClassification.confirmedStrm) {
        final fresh = await readDetail();
        final source = StrmDirectPlayPolicy.fixedSource(
          fresh.mediaSources,
          identity.sourceId,
        );
        classification = StrmDirectPlayPolicy.classify(
          source,
          freshDetail: fresh,
        );
      }
      if (classification != SourceClassification.confirmedStrm) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.sourceIdentityUnresolved,
        );
      }
      final bodies = StrmDirectPlayPolicy.strictPayloads(
        userId: session.userId,
        mediaSourceId: identity.sourceId,
        deviceProfile: _androidDeviceProfile(120000000),
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
        subtitleDisabled: subtitleDisabled,
        startTimeTicks: item.userData.playbackPositionTicks,
      );
      for (var index = 0; index < bodies.length; index++) {
        checkCurrent();
        late final Response<dynamic> response;
        try {
          response = await _dio.post<dynamic>(
            '/Items/${Uri.encodeComponent(item.id)}/PlaybackInfo',
            data: bodies[index],
            cancelToken: requestCancellation,
            options: options(),
          );
        } on DioException catch (error) {
          checkCurrent();
          if (index < bodies.length - 1 &&
              const [400, 422, 500].contains(error.response?.statusCode)) {
            continue;
          }
          rethrow;
        }
        checkCurrent();
        final info = PlaybackInfoResult.fromJson(_map(response.data));
        StrmDirectPlayPolicy.checkError(info.errorCode);
        var source = StrmDirectPlayPolicy.fixedSource(
          info.mediaSources,
          identity.sourceId,
        );
        StrmDirectPlayPolicy.requireNoServerResource(source);
        // Only a whole same-source detail snapshot may fill an absent URL.
        // Never graft old RequiredHttpHeaders onto the replacement Path.
        if (source.path == null ||
            !source.path!.startsWith(RegExp(r'https?://'))) {
          final fresh = await readDetail();
          source = StrmDirectPlayPolicy.fixedSource(
            fresh.mediaSources,
            identity.sourceId,
          );
        }
        checkCurrent();
        return SelectedSourceSnapshot(
          source: source,
          identity: identity,
          embyServer: Uri.parse(session.serverUrl),
          playSessionId: info.playSessionId,
        );
      }
      throw const PlaybackResolveException(PlaybackResolveFailure.serverError);
    } on DioException catch (error) {
      checkCurrent();
      final status = error.response?.statusCode;
      if ((status == 401 || status == 403) &&
          !_disposed &&
          _onSessionExpired != null) {
        unawaited(Future<void>.sync(_onSessionExpired));
      }
      throw PlaybackResolveException(switch (status) {
        401 || 403 => PlaybackResolveFailure.serverDenied,
        429 => PlaybackResolveFailure.rateLimited,
        _ => PlaybackResolveFailure.serverError,
      });
    } finally {
      finished = true;
      timer.cancel();
      clock.stop();
    }
  }

  Future<PlaybackPlan> getPlaybackPlan(
    EmbyItem item, {
    int? mediaSourceIndex,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
    PlaybackInfoResult? authorizedInfo,
  }) async {
    DiagnosticLog.instance.info(
      'playback',
      'event=playback_plan_requested '
          'hasResume=${item.userData.playbackPositionTicks > 0} '
          'forceTranscode=$forceTranscode',
    );

    final info =
        authorizedInfo ??
        await getPlaybackInfo(
          item,
          mediaSourceId: mediaSourceId,
          audioStreamIndex: audioStreamIndex,
          subtitleStreamIndex: subtitleStreamIndex,
          subtitleDisabled: subtitleDisabled,
          maxStreamingBitrate: maxStreamingBitrate,
          forceTranscode: forceTranscode,
        );
    final sources = info.mediaSources;
    StrmDirectPlayPolicy.validateIdentities(sources);
    if (sources.isEmpty) {
      final suffix = info.errorCode == null ? '' : '（${info.errorCode}）';
      throw EmbyApiException('服务器没有提供可播放的媒体源$suffix');
    }
    DiagnosticLog.instance.info(
      'playback',
      'event=playback_sources_received hasSources=${sources.isNotEmpty}',
    );

    PlaybackMediaSource? preferredSource;
    if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
      preferredSource = StrmDirectPlayPolicy.fixedSource(
        sources,
        mediaSourceId,
      );
    } else if (mediaSourceIndex != null &&
        mediaSourceIndex >= 0 &&
        mediaSourceIndex < sources.length) {
      preferredSource = sources[mediaSourceIndex];
    }

    final source =
        preferredSource ?? _bestSource(sources, forceTranscode: forceTranscode);
    final selectedAudio = audioStreamIndex ?? source.defaultAudioStreamIndex;
    final selectedSubtitle = subtitleDisabled
        ? null
        : subtitleStreamIndex ?? source.defaultSubtitleStreamIndex;

    late final Uri uri;
    late final PlayMethod method;
    if (forceTranscode) {
      if (!source.supportsTranscoding || source.transcodingUrl == null) {
        throw const EmbyApiException('服务器没有提供可用的转码流');
      }
      uri = _streamUri(
        source.transcodingUrl!,
        audioStreamIndex: selectedAudio,
        subtitleStreamIndex: selectedSubtitle,
      );
      method = PlayMethod.transcode;
    } else if (_isStrmSource(source)) {
      uri = _streamUri(
        '${session.serverUrl}/Videos/${item.id}/stream?'
        'MediaSourceId=${Uri.encodeQueryComponent(source.id)}&Static=true',
        audioStreamIndex: selectedAudio,
        subtitleStreamIndex: selectedSubtitle,
      );
      method = PlayMethod.directPlay;
    } else if (source.supportsDirectPlay) {
      uri = _streamUri(
        '${session.serverUrl}/Videos/${item.id}/stream?'
        'MediaSourceId=${Uri.encodeQueryComponent(source.id)}&Static=true',
        audioStreamIndex: selectedAudio,
        subtitleStreamIndex: selectedSubtitle,
      );
      method = PlayMethod.directPlay;
    } else if (source.supportsDirectStream && source.directStreamUrl != null) {
      uri = _streamUri(
        source.directStreamUrl!,
        audioStreamIndex: selectedAudio,
        subtitleStreamIndex: selectedSubtitle,
      );
      method = PlayMethod.directStream;
    } else if (source.supportsTranscoding && source.transcodingUrl != null) {
      uri = _streamUri(
        source.transcodingUrl!,
        audioStreamIndex: selectedAudio,
        subtitleStreamIndex: selectedSubtitle,
      );
      method = PlayMethod.transcode;
    } else {
      throw const EmbyApiException('媒体源没有可用的播放地址');
    }

    _logPlaybackDecision(
      method: method,
      usesServerAuthentication: _usesServerAuthentication(uri),
    );
    final duration = _playbackDuration(item: item, source: source);
    return PlaybackPlan(
      uri: uri,
      mediaSourceId: source.id,
      playSessionId: info.playSessionId,
      method: method,
      usesServerAuthentication: _usesServerAuthentication(uri),
      audioStreamIndex: selectedAudio,
      subtitleStreamIndex: subtitleDisabled ? null : selectedSubtitle,
      subtitleDisabled: subtitleDisabled,
      liveStreamId: source.liveStreamId,
      mediaSourceName: source.name,
      container: source.container,
      bitrate: source.bitrate,
      errorCode: info.errorCode,
      sourceProtocol: source.protocol,
      duration: duration,
      sourceSizeBytes: source.size,
      transportKind: classifyPlaybackTransport(
        method: method,
        uri: uri,
        sourceProtocol: source.protocol,
        container: source.container,
        liveStreamId: source.liveStreamId,
        duration: duration,
        sourceUri: Uri.tryParse(source.path ?? ''),
      ),
      mediaStreams: mergeMediaStreams(source.mediaStreams, item.mediaStreams),
      transcodingReasons: source.transcodingReasons,
      availableMediaSources: sources,
    );
  }

  Duration _playbackDuration({
    required EmbyItem item,
    required PlaybackMediaSource source,
  }) {
    final itemTicks = item.runTimeTicks;
    final sourceTicks = source.runTimeTicks;
    final ticks = itemTicks != null && itemTicks > 0
        ? itemTicks
        : sourceTicks != null && sourceTicks > 0
        ? sourceTicks
        : 0;
    return Duration(microseconds: ticks ~/ 10);
  }

  Uri resolveMediaUrl(String rawUrl) => _streamUri(rawUrl);

  Uri trickplayTileUrl({
    required String itemId,
    required int width,
    required int imageIndex,
    String? mediaSourceId,
  }) {
    final encodedItemId = Uri.encodeComponent(itemId);
    return Uri.parse(
      '${session.serverUrl}/Videos/$encodedItemId/Trickplay/$width/$imageIndex.jpg',
    ).replace(queryParameters: {'MediaSourceId': ?mediaSourceId});
  }

  Future<PlaybackInfoResult> getPlaybackInfo(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
    CancelToken? cancelToken,
    Duration? timeout,
    StrmTrace? trace,
  }) async {
    final requestedSubtitleIndex = subtitleDisabled ? -1 : subtitleStreamIndex;
    final commonBody = <String, dynamic>{
      'UserId': session.userId,
      'MediaSourceId': ?mediaSourceId,
      'StartTimeTicks': item.userData.playbackPositionTicks,
      'MaxStreamingBitrate': maxStreamingBitrate,
      'AudioStreamIndex': audioStreamIndex,
      'SubtitleStreamIndex': requestedSubtitleIndex,
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
      'MediaSourceId': ?mediaSourceId,
      'StartTimeTicks': item.userData.playbackPositionTicks,
      'AudioStreamIndex': ?audioStreamIndex,
      'SubtitleStreamIndex': ?requestedSubtitleIndex,
      if (forceTranscode) ...{
        'EnableDirectPlay': false,
        'EnableDirectStream': false,
        'EnableTranscoding': true,
      },
    };
    final attempts = [fullBody, commonBody, minimalBody];

    for (var index = 0; index < attempts.length; index++) {
      final requestNumber = trace?.nextRequest();
      final watch = Stopwatch()..start();
      void event(String outcome, int? status) => trace?.emit('strm_resolve', {
        'request': requestNumber,
        'group': 'regular',
        'attempt': index + 1,
        'strict': false,
        'outcome': outcome,
        'http': status,
        'elapsedMs': watch.elapsedMilliseconds,
      });
      event('started', null);
      try {
        final response = await _request(
          () => _dio.post<dynamic>(
            '/Items/${item.id}/PlaybackInfo',
            data: attempts[index],
            cancelToken: cancelToken,
            options: timeout == null
                ? null
                : Options(sendTimeout: timeout, receiveTimeout: timeout),
            queryParameters: {
              'UserId': session.userId,
              'StartTimeTicks': item.userData.playbackPositionTicks,
            },
          ),
        );
        event('succeeded', response.statusCode);
        return PlaybackInfoResult.fromJson(_map(response.data));
      } on EmbyApiException catch (error) {
        event('failed', error.statusCode);
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
    required bool isPaused,
  }) => _report('/Sessions/Playing', item, plan, position, isPaused);

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
          if (plan.subtitleDisabled)
            'SubtitleStreamIndex': -1
          else if (plan.subtitleStreamIndex != null)
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
      if (!_disposed &&
          friendly.isAuthenticationFailure &&
          _onSessionExpired != null) {
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

  void _logPlaybackDecision({
    required PlayMethod method,
    required bool usesServerAuthentication,
  }) {
    DiagnosticLog.instance.info(
      'playback',
      'event=playback_plan_selected method=${method.serverValue} '
          'usesServerAuthentication=$usesServerAuthentication',
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
    String? serverUrl,
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
    final isConnectionFailure = switch (error.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => true,
      DioExceptionType.unknown => error.error is SocketException,
      _ => false,
    };
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => EmbyApiException(
        '连接服务器超时，请检查地址和网络',
        serverUrl: serverUrl,
        isConnectionFailure: true,
      ),
      DioExceptionType.badCertificate => const EmbyApiException(
        '服务器 HTTPS 证书无效',
      ),
      _ => EmbyApiException(
        '无法连接 Emby 服务器，请检查地址和网络',
        serverUrl: serverUrl,
        isConnectionFailure: isConnectionFailure,
      ),
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
