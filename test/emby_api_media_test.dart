import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'list requests exclude playback payloads while detail keeps them',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: options.path.endsWith('/item-1')
                ? _itemJson
                : {
                    'TotalRecordCount': 1,
                    'Items': [_itemJson],
                  },
          ),
        );
      });

      await api.getLibraryItems(parentId: 'library-1');
      await api.getItem('item-1');

      final listFields = requests.first.queryParameters['Fields'].toString();
      final detailFields = requests.last.queryParameters['Fields'].toString();
      for (final field in [
        'People',
        'MediaSources',
        'MediaStreams',
        'Chapters',
        'Trickplay',
      ]) {
        expect(listFields, isNot(contains(field)));
        expect(detailFields, contains(field));
      }
    },
  );

  test('image authentication is sent in headers instead of the URL', () {
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: const {},
        ),
      );
    });
    final request = api.imageRequest(_item, maxWidth: 500)!;
    final url = request.uri;

    expect(url.queryParameters, isNot(contains('api_key')));
    expect(url.queryParameters['tag'], 'primary-tag');
    expect(request.headers['X-Emby-Token'], _session.accessToken);
    expect(request.headers['X-Emby-Authorization'], isNotEmpty);
  });

  test('person image requests use ID and tag without URL credentials', () {
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: const {},
        ),
      );
    });
    final request = api.imageRequestForTag(
      itemId: 'person/1',
      type: 'Primary',
      tag: 'person-tag',
      maxWidth: 240,
      maxHeight: 360,
    )!;

    expect(request.uri.path, '/Items/person%2F1/Images/Primary');
    expect(request.uri.queryParameters['tag'], 'person-tag');
    expect(request.uri.toString(), isNot(contains(_session.accessToken)));
    expect(request.headers['X-Emby-Token'], _session.accessToken);
    expect(request.cacheKey, contains(':person/1:primary:person-tag:'));
    expect(request.cacheKey, isNot(contains(_session.accessToken)));
    expect(
      api.imageRequestForTag(
        itemId: 'person-1',
        type: 'Primary',
        tag: null,
        maxWidth: 240,
      ),
      isNull,
    );
    expect(
      api.imageRequestForTag(
        itemId: '',
        type: 'Primary',
        tag: 'orphan-tag',
        maxWidth: 240,
      ),
      isNull,
    );
  });
}

EmbyApi _api(
  void Function(RequestOptions options, RequestInterceptorHandler handler)
  onRequest,
) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return EmbyApi(_session, dio: dio);
}

const _itemJson = {
  'Id': 'item-1',
  'Name': '示例视频',
  'Type': 'Video',
  'MediaType': 'Video',
  'ImageTags': {'Primary': 'primary-tag'},
  'BackdropImageTags': <String>[],
  'Genres': <String>[],
  'UserData': <String, dynamic>{},
};

const _item = EmbyItem(
  id: 'item-1',
  name: '示例视频',
  type: 'Video',
  mediaType: 'Video',
  imageTags: {'Primary': 'primary-tag'},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
