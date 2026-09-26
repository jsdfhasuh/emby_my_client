import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_pagination_strategy.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_sequence_source.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/photos/photo_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_filter_test_helpers.dart';

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
      'Folder,CollectionFolder,PhotoAlbum,Movie,Series,Episode,Video,Photo',
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
    expect(find.text('媒体类型'), findsNothing);
    expect(find.byKey(const ValueKey('library-media-type-all')), findsNothing);
    expect(find.byTooltip('排序方式'), findsOneWidget);
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-section-directories')),
      findsOneWidget,
    );

    final requestCount = requests.length;
    await openLibraryFilter(tester);
    expect(find.text('媒体类型'), findsOneWidget);
    expect(find.text('播放状态'), findsOneWidget);
    expect(find.text('项目类型'), findsNothing);
    expect(find.text('只看收藏'), findsNothing);

    await selectLibraryMediaType(tester, 'movie');
    await selectLibraryPlayedFilter(tester, 'unplayed');
    expect(requests, hasLength(requestCount));
    await applyLibraryFilter(tester);

    expect(requests, hasLength(requestCount + 1));
    expect(requests.last.queryParameters['Filters'], 'IsUnplayed');
    expect(requests.last.queryParameters['IncludeItemTypes'], 'Movie');
    expect(requests.last.queryParameters, isNot(contains('IsFavorite')));
  });

  testWidgets(
    'play count sorting preserves direction and restores alphabet navigation',
    (tester) async {
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
      expect(
        find.byKey(const ValueKey('library-alphabet-navigation')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('library-sort-direction-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-alphabet-navigation')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('library-sort-button')));
      await tester.pumpAndSettle();
      expect(find.text('播放次数'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-sort-playCount')));
      await tester.pumpAndSettle();

      expect(requests.last.queryParameters['SortBy'], 'PlayCount');
      expect(requests.last.queryParameters['SortOrder'], 'Descending');
      expect(requests.last.queryParameters['EnableUserData'], isTrue);
      expect(
        find.byKey(const ValueKey('library-alphabet-navigation')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('library-sort-direction-button')),
      );
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['SortBy'], 'PlayCount');
      expect(requests.last.queryParameters['SortOrder'], 'Ascending');
      expect(
        find.byKey(const ValueKey('library-alphabet-navigation')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('library-sort-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-sort-name')));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['SortBy'], 'SortName');
      expect(requests.last.queryParameters['SortOrder'], 'Ascending');
      expect(
        find.byKey(const ValueKey('library-alphabet-navigation')),
        findsOneWidget,
      );
    },
  );

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

    expect(find.text('媒体类型'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
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
          .widget<FilterChip>(
            find.byKey(const ValueKey('library-section-favorites')),
          )
          .selected,
      isFalse,
    );
    await openLibraryFilter(tester);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('library-media-type-all')),
          )
          .selected,
      isTrue,
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
      'Folder,CollectionFolder,PhotoAlbum,Movie,Series,Episode,Video,Photo',
    );

    await tester.tap(find.text('目录 A'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '目录 A'), findsOneWidget);
    expect(requests.last.queryParameters['ParentId'], 'folder-1');
    expect(requests.last.queryParameters['Recursive'], false);
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      'Folder,CollectionFolder,PhotoAlbum,Movie,Series,Episode,Video,Photo',
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

  testWidgets('mixed library photo opens the viewer with a photo-aware query', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 2,
            'Items': [
              {
                'Id': 'video-1',
                'Name': '媒体库视频',
                'Type': 'Video',
                'MediaType': 'Video',
                'ImageTags': const <String, String>{},
                'UserData': const <String, dynamic>{},
              },
              {
                'Id': 'photo-1',
                'Name': '媒体库图片',
                'Type': 'Photo',
                'ImageTags': const <String, String>{},
                'UserData': const <String, dynamic>{},
              },
            ],
          },
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen.root(api: api, view: _homeVideoLibrary),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      requests.first.queryParameters['IncludeItemTypes'],
      'Movie,Video,Photo',
    );
    await tester.tap(find.text('媒体库图片'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    final viewer = tester.widget<PhotoViewerScreen>(
      find.byType(PhotoViewerScreen),
    );
    expect(viewer.source.mode, MediaViewerMode.homeMedia);
    expect(viewer.source.initialItems.map((item) => item.id), [
      'video-1',
      'photo-1',
    ]);
  });

  testWidgets(
    'viewer alone loads page 60 and restores media 70 into the library',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 4200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final browseStarts = <int>[];
      final api = _api((options, handler) {
        final start = options.queryParameters['StartIndex'] as int;
        browseStarts.add(start);
        handler.resolve(_homeMediaPageResponse(options));
      });
      addTearDown(api.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: LibraryBrowseScreen.root(api: api, view: _homeVideoLibrary),
        ),
      );
      await tester.pumpAndSettle();

      expect(browseStarts, [0]);
      expect(find.text('家庭图片 55'), findsOneWidget);
      final scrollable = _verticalScrollable();
      const targetKey = ValueKey('library-item-home-item-70');
      expect(find.byKey(targetKey), findsNothing);

      await tester.tap(find.text('家庭图片 55'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewerScreen), findsOneWidget);
      final viewer = tester.widget<PhotoViewerScreen>(
        find.byType(PhotoViewerScreen),
      );
      expect(viewer.source.initialItems, hasLength(60));
      expect(viewer.source.initialRawCursor, 60);
      expect(viewer.source.initialHasMore, isTrue);
      expect(browseStarts, [0, 60]);

      tester.view.physicalSize = const Size(1024, 768);
      await tester.pump();

      for (var index = 0; index < 15; index++) {
        await tester.drag(find.byType(PageView), const Offset(-600, 0));
        await tester.pumpAndSettle();
      }
      expect(find.text('家庭图片 70'), findsOneWidget);
      expect(find.text('71 / 120+'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _pumpFixedFrames(tester);

      expect(find.byType(PhotoViewerScreen), findsNothing);
      final debugState =
          tester.state(find.byType(LibraryBrowseScreen))
              as LibraryBrowseDebugState;
      expect(debugState.debugLoadedItemIds, hasLength(120));
      expect(debugState.debugLoadedItemIds.toSet(), hasLength(120));
      expect(debugState.debugNextStartIndex, 120);
      expect(debugState.debugTotalCount, 180);
      expect(debugState.debugTotalDirty, isFalse);
      expect(debugState.debugHasMore, isTrue);
      expect(debugState.debugLoadFailed, isFalse);
      final target = find.byKey(targetKey);
      expect(target, findsOneWidget);
      final targetRect = tester.getRect(target);
      expect(targetRect.overlaps(tester.getRect(scrollable)), isTrue);

      await tester.scrollUntilVisible(
        find.text('家庭图片 110'),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(browseStarts, [0, 60, 120]);
      expect(
        find.byKey(const ValueKey('library-item-home-item-110')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'identity viewer result replaces membership and restores its final media ID',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _api((options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: {
              'TotalRecordCount': 60,
              'Items': [
                for (var index = 0; index < 60; index++)
                  {
                    'Id': 'identity-item-$index',
                    'Name': '身份图片 $index',
                    'Type': 'Photo',
                    'ImageTags': const <String, String>{},
                    'BackdropImageTags': const <String>[],
                    'Genres': const <String>[],
                    'UserData': const <String, dynamic>{},
                  },
              ],
            },
          ),
        );
      });
      addTearDown(api.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: LibraryBrowseScreen.root(
            api: api,
            view: _homeVideoLibrary,
            initialState: const LibraryBrowseState(
              sortBy: LibrarySortBy.playCount,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('身份图片 5'));
      await tester.pumpAndSettle();

      final viewer = tester.widget<PhotoViewerScreen>(
        find.byType(PhotoViewerScreen),
      );
      expect(
        viewer.source.paginationStrategy,
        LibraryPaginationStrategy.identityRescan,
      );
      final target = viewer.source.initialItems.singleWhere(
        (item) => item.id == 'identity-item-55',
      );
      final rescannedItems = [
        ...viewer.source.initialItems.where(
          (item) => item.id != 'identity-item-0' && item.id != target.id,
        ),
        target,
      ];
      Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop(
        MediaViewerResult(
          queryFingerprint: viewer.source.queryFingerprint,
          rawItems: rescannedItems,
          currentItemId: target.id,
          nextStartIndex: 59,
          totalCount: 59,
          totalDirty: true,
          hasMore: false,
          paginationStrategy: LibraryPaginationStrategy.identityRescan,
        ),
      );
      await _pumpFixedFrames(tester);

      final state =
          tester.state(find.byType(LibraryBrowseScreen))
              as LibraryBrowseDebugState;
      expect(state.debugLoadedItemIds, rescannedItems.map((item) => item.id));
      expect(state.debugLoadedItemIds, isNot(contains('identity-item-0')));
      expect(state.debugLoadedItemIds.last, target.id);
      expect(state.debugNextStartIndex, 59);
      expect(state.debugTotalCount, 59);
      expect(state.debugTotalDirty, isTrue);
      expect(state.debugHasMore, isFalse);
      final targetFinder = find.byKey(
        const ValueKey('library-item-identity-item-55'),
      );
      expect(targetFinder, findsOneWidget);
      expect(
        tester
            .getRect(targetFinder)
            .overlaps(tester.getRect(_verticalScrollable())),
        isTrue,
      );
    },
  );

  for (final delayedPageFails in [false, true]) {
    testWidgets(
      'late library page ${delayedPageFails ? 'failure' : 'response'} does not regress merged viewer state',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (_) async => null,
        );
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final browseStarts = <int>[];
        RequestOptions? delayedPageOptions;
        RequestInterceptorHandler? delayedPageHandler;
        var pageSixtyRequests = 0;
        final api = _api((options, handler) {
          final start = options.queryParameters['StartIndex'] as int;
          browseStarts.add(start);
          if (start == 60 && pageSixtyRequests++ == 0) {
            delayedPageOptions = options;
            delayedPageHandler = handler;
            return;
          }
          handler.resolve(_homeMediaPageResponse(options));
        });
        addTearDown(api.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: LibraryBrowseScreen.root(api: api, view: _homeVideoLibrary),
          ),
        );
        await tester.pumpAndSettle();

        final scrollable = _verticalScrollable();
        await tester.scrollUntilVisible(
          find.text('家庭图片 55'),
          700,
          scrollable: scrollable,
        );
        await _pumpFixedFrames(tester);
        expect(browseStarts, [0, 60]);

        await tester.tap(find.text('家庭图片 55'));
        await tester.pumpAndSettle();
        expect(browseStarts, [0, 60, 60]);
        for (var index = 0; index < 15; index++) {
          await tester.drag(find.byType(PageView), const Offset(-600, 0));
          await tester.pumpAndSettle();
        }
        expect(find.text('家庭图片 70'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await _pumpFixedFrames(tester);
        var debugState =
            tester.state(find.byType(LibraryBrowseScreen))
                as LibraryBrowseDebugState;
        expect(debugState.debugLoadedItemIds, hasLength(120));
        expect(debugState.debugNextStartIndex, 120);
        expect(debugState.debugLoading, isTrue);

        if (delayedPageFails) {
          delayedPageHandler!.reject(
            DioException(
              requestOptions: delayedPageOptions!,
              type: DioExceptionType.connectionError,
              error: 'delayed page failed',
            ),
          );
        } else {
          delayedPageHandler!.resolve(
            _homeMediaPageResponse(delayedPageOptions!, staleLastItem: true),
          );
        }
        await tester.pumpAndSettle();

        debugState =
            tester.state(find.byType(LibraryBrowseScreen))
                as LibraryBrowseDebugState;
        expect(debugState.debugLoadedItemIds, hasLength(120));
        expect(debugState.debugLoadedItemIds.toSet(), hasLength(120));
        expect(
          debugState.debugLoadedItemIds,
          isNot(contains('stale-delayed-home-item')),
        );
        expect(debugState.debugNextStartIndex, 120);
        expect(debugState.debugTotalCount, 180);
        expect(debugState.debugTotalDirty, isFalse);
        expect(debugState.debugHasMore, isTrue);
        expect(debugState.debugLoadFailed, isFalse);
        expect(debugState.debugLoading, isFalse);
        expect(
          find.byKey(const ValueKey('library-item-home-item-70')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('query generation change rejects a stale viewer snapshot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic> responseItem(int index) => {
      'Id': 'stable-item-$index',
      'Name': '稳定图片 $index',
      'Type': 'Photo',
      'ImageTags': const <String, String>{},
      'BackdropImageTags': const <String>[],
      'Genres': const <String>[],
      'UserData': const <String, dynamic>{},
    };
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 60,
            'Items': [
              for (var index = 0; index < 60; index++) responseItem(index),
            ],
          },
        ),
      );
    });
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen.root(api: api, view: _homeVideoLibrary),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('稳定图片 5'));
    await tester.pumpAndSettle();
    final viewer = tester.widget<PhotoViewerScreen>(
      find.byType(PhotoViewerScreen),
    );
    const staleItem = EmbyItem(
      id: 'viewer-only-stale',
      name: '陈旧查看器项目',
      type: 'Photo',
      imageTags: {},
      backdropImageTags: [],
      genres: [],
      userData: EmbyUserData(),
    );
    final staleResult = MediaViewerResult(
      queryFingerprint: viewer.source.queryFingerprint,
      rawItems: [...viewer.source.initialItems, staleItem],
      currentItemId: staleItem.id,
      nextStartIndex: 61,
      totalCount: 61,
      totalDirty: false,
      hasMore: false,
    );

    final libraryState =
        tester.state(find.byType(LibraryBrowseScreen, skipOffstage: false))
            as LibraryBrowseDebugState;
    final generationBeforeRefresh = libraryState.debugGeneration;
    final fingerprintBeforeRefresh = libraryState.debugQueryFingerprint;
    final refresh = libraryState.debugRefresh();
    await _pumpFixedFrames(tester);
    await refresh;
    expect(libraryState.debugGeneration, generationBeforeRefresh + 1);
    expect(libraryState.debugQueryFingerprint, fingerprintBeforeRefresh);
    expect(viewer.source.queryFingerprint, fingerprintBeforeRefresh);
    Navigator.of(
      tester.element(find.byType(PhotoViewerScreen)),
    ).pop(staleResult);
    await tester.pumpAndSettle();

    expect(libraryState.debugLoadedItemIds, isNot(contains(staleItem.id)));
    expect(libraryState.debugNextStartIndex, 60);
    expect(libraryState.debugTotalCount, 60);
    expect(find.text('陈旧查看器项目'), findsNothing);
  });

  testWidgets('query fingerprint change rejects a stale viewer snapshot', (
    tester,
  ) async {
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 1,
            'Items': [
              {
                'Id': 'fingerprint-item',
                'Name': '指纹图片',
                'Type': 'Photo',
                'ImageTags': const <String, String>{},
                'BackdropImageTags': const <String>[],
                'Genres': const <String>[],
                'UserData': const <String, dynamic>{},
              },
            ],
          },
        ),
      );
    });
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen.root(api: api, view: _homeVideoLibrary),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('指纹图片'));
    await tester.pumpAndSettle();
    final viewer = tester.widget<PhotoViewerScreen>(
      find.byType(PhotoViewerScreen),
    );
    const staleItem = EmbyItem(
      id: 'fingerprint-stale',
      name: '错误指纹项目',
      type: 'Photo',
      imageTags: {},
      backdropImageTags: [],
      genres: [],
      userData: EmbyUserData(),
    );

    Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop(
      MediaViewerResult(
        queryFingerprint: '${viewer.source.queryFingerprint}-stale',
        rawItems: [...viewer.source.initialItems, staleItem],
        currentItemId: staleItem.id,
        nextStartIndex: 2,
        totalCount: 2,
        totalDirty: false,
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();

    final debugState =
        tester.state(find.byType(LibraryBrowseScreen))
            as LibraryBrowseDebugState;
    expect(debugState.debugLoadedItemIds, ['fingerprint-item']);
    expect(debugState.debugNextStartIndex, 1);
    expect(find.text('错误指纹项目'), findsNothing);
  });

  testWidgets('generic mixed library photo viewer remains photos-only', (
    tester,
  ) async {
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 1,
            'Items': [
              {
                'Id': 'photo-1',
                'Name': '普通混合图片',
                'Type': 'Photo',
                'ImageTags': const <String, String>{},
                'UserData': const <String, dynamic>{},
              },
            ],
          },
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen.root(api: api, view: _mixedLibrary),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通混合图片'));
    await tester.pumpAndSettle();

    final viewer = tester.widget<PhotoViewerScreen>(
      find.byType(PhotoViewerScreen),
    );
    expect(viewer.source.mode, MediaViewerMode.photosOnly);
  });
}

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable &&
      (widget.axisDirection == AxisDirection.down ||
          widget.axisDirection == AxisDirection.up),
);

