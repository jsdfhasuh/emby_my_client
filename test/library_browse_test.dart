import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('library browse sends server-side sort and filter parameters', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_libraryResponse(options));
    });

    final page = await api.getLibraryItems(
      parentId: 'library-1',
      startIndex: 60,
      limit: 30,
      options: const LibraryBrowseOptions(
        sortBy: LibrarySortBy.dateAdded,
        sortOrder: LibrarySortOrder.descending,
        playedFilter: LibraryPlayedFilter.unplayed,
        itemType: LibraryItemType.movie,
        favoriteOnly: true,
      ),
    );

    expect(page.totalRecordCount, 116);
    expect(page.items.single.id, 'movie-1');
    expect(captured?.path, '/Users/user-1/Items');
    expect(captured?.queryParameters, containsPair('ParentId', 'library-1'));
    expect(captured?.queryParameters, containsPair('StartIndex', 60));
    expect(captured?.queryParameters, containsPair('Limit', 30));
    expect(captured?.queryParameters, containsPair('SortBy', 'DateCreated'));
    expect(captured?.queryParameters, containsPair('SortOrder', 'Descending'));
    expect(captured?.queryParameters, containsPair('Filters', 'IsUnplayed'));
    expect(
      captured?.queryParameters,
      containsPair('IncludeItemTypes', 'Movie'),
    );
    expect(captured?.queryParameters, containsPair('IsFavorite', true));
    expect(
      captured?.queryParameters,
      containsPair('EnableTotalRecordCount', true),
    );
  });

  test('folder browsing requests only the current directory level', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_libraryResponse(options));
    });

    await api.getLibraryItems(
      parentId: 'library-1',
      options: const LibraryBrowseOptions(itemType: LibraryItemType.folder),
    );

    expect(captured?.queryParameters['Recursive'], false);
    expect(
      captured?.queryParameters['IncludeItemTypes'],
      'Folder,Movie,Series,Episode,Video',
    );
  });

  testWidgets('library controls expose count sorting and staged filters', (
    tester,
  ) async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_libraryResponse(options));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen(
          api: api,
          view: _library,
          categorySettings: _allCategorySettings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('共 116 项'), findsOneWidget);
    expect(find.text('节目'), findsOneWidget);
    final movieQuickFilter = find.descendant(
      of: find.byType(ChoiceChip),
      matching: find.text('电影'),
    );
    expect(movieQuickFilter, findsOneWidget);
    expect(find.byTooltip('排序方式'), findsOneWidget);
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ChoiceChip), matching: find.text('文件夹')),
      findsOneWidget,
    );

    await tester.tap(movieQuickFilter);
    await tester.pumpAndSettle();
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      LibraryItemType.movie.apiValue,
    );

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    expect(find.text('播放状态'), findsOneWidget);
    expect(find.text('项目类型'), findsOneWidget);

    await tester.tap(find.text('未播放'));
    await tester.tap(find.text('只看收藏'));
    await tester.tap(find.text('查看结果'));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['Filters'], 'IsUnplayed');
    expect(requests.last.queryParameters['IncludeItemTypes'], 'Movie');
    expect(requests.last.queryParameters['IsFavorite'], true);
  });

  testWidgets('library defaults hide optional media type categories', (
    tester,
  ) async {
    final api = _api((options, handler) {
      handler.resolve(_libraryResponse(options));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    expect(_quickCategory('节目'), findsOneWidget);
    expect(_quickCategory('电影'), findsNothing);
    expect(_quickCategory('剧集'), findsNothing);
    expect(_quickCategory('视频'), findsNothing);
    expect(_quickCategory('收藏'), findsOneWidget);
    expect(_quickCategory('文件夹'), findsOneWidget);
  });

  testWidgets('folder category opens nested folder browsing', (tester) async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_folderResponse(options));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    final folderCategory = find.descendant(
      of: find.byType(ChoiceChip),
      matching: find.text('文件夹'),
    );
    await tester.tap(folderCategory);
    await tester.pumpAndSettle();

    expect(find.text('目录 A'), findsOneWidget);
    expect(requests.last.queryParameters['Recursive'], false);

    await tester.tap(find.text('目录 A'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '目录 A'), findsOneWidget);
    expect(requests.last.queryParameters['ParentId'], 'folder-1');
    expect(requests.last.queryParameters['Recursive'], false);
  });

  testWidgets('returning from details restores a deeply scrolled position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final browseStarts = <int>[];
    String? refreshedItemId;
    final api = _api((options, handler) {
      if (options.path.startsWith('/Users/user-1/Items/item-')) {
        final id = options.path.split('/').last;
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: _pagedItem(int.parse(id.split('-').last)),
          ),
        );
        return;
      }
      if (options.queryParameters['Ids'] case final String ids) {
        refreshedItemId = ids;
        final index = int.parse(ids.split('-').last);
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: {
              'Items': [_pagedItem(index)],
            },
          ),
        );
        return;
      }
      final start = options.queryParameters['StartIndex'] as int;
      final limit = options.queryParameters['Limit'] as int;
      browseStarts.add(start);
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 120,
            'Items': [
              for (
                var index = start;
                index < (start + limit).clamp(0, 120);
                index++
              )
                _pagedItem(index),
            ],
          },
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('项目 70'),
      700,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    await tester.tap(find.text('项目 70'));
    await tester.pumpAndSettle();
    expect(find.text('项目 70'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    final after = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(after, closeTo(before, 1));
    expect(browseStarts, [0, 60]);
    expect(refreshedItemId, 'item-70');
  });
}

Finder _quickCategory(String label) =>
    find.descendant(of: find.byType(ChoiceChip), matching: find.text(label));

EmbyApi _api(
  void Function(RequestOptions options, RequestInterceptorHandler handler)
  onRequest,
) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return EmbyApi(_session, dio: dio);
}

Response<dynamic> _libraryResponse(RequestOptions options) => Response<dynamic>(
  requestOptions: options,
  statusCode: 200,
  data: {
    'TotalRecordCount': 116,
    'Items': [
      {
        'Id': 'movie-1',
        'Name': '示例电影',
        'Type': 'Movie',
        'MediaType': 'Video',
        'ImageTags': const <String, String>{},
        'BackdropImageTags': const <String>[],
        'Genres': const <String>[],
        'UserData': const <String, dynamic>{},
      },
    ],
  },
);

Response<dynamic> _folderResponse(RequestOptions options) {
  final query = options.queryParameters;
  final isFolderView =
      query['IncludeItemTypes'] == LibraryItemType.folder.apiValue;
  final isLibraryRoot = query['ParentId'] == _library.id;
  final items = isFolderView && isLibraryRoot
      ? [
          {
            'Id': 'folder-1',
            'Name': '目录 A',
            'Type': 'Folder',
            'ImageTags': const <String, String>{},
            'BackdropImageTags': const <String>[],
            'Genres': const <String>[],
            'UserData': const <String, dynamic>{},
          },
        ]
      : const <Map<String, dynamic>>[];
  return Response<dynamic>(
    requestOptions: options,
    statusCode: 200,
    data: {'TotalRecordCount': items.length, 'Items': items},
  );
}

Map<String, dynamic> _pagedItem(int index) => {
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

const _library = EmbyItem(
  id: 'library-1',
  name: '电影',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _allCategorySettings = LibraryCategorySettings(
  showMovies: true,
  showSeries: true,
  showVideos: true,
  showFavorites: true,
  showFolders: true,
);
