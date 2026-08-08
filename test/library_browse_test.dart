import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes library browse scopes without overlapping state', () {
    final overlapping = LibraryBrowseState(
      scope: LibraryBrowseScope.directory,
      mediaType: LibraryMediaType.movie,
      playedFilter: LibraryPlayedFilter.unplayed,
      localFilter: LibraryLocalMediaFilter.strm,
      alphabetFilter: LetterItems('m'),
    );
    final directory = normalizeLibraryBrowseState(overlapping);
    expect(directory.scope, LibraryBrowseScope.directory);
    expect(directory.mediaType, LibraryMediaType.all);
    expect(directory.playedFilter, LibraryPlayedFilter.all);
    expect(directory.localFilter, LibraryLocalMediaFilter.all);
    expect(directory.alphabetFilter.isAll, isTrue);

    final media = reduceLibraryBrowseState(
      directory,
      const LibraryScopeSelected(LibraryBrowseScope.media),
    );
    expect(media, const LibraryBrowseState());

    const filteredMedia = LibraryBrowseState(mediaType: LibraryMediaType.movie);
    final favorites = reduceLibraryBrowseState(
      filteredMedia,
      const LibraryScopeSelected(LibraryBrowseScope.favorites),
    );
    expect(favorites.scope, LibraryBrowseScope.favorites);
    expect(favorites.mediaType, LibraryMediaType.movie);
  });

  test(
    'combines favorite and played filters in one server filter value',
    () async {
      RequestOptions? captured;
      final api = _api((options, handler) {
        captured = options;
        handler.resolve(_libraryResponse(options));
      });

      await api.getLibraryMediaItems(
        parentId: 'library-1',
        favorites: true,
        playedFilter: LibraryPlayedFilter.unplayed,
      );

      expect(captured?.queryParameters['Filters'], 'IsFavorite,IsUnplayed');
      expect(captured?.queryParameters, isNot(contains('IsFavorite')));
    },
  );

  test('filter badge excludes the visible media type choice', () {
    const all = LibraryBrowseState();
    expect(all.activeFilterCount, 0);
    expect(
      all.copyWith(mediaType: LibraryMediaType.movie).activeFilterCount,
      0,
    );
    expect(
      all
          .copyWith(
            mediaType: LibraryMediaType.movie,
            playedFilter: LibraryPlayedFilter.unplayed,
          )
          .activeFilterCount,
      1,
    );
  });

  test('library browse sends server-side sort and filter parameters', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_libraryResponse(options));
    });

    final page = await api.getLibraryMediaItems(
      parentId: 'library-1',
      startIndex: 60,
      limit: 30,
      sortBy: LibrarySortBy.dateAdded,
      sortOrder: LibrarySortOrder.descending,
      playedFilter: LibraryPlayedFilter.unplayed,
      mediaType: LibraryMediaType.movie,
      favorites: true,
    );

    expect(page.totalRecordCount, 116);
    expect(page.items.single.id, 'movie-1');
    expect(captured?.path, '/Users/user-1/Items');
    expect(captured?.queryParameters, containsPair('ParentId', 'library-1'));
    expect(captured?.queryParameters, containsPair('StartIndex', 60));
    expect(captured?.queryParameters, containsPair('Limit', 30));
    expect(captured?.queryParameters, containsPair('SortBy', 'DateCreated'));
    expect(captured?.queryParameters, containsPair('SortOrder', 'Descending'));
    expect(
      captured?.queryParameters,
      containsPair('Filters', 'IsFavorite,IsUnplayed'),
    );
    expect(
      captured?.queryParameters,
      containsPair('IncludeItemTypes', 'Movie'),
    );
    expect(captured?.queryParameters, isNot(contains('IsFavorite')));
    expect(
      captured?.queryParameters,
      containsPair('EnableTotalRecordCount', true),
    );
    expect(captured?.queryParameters, isNot(contains('NameStartsWith')));
    expect(captured?.queryParameters, isNot(contains('NameLessThan')));
  });

  test(
    'library alphabet parameters are normalized and mutually exclusive',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_libraryResponse(options));
      });

      await api.getLibraryMediaItems(
        parentId: 'library-1',
        alphabetFilter: LetterItems('m'),
      );
      await api.getLibraryMediaItems(
        parentId: 'library-1',
        alphabetFilter: const SymbolsItems(),
      );
      await api.getLibraryMediaItems(
        parentId: 'library-1',
        alphabetFilter: LetterItems('q'),
      );

      expect(requests.first.queryParameters['NameStartsWith'], 'M');
      expect(requests.first.queryParameters, isNot(contains('NameLessThan')));
      expect(requests[1].queryParameters['NameLessThan'], 'A');
      expect(requests[1].queryParameters, isNot(contains('NameStartsWith')));
      expect(requests[2].queryParameters['NameStartsWith'], 'Q');
      expect(requests, hasLength(3));
    },
  );

  test('folder browsing requests only the current directory level', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_libraryResponse(options));
    });

    await api.getDirectoryChildren(parentId: 'library-1');

    expect(captured?.queryParameters['Recursive'], false);
    expect(
      captured?.queryParameters['IncludeItemTypes'],
      'Folder,CollectionFolder,Movie,Series,Episode,Video',
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
        home: LibraryBrowseScreen.root(
          api: api,
          view: _library,
          categorySettings: _allCategorySettings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('共 116 项'), findsOneWidget);
    expect(find.text('媒体类型'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-media-type-all')),
      findsOneWidget,
    );
    final movieQuickFilter = find.descendant(
      of: find.byType(ChoiceChip),
      matching: find.text('电影'),
    );
    expect(movieQuickFilter, findsOneWidget);
    expect(find.byTooltip('排序方式'), findsOneWidget);
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-section-directories')),
      findsOneWidget,
    );

    await tester.tap(movieQuickFilter);
    await tester.pumpAndSettle();
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      LibraryMediaType.movie.apiValue,
    );

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    expect(find.text('播放状态'), findsOneWidget);
    expect(find.text('项目类型'), findsNothing);
    expect(find.text('只看收藏'), findsNothing);

    await tester.tap(find.text('未播放'));
    await tester.tap(find.text('查看结果'));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['Filters'], 'IsUnplayed');
    expect(requests.last.queryParameters['IncludeItemTypes'], 'Movie');
    expect(requests.last.queryParameters, isNot(contains('IsFavorite')));
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
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    expect(_quickCategory('全部'), findsOneWidget);
    expect(_quickCategory('电影'), findsNothing);
    expect(_quickCategory('剧集'), findsNothing);
    expect(_quickCategory('视频'), findsNothing);
    expect(_quickCategory('收藏'), findsNothing);
    expect(_quickCategory('文件夹'), findsNothing);
    expect(
      find.byKey(const ValueKey('library-section-favorites')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-section-directories')),
      findsOneWidget,
    );
  });

  testWidgets('reset returns from favorites to the media default', (
    tester,
  ) async {
    final api = _api((options, handler) {
      handler.resolve(_libraryResponse(options));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen.root(
          api: api,
          view: _library,
          categorySettings: _allCategorySettings,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-more-reset')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('library-section-media')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.descendant(
              of: find.byKey(const ValueKey('library-media-type-all')),
              matching: find.byType(ChoiceChip),
            ),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('library-section-favorites')),
          )
          .selected,
      isFalse,
    );
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
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    final folderCategory = find.byKey(
      const ValueKey('library-section-directories'),
    );
    await tester.tap(folderCategory);
    await tester.pumpAndSettle();

    expect(find.text('目录 A'), findsOneWidget);
    expect(requests.last.queryParameters['Recursive'], false);
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      'Folder,CollectionFolder,Movie,Series,Episode,Video',
    );

    await tester.tap(find.text('目录 A'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '目录 A'), findsOneWidget);
    expect(requests.last.queryParameters['ParentId'], 'folder-1');
    expect(requests.last.queryParameters['Recursive'], false);
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      'Folder,CollectionFolder,Movie,Series,Episode,Video',
    );
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
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = _verticalScrollable();
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

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, closeTo(before, 1));
    expect(browseStarts, [0, 60]);
    expect(refreshedItemId, 'item-70');
  });
}

Finder _quickCategory(String label) =>
    find.descendant(of: find.byType(ChoiceChip), matching: find.text(label));

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable &&
      (widget.axisDirection == AxisDirection.down ||
          widget.axisDirection == AxisDirection.up),
);

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
      query['IncludeItemTypes'] ==
      'Folder,CollectionFolder,Movie,Series,Episode,Video';
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