Future<void> _pumpFixedFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Response<dynamic> _homeMediaPageResponse(
  RequestOptions options, {
  bool staleLastItem = false,
}) {
  final start = options.queryParameters['StartIndex'] as int;
  final limit = options.queryParameters['Limit'] as int;
  final end = (start + limit).clamp(0, 180);
  return Response<dynamic>(
    requestOptions: options,
    statusCode: 200,
    data: {
      'TotalRecordCount': 180,
      'Items': [
        for (var index = start; index < end; index++)
          {
            'Id': staleLastItem && index == end - 1
                ? 'stale-delayed-home-item'
                : 'home-item-$index',
            'Name': staleLastItem && index == end - 1
                ? '延迟过期图片'
                : '家庭图片 $index',
            'Type': 'Photo',
            'ImageTags': const <String, String>{},
            'BackdropImageTags': const <String>[],
            'Genres': const <String>[],
            'UserData': const <String, dynamic>{},
          },
      ],
    },
  );
}

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
      'Folder,CollectionFolder,PhotoAlbum,Movie,Series,Episode,Video,Photo';
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

const _homeVideoLibrary = EmbyItem(
  id: 'home-video-library',
  name: '家庭视频和照片',
  type: 'CollectionFolder',
  collectionType: 'homevideos',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _mixedLibrary = EmbyItem(
  id: 'mixed-library',
  name: '普通混合媒体',
  type: 'CollectionFolder',
  collectionType: 'mixed',
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
