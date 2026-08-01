import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('image requests', () {
    test('uses bounded dimensions and header authentication', () {
      final api = EmbyApi(_session, dio: Dio());
      final request = api.imageRequest(_photo, maxWidth: 1400, maxHeight: 800);

      expect(request, isNotNull);
      expect(request!.decodeWidth, 1920);
      expect(request.decodeHeight, 900);
      expect(request.uri.queryParameters['maxWidth'], '1920');
      expect(request.uri.queryParameters['maxHeight'], '900');
      expect(request.uri.queryParameters['tag'], 'primary-tag');
      expect(request.uri.queryParameters, isNot(contains('api_key')));
      expect(request.uri.toString(), isNot(contains(_session.accessToken)));
      expect(request.headers['X-Emby-Token'], _session.accessToken);
      expect(request.cacheKey, isNot(contains(_session.accessToken)));
      expect(request.cacheKey, isNot(contains(_session.serverUrl)));
      expect(request.toString(), isNot(contains(_session.accessToken)));
    });

    test('cache keys change with scope, tag, type and size', () {
      final api = EmbyApi(_session, dio: Dio());
      final primary = api.imageRequest(_photo, maxWidth: 500)!;
      final backdrop = api.imageRequest(
        _photo,
        type: 'Backdrop',
        maxWidth: 500,
      )!;
      final larger = api.imageRequest(_photo, maxWidth: 1200)!;
      final changedTag = api.imageRequest(
        _photoWithTag('other-primary'),
        maxWidth: 500,
      )!;
      final boundedHeight = api.imageRequest(
        _photo,
        maxWidth: 500,
        maxHeight: 500,
      )!;
      final otherScope = EmbyApi(
        const EmbySession(
          serverUrl: 'https://emby.example.test',
          serverName: 'Emby',
          serverId: 'server-2',
          userId: 'user-2',
          username: 'other',
          accessToken: 'other-token',
          deviceId: 'device-2',
        ),
        dio: Dio(),
      ).imageRequest(_photo, maxWidth: 500)!;

      expect({
        primary.cacheKey,
        backdrop.cacheKey,
        larger.cacheKey,
        changedTag.cacheKey,
        boundedHeight.cacheKey,
        otherScope.cacheKey,
      }, hasLength(6));
    });

    test('selects deterministic supported width buckets', () {
      expect(EmbyImageRequest.bucketWidth(1), 384);
      expect(EmbyImageRequest.bucketWidth(500), 512);
      expect(EmbyImageRequest.bucketWidth(1280), 1280);
      expect(EmbyImageRequest.bucketWidth(1400), 1920);
      expect(EmbyImageRequest.bucketWidth(9000), 2560);
    });

    test('reports cached image authentication failure once', () async {
      var expired = 0;
      final api = EmbyApi(
        _session,
        dio: Dio(),
        onSessionExpired: () => expired++,
      );
      final request = api.imageRequest(_photo)!;

      request.errorListener?.call(
        HttpExceptionWithStatus(404, 'not found', uri: request.uri),
      );
      request.errorListener?.call(
        HttpExceptionWithStatus(401, 'expired', uri: request.uri),
      );
      request.errorListener?.call(
        HttpExceptionWithStatus(403, 'expired again', uri: request.uri),
      );
      await Future<void>.delayed(Duration.zero);

      expect(expired, 1);
    });

    test(
      'ignores cached image authentication failure after disposal',
      () async {
        var expired = 0;
        final api = EmbyApi(
          _session,
          dio: Dio(),
          onSessionExpired: () => expired++,
        );
        final request = api.imageRequest(_photo)!;
        await api.dispose();

        request.errorListener?.call(
          HttpExceptionWithStatus(401, 'late response', uri: request.uri),
        );
        await Future<void>.delayed(Duration.zero);

        expect(expired, 0);
      },
    );
  });

  test('photo directory query preserves hierarchy and pagination', () async {
    RequestOptions? captured;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'Items': [
                    {
                      'Id': 'photo-1',
                      'Name': 'Photo 1',
                      'Type': 'Photo',
                      'ImageTags': {'Primary': 'tag-1'},
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
    final api = EmbyApi(_session, dio: dio);

    final items = await api.getPhotoChildren(
      parentId: 'album-1',
      startIndex: 60,
      limit: 30,
    );

    expect(items.single.id, 'photo-1');
    expect(captured?.path, '/Users/user-1/Items');
    expect(captured?.queryParameters, containsPair('ParentId', 'album-1'));
    expect(captured?.queryParameters, containsPair('StartIndex', 60));
    expect(captured?.queryParameters, containsPair('Limit', 30));
    expect(captured?.queryParameters, containsPair('Recursive', false));
    expect(
      captured?.queryParameters,
      containsPair('IncludeItemTypes', 'Photo,PhotoAlbum,Folder'),
    );
    expect(captured?.queryParameters, containsPair('SortBy', 'SortName'));
  });
}

EmbyItem _photoWithTag(String tag) => EmbyItem(
  id: _photo.id,
  name: _photo.name,
  type: _photo.type,
  imageTags: {'Primary': tag, 'Backdrop': 'backdrop-tag'},
  backdropImageTags: const ['backdrop-tag'],
  genres: const [],
  userData: const EmbyUserData(),
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

const _photo = EmbyItem(
  id: 'photo-1',
  name: 'Photo 1',
  type: 'Photo',
  imageTags: {'Primary': 'primary-tag', 'Backdrop': 'backdrop-tag'},
  backdropImageTags: ['backdrop-tag'],
  genres: [],
  userData: EmbyUserData(),
);
