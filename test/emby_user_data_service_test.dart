import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses canonical favorite and played item endpoints', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(
        Response<dynamic>(requestOptions: options, statusCode: 204),
      );
    });

    await api.userData.setFavorite('item with/slash', favorite: true);
    await api.userData.setFavorite('item-1', favorite: false);
    await api.userData.setPlayed('item-1', played: true);
    await api.userData.setPlayed('item-1', played: false);

    expect(requests.map((request) => request.method), [
      'POST',
      'DELETE',
      'POST',
      'DELETE',
    ]);
    expect(requests.map((request) => request.path), [
      '/Users/user-1/FavoriteItems/item%20with%2Fslash',
      '/Users/user-1/FavoriteItems/item-1',
      '/Users/user-1/PlayedItems/item-1',
      '/Users/user-1/PlayedItems/item-1',
    ]);
  });

  for (final status in [401, 403]) {
    test('expires the session after user data HTTP $status', () async {
      var expired = false;
      final api = _api(
        (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response<dynamic>(
                requestOptions: options,
                statusCode: status,
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
        onSessionExpired: () async {
          expired = true;
        },
      );

      await expectLater(
        api.userData.setFavorite('item-1', favorite: true),
        throwsA(
          isA<EmbyApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            status,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(expired, isTrue);
    });
  }
}

typedef _RequestHandler =
    void Function(RequestOptions options, RequestInterceptorHandler handler);

EmbyApi _api(
  _RequestHandler handler, {
  Future<void> Function()? onSessionExpired,
}) {
  final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: handler));
  return EmbyApi(_session, dio: dio, onSessionExpired: onSessionExpired);
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
