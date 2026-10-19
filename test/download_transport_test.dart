import 'package:dio/dio.dart';
import 'dart:io';
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
    HttpRequest? captured;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      captured = request;
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 7-9/10');
      request.response.contentLength = 3;
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    final api = EmbyApi(
      EmbySession(
        serverUrl: 'http://127.0.0.1:${server.port}/emby',
        serverName: 'Test Emby',
        serverId: 'server-1',
        userId: 'user-1',
        username: 'tester',
        accessToken: _session.accessToken,
        deviceId: 'device-1',
      ),
    );
    addTearDown(api.dispose);

    final response = await api.openDownload(
      Uri.parse('http://127.0.0.1:${server.port}/emby/Items/item/Download'),
      cancelToken: CancelToken(),
      offset: 7,
      etag: '"v1"',
    );

    expect(response.statusCode, 206);
    expect(await response.data!.stream.expand((bytes) => bytes).toList(), [
      1,
      2,
      3,
    ]);
    expect(captured?.headers.value('Accept-Encoding'), 'identity');
    expect(captured?.headers.value('Range'), 'bytes=7-');
    expect(captured?.headers.value('If-Range'), '"v1"');
    expect(captured?.headers.value('X-Emby-Token'), _session.accessToken);
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
