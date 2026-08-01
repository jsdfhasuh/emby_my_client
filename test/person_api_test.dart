import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'person works query uses server paging, sorting, and movie/series only',
    () async {
      RequestOptions? captured;
      final api = _api((options, handler) {
        captured = options;
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: {
              'TotalRecordCount': 81,
              'Items': [
                _itemJson('movie-1', 'Movie'),
                _itemJson('movie-1', 'Movie'),
                _itemJson('series-1', 'Series'),
              ],
            },
          ),
        );
      });

      final page = await api.getPersonItems(
        personId: 'person/一 & 2',
        startIndex: 60,
        limit: 30,
      );

      expect(page.items.map((item) => item.id), ['movie-1', 'series-1']);
      expect(page.rawItemCount, 3);
      expect(page.totalRecordCount, 81);
      expect(captured?.path, '/Users/user-1/Items');
      expect(captured?.uri.path, '/Users/user-1/Items');
      expect(captured?.uri.queryParameters['PersonIds'], 'person/一 & 2');
      expect(captured?.queryParameters['IncludeItemTypes'], 'Movie,Series');
      expect(captured?.queryParameters['Recursive'], true);
      expect(captured?.queryParameters['SortBy'], 'PremiereDate');
      expect(captured?.queryParameters['SortOrder'], 'Descending');
      expect(captured?.queryParameters['StartIndex'], 60);
      expect(captured?.queryParameters['Limit'], 30);
      expect(captured?.queryParameters['EnableUserData'], true);
      expect(captured?.queryParameters['EnableImages'], true);
      expect(captured?.queryParameters['EnableTotalRecordCount'], true);
      expect(captured?.queryParameters.toString(), isNot(contains('Episode')));
    },
  );

  test('person work filters map to one server media type', () async {
    final types = <PersonMediaFilter, String>{};
    final api = _api((options, handler) {
      final raw = options.queryParameters['IncludeItemTypes'] as String;
      final filter = PersonMediaFilter.values.singleWhere(
        (candidate) => candidate.apiValue == raw,
      );
      types[filter] = raw;
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: const {'Items': <dynamic>[]},
        ),
      );
    });

    await api.getPersonItems(
      personId: 'person-1',
      filter: PersonMediaFilter.movie,
    );
    await api.getPersonItems(
      personId: 'person-1',
      filter: PersonMediaFilter.series,
    );

    expect(types[PersonMediaFilter.movie], 'Movie');
    expect(types[PersonMediaFilter.series], 'Series');
  });

  test('empty person result keeps a missing total count as unknown', () async {
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: const {'Items': <dynamic>[]},
        ),
      );
    });

    final page = await api.getPersonItems(personId: 'person-1');

    expect(page.items, isEmpty);
    expect(page.totalRecordCount, isNull);
  });

  test('blank person ID is rejected before a request is sent', () async {
    var requests = 0;
    final api = _api((options, handler) {
      requests++;
      handler.resolve(
        Response<dynamic>(requestOptions: options, statusCode: 200),
      );
    });

    await expectLater(api.getPersonItems(personId: '   '), throwsArgumentError);
    expect(requests, 0);
  });

  for (final status in [401, 403]) {
    test('person works HTTP $status expires the session', () async {
      var expired = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
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
          ),
        );
      final api = EmbyApi(
        _session,
        dio: dio,
        onSessionExpired: () => expired++,
      );

      await expectLater(
        api.getPersonItems(personId: 'person-1'),
        throwsA(
          isA<EmbyApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            status,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(expired, 1);
    });
  }
}

EmbyApi _api(
  void Function(RequestOptions options, RequestInterceptorHandler handler)
  onRequest,
) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return EmbyApi(_session, dio: dio);
}

Map<String, dynamic> _itemJson(String id, String type) => {
  'Id': id,
  'Name': id,
  'Type': type,
  'ImageTags': const <String, String>{},
  'BackdropImageTags': const <String>[],
  'Genres': const <String>[],
  'UserData': const <String, dynamic>{},
};

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
