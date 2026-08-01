import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/person_detail_screen.dart';
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
              EmbyPerson(id: 'person-1', name: '可点击演员', type: 'Actor'),
              EmbyPerson(name: '无 ID 演员', type: 'GuestStar', role: '客串'),
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
        home: PersonDetailScreen(api: api, personId: 'person-1'),
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

Map<String, dynamic> _itemJson(
  String id,
  String name,
  String type, {
  String? overview,
  List<Map<String, dynamic>> people = const [],
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
  'UserData': const <String, dynamic>{},
};

EmbyItem _item(String id, String name) => EmbyItem(
  id: id,
  name: name,
  type: 'Movie',
  mediaType: 'Video',
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
