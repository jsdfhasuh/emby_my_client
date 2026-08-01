import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/search/search_history_store.dart';
import 'package:emby_my_client/ui/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'search sends paging and type parameters without overriding relevance',
    () async {
      RequestOptions? captured;
      final api = _api((options, handler) {
        captured = options;
        handler.resolve(_searchResponse(options));
      });

      final page = await api.search(
        '示例',
        startIndex: 60,
        limit: 30,
        itemType: SearchItemType.folder,
      );

      expect(page.totalRecordCount, 1);
      expect(page.items.map((item) => item.id), ['folder-1']);
      expect(captured?.path, '/Users/user-1/Items');
      expect(captured?.queryParameters['SearchTerm'], '示例');
      expect(captured?.queryParameters['StartIndex'], 60);
      expect(captured?.queryParameters['Limit'], 30);
      expect(
        captured?.queryParameters['IncludeItemTypes'],
        'Folder,CollectionFolder',
      );
      expect(captured?.queryParameters['EnableTotalRecordCount'], true);
      expect(captured?.queryParameters, isNot(contains('SortBy')));
    },
  );

  test('blank search returns an empty page without making a request', () async {
    var requestCount = 0;
    final api = _api((options, handler) {
      requestCount++;
      handler.resolve(_searchResponse(options));
    });

    final page = await api.search('   ');

    expect(requestCount, 0);
    expect(page.items, isEmpty);
    expect(page.totalRecordCount, 0);
  });

  test('recent searches are case-insensitive, newest-first, and bounded', () {
    final history = updatedSearchHistory(
      ['Alien', 'Blade Runner', 'ALIEN', ''],
      '  alien  ',
      limit: 3,
    );
    expect(history, ['alien', 'Blade Runner']);

    var current = <String>[];
    for (var index = 0; index < 20; index++) {
      current = updatedSearchHistory(current, 'query-$index');
    }
    expect(current, hasLength(searchHistoryLimit));
    expect(current.first, 'query-19');
    expect(current.last, 'query-8');
  });

  testWidgets('search restores history and refetches for a selected type', (
    tester,
  ) async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_searchResponse(options));
    });
    final history = MemorySearchHistoryStore();
    await history.add(ServerScope.fromSession(_session), '示例');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SearchScreen(api: api, historyStore: history),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最近搜索'), findsOneWidget);
    expect(find.text('示例'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, '示例'));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['SearchTerm'], '示例');
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      SearchItemType.all.apiValue,
    );

    final folderFilter = find.descendant(
      of: find.byType(ChoiceChip),
      matching: find.text('文件夹'),
    );
    await tester.tap(folderFilter);
    await tester.pumpAndSettle();

    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      SearchItemType.folder.apiValue,
    );
    expect(find.text('目录 A'), findsOneWidget);
  });

  testWidgets('search paging advances by raw page size after deduplication', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      final startIndex = options.queryParameters['StartIndex'] as int;
      final items = startIndex == 0
          ? List.generate(60, (index) => _resultItem(index == 59 ? 0 : index))
          : [_resultItem(60)];
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {'TotalRecordCount': 61, 'Items': items},
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SearchScreen(
            api: api,
            historyStore: MemorySearchHistoryStore(),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '分页');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -12000),
      12000,
    );
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests.last.queryParameters['StartIndex'], 60);
    expect(find.text('项目 60'), findsOneWidget);
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

Response<dynamic> _searchResponse(RequestOptions options) {
  final isFolder =
      options.queryParameters['IncludeItemTypes'] ==
      SearchItemType.folder.apiValue;
  final item = isFolder
      ? {
          'Id': 'folder-1',
          'Name': '目录 A',
          'Type': 'Folder',
          'ImageTags': const <String, String>{},
          'BackdropImageTags': const <String>[],
          'Genres': const <String>[],
          'UserData': const <String, dynamic>{},
        }
      : {
          'Id': 'movie-1',
          'Name': '示例电影',
          'Type': 'Movie',
          'MediaType': 'Video',
          'ImageTags': const <String, String>{},
          'BackdropImageTags': const <String>[],
          'Genres': const <String>[],
          'UserData': const <String, dynamic>{},
        };
  return Response<dynamic>(
    requestOptions: options,
    statusCode: 200,
    data: {
      'TotalRecordCount': isFolder ? 1 : 87,
      'Items': [item],
    },
  );
}

Map<String, dynamic> _resultItem(int index) => {
  'Id': 'item-$index',
  'Name': '项目 $index',
  'Type': 'Video',
  'MediaType': 'Video',
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
