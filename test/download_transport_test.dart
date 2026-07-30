import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download URLs never contain the Emby access token', () {
    final api = EmbyApi(_session, dio: Dio());

    final uris = api.originalDownloadUris(
      itemId: 'item/with slash',
      mediaSourceId: 'source-1',
    );

    expect(uris, hasLength(4));
    expect(uris.first.path, '/emby/Items/item%2Fwith%20slash/Download');
    expect(
      uris.map((uri) => uri.toString()),
      everyElement(isNot(contains(_session.accessToken))),
    );
    expect(
      uris.map((uri) => uri.queryParameters),
      everyElement(isNot(contains('api_key'))),
    );
  });

  test('opens a resume stream with authenticated Range headers', () async {
    RequestOptions? captured;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<ResponseBody>(
                requestOptions: options,
                statusCode: 206,
                data: ResponseBody.fromBytes(
                  [1, 2, 3],
                  206,
                  headers: {
                    Headers.contentLengthHeader: ['3'],
                    'content-range': ['bytes 7-9/10'],
                  },
                ),
              ),
            );
          },
        ),
      );
    final api = EmbyApi(_session, dio: dio);
    addTearDown(api.dispose);

    final response = await api.openDownload(
      Uri.parse('https://emby.example.test/emby/Items/item/Download'),
      cancelToken: CancelToken(),
      offset: 7,
      etag: '"v1"',
    );

    expect(response.statusCode, 206);
    expect(captured?.headers['Range'], 'bytes=7-');
    expect(captured?.headers['If-Range'], '"v1"');
    expect(captured?.headers['X-Emby-Token'], _session.accessToken);
    expect(captured?.uri.queryParameters, isNot(contains('api_key')));
  });
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test/emby',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
