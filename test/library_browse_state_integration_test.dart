import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('raw cursor advances before duplicate and invalid item removal', (
    tester,
  ) async {
    _setCompactView(tester);
    final starts = <int>[];
    final api = _rawPagingApi(starts);

    await tester.pumpWidget(_rootApp(api));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-duplicate-0')),
      400,
      scrollable: _verticalScrollable(),
    );
    expect(
      find.byKey(const ValueKey('library-item-duplicate-0')),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-duplicate-17')),
      600,
      scrollable: _verticalScrollable(),
    );
    await tester.pumpAndSettle();

    expect(starts, [0, 60]);
    expect(
      find.byKey(const ValueKey('library-item-duplicate-17')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-next-0')),
      400,
      scrollable: _verticalScrollable(),
    );
    expect(find.byKey(const ValueKey('library-item-next-0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('an empty raw page stops pagination even with a larger total', (
    tester,
  ) async {
    final api = _EmptyPageApi();
    await tester.pumpWidget(_rootApp(api));
    await tester.pumpAndSettle();

    expect(api.calls, 1);
    expect(find.text('这个媒体库是空的'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(api.calls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('a stale generation cannot replace the latest scope result', (
    tester,
  ) async {
    final api = _StaleGenerationApi();
    await tester.pumpWidget(_rootApp(api));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-item-favorite')), findsOneWidget);

    api.initial.complete(_page([_item('stale')]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-item-favorite')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-item-stale')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets(
    'favorites survive media, played and local filters while selected controls are no-ops',
    (tester) async {
      final api = _StateRecordingApi();
      await tester.pumpWidget(
        _rootApp(api, categorySettings: _allCategorySettings),
      );
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('library-section-media')));
      await tester.tap(find.byKey(const ValueKey('library-media-type-all')));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('library-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-filter-all')));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));

      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      final allPlayed = find.descendant(
        of: find.byType(SegmentedButton<LibraryPlayedFilter>),
        matching: find.text('全部'),
      );
      await tester.tap(allPlayed);
      await tester.tap(find.text('查看结果'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-media-type-movie')));
      await tester.pumpAndSettle();
      expect(api.requests.last.favorites, isTrue);
      expect(api.requests.last.mediaType, LibraryMediaType.movie);

      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('未播放'));
      await tester.tap(find.text('查看结果'));
      await tester.pumpAndSettle();
      expect(api.requests.last.favorites, isTrue);
      expect(api.requests.last.mediaType, LibraryMediaType.movie);
      expect(api.requests.last.playedFilter, LibraryPlayedFilter.unplayed);

      await tester.tap(find.byKey(const ValueKey('library-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-filter-strm')));
      await tester.pumpAndSettle();
      expect(api.requests.last.favorites, isTrue);
      expect(api.requests.last.mediaType, LibraryMediaType.movie);
      expect(api.requests.last.playedFilter, LibraryPlayedFilter.unplayed);
      expect(api.requests.last.startIndex, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets('local scan failure retains matches and retries its raw cursor', (
    tester,
  ) async {
    _setCompactView(tester);
    final starts = <int>[];
    final api = _retryingLocalScanApi(starts);
    await tester.pumpWidget(_rootApp(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-strm')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-item-strm-first')),
      findsOneWidget,
    );
    final position = tester
        .state<ScrollableState>(_verticalScrollable())
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(starts, [0, 0, 60]);

    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
    final retry = find.byKey(const ValueKey('library-scan-retry'));
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(starts, [0, 0, 60, 60]);
    expect(
      find.byKey(const ValueKey('library-item-strm-first')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-item-strm-second')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('directory media open details and folders open nested identity', (
    tester,
  ) async {
    _setCompactView(tester);
    final api = _mixedDirectoryApi();
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.directory(api: api, view: _folder),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-section-bar')), findsNothing);
    for (final id in ['movie', 'series', 'episode', 'video']) {
      await tester.tap(find.byKey(ValueKey('library-group-$id')));
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('library-group-$id')), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('library-group-child-folder')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '子目录'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-section-bar')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets(
    'facet identity hides root scope controls and keeps media tools',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _simpleDioApi(requests);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryBrowseScreen.facet(
            api: api,
            view: _library,
            facet: const LibraryFacet(
              id: 'genre-1',
              name: '动作',
              kind: LibraryFacetKind.genre,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '动作'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-section-bar')), findsNothing);
      expect(find.text('媒体类型'), findsOneWidget);
      expect(requests.single.queryParameters['GenreIds'], 'genre-1');

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets('library failures expose only fixed UI text', (tester) async {
    final api = _FailingLibraryApi();
    await tester.pumpWidget(_rootApp(api));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-load-error')), findsOneWidget);
    expect(find.text('加载失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-token'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  for (final entry in const [
    (Size(390, 844), 1.0),
    (Size(390, 520), 2.0),
    (Size(844, 390), 1.3),
  ]) {
    testWidgets(
      'root controls fit ${entry.$1.width}x${entry.$1.height} at ${entry.$2}x text',
      (tester) async {
        tester.view.physicalSize = entry.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _StateRecordingApi();

        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(entry.$2)),
            child: _rootApp(api, categorySettings: _allCategorySettings),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('library-section-bar')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-action-bar')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await api.dispose();
      },
    );
  }
}

Widget _rootApp(
  EmbyApi api, {
  LibraryCategorySettings categorySettings = const LibraryCategorySettings(),
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: LibraryBrowseScreen.root(
    api: api,
    view: _library,
    categorySettings: categorySettings,
  ),
);

void _setCompactView(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

EmbyApi _rawPagingApi(List<int> starts) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final start = options.queryParameters['StartIndex'] as int;
          starts.add(start);
          final rawItems = start == 0
              ? <dynamic>[
                  for (var id = 0; id < 18; id++)
                    for (var copy = 0; copy < 3; copy++)
                      _itemJson('duplicate-$id'),
                  _itemJson(''),
                  _itemJson(''),
                  _itemJson(''),
                  'invalid',
                  'invalid',
                  'invalid',
                ]
              : <dynamic>[
                  for (var id = 0; id < 10; id++) _itemJson('next-$id'),
                ];
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {'TotalRecordCount': 70, 'Items': rawItems},
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

class _EmptyPageApi extends EmbyApi {
  _EmptyPageApi() : super(_session, dio: Dio());

  int calls = 0;

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryMediaType mediaType = LibraryMediaType.all,
    LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
    bool favorites = false,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) async {
    calls++;
    return const EmbyItemPage(items: [], totalRecordCount: 10, rawItemCount: 0);
  }
}

class _StaleGenerationApi extends EmbyApi {
  _StaleGenerationApi() : super(_session, dio: Dio());

  final initial = Completer<EmbyItemPage>();

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryMediaType mediaType = LibraryMediaType.all,
    LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
    bool favorites = false,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) => favorites ? Future.value(_page([_item('favorite')])) : initial.future;
}

class _RecordedLibraryRequest {
  const _RecordedLibraryRequest({
    required this.startIndex,
    required this.mediaType,
    required this.playedFilter,
    required this.favorites,
  });

  final int startIndex;
  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
  final bool favorites;
}

class _StateRecordingApi extends EmbyApi {
  _StateRecordingApi() : super(_session, dio: Dio());

  final List<_RecordedLibraryRequest> requests = [];

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryMediaType mediaType = LibraryMediaType.all,
    LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
    bool favorites = false,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) async {
    requests.add(
      _RecordedLibraryRequest(
        startIndex: startIndex,
        mediaType: mediaType,
        playedFilter: playedFilter,
        favorites: favorites,
      ),
    );
    return _page([_item('state-${requests.length}', isStrm: true)]);
  }
}

EmbyApi _retryingLocalScanApi(List<int> starts) {
  var call = 0;
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          call++;
          final start = options.queryParameters['StartIndex'] as int;
          starts.add(start);
          if (call == 3) {
            handler.reject(
              DioException.badResponse(
                statusCode: 500,
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 500,
                ),
              ),
            );
            return;
          }
          final items = switch (call) {
            1 => [for (var id = 0; id < 60; id++) _itemJson('initial-$id')],
            2 => [
              _itemJson('strm-first', isStrm: true),
              for (var id = 1; id < 60; id++) _itemJson('scan-a-$id'),
            ],
            _ => [
              _itemJson('strm-second', isStrm: true),
              for (var id = 1; id < 60; id++) _itemJson('scan-b-$id'),
            ],
          };
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {'TotalRecordCount': 120, 'Items': items},
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

EmbyApi _mixedDirectoryApi() {
  final items = [
    _itemJson('child-folder', type: 'Folder', name: '子目录'),
    _itemJson('movie', type: 'Movie'),
    _itemJson('series', type: 'Series'),
    _itemJson('episode', type: 'Episode'),
    _itemJson('video', type: 'Video'),
  ];
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.queryParameters['Ids'] case final String ids) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'Items': [items.firstWhere((item) => item['Id'] == ids)],
                },
              ),
            );
            return;
          }
          final detail = RegExp(
            r'^/Users/user-1/Items/([^/]+)$',
          ).firstMatch(options.path);
          if (detail != null) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: items.firstWhere((item) => item['Id'] == detail.group(1)),
              ),
            );
            return;
          }
          final parentId = options.queryParameters['ParentId'];
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'TotalRecordCount': parentId == _folder.id ? items.length : 0,
                'Items': parentId == _folder.id ? items : const [],
              },
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

EmbyApi _simpleDioApi(List<RequestOptions> requests) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'TotalRecordCount': 1,
                'Items': [_itemJson('facet-media')],
              },
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

class _FailingLibraryApi extends EmbyApi {
  _FailingLibraryApi() : super(_session, dio: Dio());

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryMediaType mediaType = LibraryMediaType.all,
    LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
    bool favorites = false,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) => Future.error(StateError('private-token raw failure'));
}

EmbyItemPage _page(List<EmbyItem> items) => EmbyItemPage(
  items: items,
  totalRecordCount: items.length,
  rawItemCount: items.length,
);

EmbyItem _item(String id, {bool isStrm = false}) =>
    EmbyItem.fromJson(_itemJson(id, isStrm: isStrm));

Map<String, dynamic> _itemJson(
  String id, {
  String type = 'Movie',
  String? name,
  bool isStrm = false,
}) => {
  'Id': id,
  'Name': name ?? id,
  'Type': type,
  'MediaType': switch (type) {
    'Movie' || 'Episode' || 'Video' => 'Video',
    _ => null,
  },
  'Path': isStrm ? '/media/$id.strm' : '/media/$id.mkv',
  'Container': isStrm ? 'strm' : 'mkv',
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

const _folder = EmbyItem(
  id: 'folder-1',
  name: '目录',
  type: 'Folder',
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
