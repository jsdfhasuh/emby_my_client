import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads the next season when the current queue ends', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'Items': [
                  {
                    'Id': 'episode-2',
                    'Name': 'Second',
                    'Type': 'Episode',
                    'MediaType': 'Video',
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final api = EmbyApi(_session, dio: dio);
    final queue = PlaybackQueue(
      api: api,
      initialItems: const [_episode1],
      seriesId: 'series-1',
      seasons: const [_season1, _season2],
      currentSeasonId: 'season-1',
    );

    final next = await queue.next(_episode1);

    expect(next?.id, 'episode-2');
    expect(requests, hasLength(1));
    expect(requests.single.queryParameters['SeasonId'], 'season-2');
    expect(queue.previous(next!), _episode1);
  });
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

const _episode1 = EmbyItem(
  id: 'episode-1',
  name: 'First',
  type: 'Episode',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _season1 = EmbyItem(
  id: 'season-1',
  name: 'Season 1',
  type: 'Season',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _season2 = EmbyItem(
  id: 'season-2',
  name: 'Season 2',
  type: 'Season',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
