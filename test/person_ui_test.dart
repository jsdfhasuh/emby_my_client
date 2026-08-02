import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/person_detail_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:emby_my_client/ui/widgets/person_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cast cards show placeholders and only valid IDs are links', (
    tester,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CastRow(
            people: const [
              EmbyPerson(id: 'person-1', name: '可点击演员', type: ' actor '),
              EmbyPerson(name: '无 ID 演员', type: 'gueststar', role: '客串'),
              EmbyPerson(id: 'director-1', name: '导演', type: 'Director'),
            ],
            imageRequestFor: (_) => null,
            onTap: (person) => tapped.add(person.id!),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.person_outline_rounded), findsNWidgets(2));
    expect(find.text('导演'), findsNothing);
    expect(find.byKey(const ValueKey('cast-link-person-1')), findsOneWidget);
    expect(
      find.ancestor(of: find.text('无 ID 演员'), matching: find.byType(InkWell)),
      findsNothing,
    );

    await tester.tap(find.text('无 ID 演员'));
    await tester.tap(find.byKey(const ValueKey('cast-link-person-1')));
    expect(tapped, ['person-1']);
  });

  testWidgets('movie cast opens the matching person page', (tester) async {
    final api = _api((options, handler) {
      if (options.queryParameters['PersonIds'] != null) {
        handler.resolve(_pageResponse(options, const [], total: 0));
        return;
      }
      if (options.path.endsWith('/movie-1')) {
        handler.resolve(
          _itemResponse(
            options,
            _itemJson(
              'movie-1',
              '示例电影',
              'Movie',
              people: const [
                {
                  'Id': 'person-1',
                  'Name': '演员一',
                  'Type': 'Actor',
                  'Role': '主角',
                  'PrimaryImageTag': 'actor-image-tag',
                },
                {'Name': '无 ID 演员', 'Type': 'GuestStar'},
                {'Id': 'director-1', 'Name': '导演一', 'Type': 'Director'},
              ],
            ),
          ),
        );
        return;
      }
      if (options.path.endsWith('/person-1')) {
        handler.resolve(
          _itemResponse(options, _itemJson('person-1', '演员一', 'Person')),
        );
        return;
      }
      fail('Unexpected request: ${options.uri}');
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ItemDetailScreen(api: api, initialItem: _item('movie-1', '示例电影')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('演员'), findsOneWidget);
    expect(find.text('导演一'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('cast-link-person-1')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('cast-link-person-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('person-detail-scroll')), findsOneWidget);
    final personScreen = tester.widget<PersonDetailScreen>(
      find.byType(PersonDetailScreen),
    );
    expect(personScreen.initialPerson.name, '演员一');
    expect(personScreen.initialPerson.role, '主角');
    expect(personScreen.initialPerson.primaryImageTag, 'actor-image-tag');
    expect(find.text('演员一'), findsWidgets);
    expect(find.text('当前服务器没有收录此人物的电影或电视剧'), findsOneWidget);
  });

  testWidgets('person works page filters, pages, and opens existing details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final requests = <({String types, int start})>[];
    final api = _api((options, handler) {
      final personId = options.queryParameters['PersonIds'];
      if (personId != null) {
        final types = options.queryParameters['IncludeItemTypes'] as String;
        final start = options.queryParameters['StartIndex'] as int;
        requests.add((types: types, start: start));
        if (types == 'Movie') {
          handler.resolve(
            _pageResponse(options, [
              _itemJson('filtered-movie', '筛选电影', 'Movie'),
            ], total: 1),
          );
          return;
        }
        final items = start == 0
            ? [
                for (var index = 0; index < 60; index++)
                  _itemJson('work-$index', '作品 $index', 'Movie'),
              ]
            : [_itemJson('work-60', '作品 60', 'Series')];
        handler.resolve(_pageResponse(options, items, total: 61));
        return;
      }
      if (options.path.endsWith('/person-1')) {
        handler.resolve(
          _itemResponse(
            options,
            _itemJson('person-1', '演员一', 'Person', overview: ''),
          ),
        );
        return;
      }
      if (options.path.endsWith('/filtered-movie')) {
        handler.resolve(
          _itemResponse(options, _itemJson('filtered-movie', '筛选电影', 'Movie')),
        );
        return;
      }
      fail('Unexpected request: ${options.uri}');
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: PersonDetailScreen(
          api: api,
          personId: 'person-1',
          initialPerson: const EmbyPerson(
            id: 'person-1',
            name: '演员一',
            type: 'Actor',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('简介'), findsNothing);
    expect(find.text('共 61 部'), findsOneWidget);

    await tester.fling(
      find.byKey(const Key('person-detail-scroll')),
      const Offset(0, -14000),
      12000,
    );
    await tester.pumpAndSettle();

    expect(requests, contains((types: 'Movie,Series', start: 60)));
    expect(find.text('作品 60'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('person-filter-movie')),
      -700,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('person-filter-movie')));
    await tester.pumpAndSettle();

    expect(requests.last, (types: 'Movie', start: 0));
    expect(find.text('共 1 部'), findsOneWidget);
    expect(find.text('筛选电影'), findsOneWidget);

    await tester.tap(find.text('筛选电影'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailScreen), findsOneWidget);
    expect(find.text('筛选电影'), findsWidgets);
  });

  testWidgets(
    'failed person details show typed fallback and successful works',
    (tester) async {
      final api = _api((options, handler) {
        if (options.queryParameters['PersonIds'] != null) {
          handler.resolve(
            _pageResponse(options, [
              _itemJson('fallback-work', '回退作品', 'Movie'),
            ], total: 1),
          );
          return;
        }
        if (options.path.endsWith('/person-1')) {
          handler.reject(_httpError(options, 500));
          return;
        }
        fail('Unexpected request: ${options.uri}');
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: PersonDetailScreen(
            api: api,
            personId: 'person-1',
            initialPerson: const EmbyPerson(
              id: 'person-1',
              name: '回退演员',
              type: 'Actor',
              primaryImageTag: 'fallback-image-tag',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('回退演员'), findsWidgets);
      expect(find.text('回退作品'), findsOneWidget);
      expect(find.text('人物资料加载失败'), findsOneWidget);
      expect(find.text('重试人物资料'), findsOneWidget);
      final avatar = tester.widget<PersonAvatar>(find.byType(PersonAvatar));
      expect(
        avatar.imageRequest?.uri.queryParameters['tag'],
        'fallback-image-tag',
      );
    },
  );

  testWidgets('person detail retry replaces fallback with server data', (
    tester,
  ) async {
    var detailAttempts = 0;
    final api = _api((options, handler) {
      if (options.queryParameters['PersonIds'] != null) {
        handler.resolve(_pageResponse(options, const [], total: 0));
        return;
      }
      if (options.path.endsWith('/person-1')) {
        detailAttempts++;
        if (detailAttempts == 1) {
          handler.reject(_httpError(options, 500));
        } else {
          handler.resolve(
            _itemResponse(options, _itemJson('person-1', '服务端人物', 'Person')),
          );
        }
        return;
      }
      fail('Unexpected request: ${options.uri}');
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: PersonDetailScreen(
          api: api,
          personId: 'person-1',
          initialPerson: const EmbyPerson(
            id: 'person-1',
            name: '回退演员',
            type: 'Actor',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('人物资料加载失败'), findsOneWidget);

    await tester.tap(find.text('重试人物资料'));
    await tester.pumpAndSettle();

    expect(detailAttempts, 2);
    expect(find.text('服务端人物'), findsWidgets);
    expect(find.text('人物资料加载失败'), findsNothing);
  });

  testWidgets('returning from a work refreshes only that item user data', (
    tester,
  ) async {
    final refreshedIds = <String>[];
    final api = _api((options, handler) {
      if (options.queryParameters['Ids'] case final String ids) {
        refreshedIds.add(ids);
        handler.resolve(
          _pageResponse(options, [
            _itemJson(
              'work-15',
              '待刷新作品',
              'Movie',
              userData: const {
                'PlaybackPositionTicks': 7200000000,
                'PlayedPercentage': 75,
                'Played': true,
                'IsFavorite': true,
                'UnplayedItemCount': 3,
              },
            ),
          ], total: 1),
        );
        return;
      }
      if (options.queryParameters['PersonIds'] != null) {
        handler.resolve(
          _pageResponse(options, [
            for (var index = 1; index <= 20; index++)
              _itemJson(
                'work-$index',
                index == 15 ? '待刷新作品' : '未打开作品 $index',
                'Movie',
                userData: index == 15
                    ? const {'PlayedPercentage': 10}
                    : const {},
              ),
          ], total: 20),
        );
        return;
      }
      if (options.path.endsWith('/person-1')) {
        handler.resolve(
          _itemResponse(options, _itemJson('person-1', '演员一', 'Person')),
        );
        return;
      }
      if (options.path.endsWith('/work-15')) {
        handler.resolve(
          _itemResponse(options, _itemJson('work-15', '待刷新作品', 'Movie')),
        );
        return;
      }
      fail('Unexpected request: ${options.uri}');
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: PersonDetailScreen(
          api: api,
          personId: 'person-1',
          initialPerson: const EmbyPerson(
            id: 'person-1',
            name: '演员一',
            type: 'Actor',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('person-work-work-15')),
      700,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    await tester.tap(find.byKey(const ValueKey('person-work-work-15')));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(refreshedIds, ['work-15']);
    final after = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(after, closeTo(before, 1));
    final refreshed = tester.widget<MediaPosterCard>(
      find.byKey(const ValueKey('person-work-work-15')),
    );
    final untouched = tester.widget<MediaPosterCard>(
      find.byKey(const ValueKey('person-work-work-14')),
    );
    expect(refreshed.item.userData.playbackPositionTicks, 7200000000);
    expect(refreshed.item.userData.playedPercentage, 75);
    expect(refreshed.item.userData.isPlayed, isTrue);
    expect(refreshed.item.userData.isFavorite, isTrue);
    expect(refreshed.item.userData.unplayedItemCount, 3);
    expect(untouched.item.userData.isPlayed, isFalse);
    expect(find.text('共 20 部', skipOffstage: false), findsOneWidget);
  });

  for (final type in ['Movie', 'Series', 'Episode']) {
    testWidgets('$type details show the cast section', (tester) async {
      final api = _api((options, handler) {
        if (options.path.endsWith('/media-1')) {
          handler.resolve(
            _itemResponse(
              options,
              _itemJson(
                'media-1',
                '媒体详情',
                type,
                people: const [
                  {'Id': 'person-1', 'Name': '测试演员', 'Type': 'Actor'},
                ],
              ),
            ),
          );
          return;
        }
        if (options.path == '/Shows/media-1/Seasons' ||
            options.path == '/Shows/media-1/Episodes') {
          handler.resolve(_pageResponse(options, const [], total: 0));
          return;
        }
        fail('Unexpected request: ${options.uri}');
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: ItemDetailScreen(
            api: api,
            initialItem: _item('media-1', '媒体详情', type: type),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('演员'), findsOneWidget);
      expect(find.text('测试演员'), findsOneWidget);
    });
  }

  testWidgets('season details do not show the cast section', (tester) async {
    final api = _api((options, handler) {
      handler.resolve(
        _itemResponse(
          options,
          _itemJson(
            'season-1',
            '第一季',
            'Season',
            people: const [
              {'Id': 'person-1', 'Name': '测试演员', 'Type': 'Actor'},
            ],
          ),
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ItemDetailScreen(
          api: api,
          initialItem: _item('season-1', '第一季', type: 'Season'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('演员'), findsNothing);
    expect(find.text('测试演员'), findsNothing);
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

Response<dynamic> _itemResponse(
  RequestOptions options,
  Map<String, dynamic> item,
) => Response<dynamic>(requestOptions: options, statusCode: 200, data: item);

Response<dynamic> _pageResponse(
  RequestOptions options,
  List<Map<String, dynamic>> items, {
  required int total,
}) => Response<dynamic>(
  requestOptions: options,
  statusCode: 200,
  data: {'Items': items, 'TotalRecordCount': total},
);

DioException _httpError(RequestOptions options, int statusCode) => DioException(
  requestOptions: options,
  response: Response<dynamic>(requestOptions: options, statusCode: statusCode),
  type: DioExceptionType.badResponse,
);

Map<String, dynamic> _itemJson(
  String id,
  String name,
  String type, {
  String? overview,
  List<Map<String, dynamic>> people = const [],
  Map<String, dynamic> userData = const {},
}) => {
  'Id': id,
  'Name': name,
  'Type': type,
  'MediaType': type == 'Movie' ? 'Video' : null,
  'Overview': overview,
  'People': people,
  'ImageTags': const <String, String>{},
  'BackdropImageTags': const <String>[],
  'Genres': const <String>[],
  'UserData': userData,
};

EmbyItem _item(String id, String name, {String type = 'Movie'}) => EmbyItem(
  id: id,
  name: name,
  type: type,
  mediaType: type == 'Movie' || type == 'Episode' ? 'Video' : null,
  imageTags: const {},
  backdropImageTags: const [],
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
