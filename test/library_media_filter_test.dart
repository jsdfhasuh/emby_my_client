import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('filters STRM and regular media across server pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final requests = <RequestOptions>[];
    final api = _api(requests);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-item-regular-0')),
      findsOneWidget,
    );
    const actionButtonKeys = [
      'library-play-all-button',
      'library-shuffle-button',
      'library-sort-button',
      'library-filter-button',
      'library-more-button',
    ];
    for (final key in actionButtonKeys) {
      final finder = find.byKey(ValueKey(key));
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(393));
    }
    expect(tester.takeException(), isNull);
    expect(
      requests.single.queryParameters['Fields'],
      allOf(contains('Path'), contains('Container'), contains('MediaSources')),
    );

    await tester.tap(find.byKey(const ValueKey('library-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-strm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-item-strm-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-item-regular-0')), findsNothing);
    expect(requests, hasLength(2));
    expect(requests.last.queryParameters['StartIndex'], 60);

    await tester.tap(find.byKey(const ValueKey('library-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-regular')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-item-regular-0')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library-item-strm-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('library-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('library-sort-dateAddedDescending')),
    );
    await tester.pumpAndSettle();

    expect(requests, hasLength(3));
    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters['SortBy'], 'DateCreated');
    expect(requests.last.queryParameters['SortOrder'], 'Descending');
    expect(
      find.byKey(const ValueKey('library-item-regular-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('library-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-more-reset')));
    await tester.pumpAndSettle();

    expect(requests, hasLength(4));
    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters['SortBy'], 'SortName');
    expect(requests.last.queryParameters['SortOrder'], 'Ascending');
    expect(find.byKey(const ValueKey('library-item-strm-1')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('browses folders, categories, tags and favorites', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final requests = <RequestOptions>[];
    final api = _sectionApi(requests);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    for (final section in [
      'videos',
      'folders',
      'genres',
      'tags',
      'favorites',
    ]) {
      expect(find.byKey(ValueKey('library-section-$section')), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('library-section-folders')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-group-folder-1')),
      findsOneWidget,
    );
    expect(requests.last.queryParameters['Recursive'], isFalse);
    expect(requests.last.queryParameters['IncludeItemTypes'], 'Folder');

    await tester.tap(find.byKey(const ValueKey('library-section-genres')));
    await tester.pumpAndSettle();
    expect(requests.last.path, '/Genres');
    expect(find.byKey(const ValueKey('library-group-genre-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-group-genre-1')));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['GenreIds'], 'genre-1');
    expect(
      find.byKey(const ValueKey('library-item-genre-media')),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-section-tags')));
    await tester.pumpAndSettle();
    expect(requests.last.path, '/Tags');
    expect(find.byKey(const ValueKey('library-group-tag-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-group-tag-1')));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['TagIds'], 'tag-1');
    expect(
      find.byKey(const ValueKey('library-item-tag-media')),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    final sectionScroller = find.descendant(
      of: find.byKey(const ValueKey('library-section-bar')),
      matching: find.byType(SingleChildScrollView),
    );
    await tester.drag(sectionScroller, const Offset(-180, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['Filters'], 'IsFavorite');
    expect(
      find.byKey(const ValueKey('library-item-favorite-media')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets(
    'returning from a deeply scrolled folder does not reload the listing',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final browseStarts = <int>[];
      final detailRequests = <String>[];
      final api = _pagedApi(
        browseStarts: browseStarts,
        detailRequests: detailRequests,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryBrowseScreen(api: api, view: _folder),
        ),
      );
      await tester.pumpAndSettle();

      final verticalScrollable = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      );
      expect(verticalScrollable, findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-item-item-70')),
        700,
        scrollable: verticalScrollable,
      );
      await tester.pumpAndSettle();
      final before = tester
          .state<ScrollableState>(verticalScrollable)
          .position
          .pixels;

      await tester.tap(find.byKey(const ValueKey('library-item-item-70')));
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      final after = tester
          .state<ScrollableState>(verticalScrollable)
          .position
          .pixels;
      expect(after, closeTo(before, 1));
      expect(browseStarts, [0, 60]);
      expect(detailRequests, ['item-70']);
      expect(
        find.byKey(const ValueKey('library-item-item-70')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );
}

EmbyApi _api(List<RequestOptions> requests) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final startIndex = options.queryParameters['StartIndex'] as int? ?? 0;
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'Items': startIndex == 0
                    ? List.generate(
                        60,
                        (index) => {
                          'Id': 'regular-$index',
                          'Name': '普通媒体 $index',
                          'Type': 'Movie',
                          'Path': '/media/movie-$index.mkv',
                          'Container': 'mkv',
                        },
                      )
                    : [
                        {
                          'Id': 'strm-1',
                          'Name': 'STRM 媒体',
                          'Type': 'Movie',
                          'Path': r'D:\Media\Remote.STRM',
                        },
                      ],
              },
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

EmbyApi _sectionApi(List<RequestOptions> requests) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final query = options.queryParameters;
          final items = switch (options.path) {
            '/Genres' => [
              {'Id': 'genre-1', 'Name': '动作', 'Type': 'Genre'},
            ],
            '/Tags' => [
              {'Id': 'tag-1', 'Name': '高码率', 'Type': 'Tag'},
            ],
            _ when query['IncludeItemTypes'] == 'Folder' => [
              {'Id': 'folder-1', 'Name': '电影目录', 'Type': 'Folder'},
            ],
            _ when query['GenreIds'] == 'genre-1' => [
              {'Id': 'genre-media', 'Name': '动作电影', 'Type': 'Movie'},
            ],
            _ when query['TagIds'] == 'tag-1' => [
              {'Id': 'tag-media', 'Name': '标签电影', 'Type': 'Movie'},
            ],
            _ when query['Filters'] == 'IsFavorite' => [
              {
                'Id': 'favorite-media',
                'Name': '收藏电影',
                'Type': 'Movie',
                'UserData': {'IsFavorite': true},
              },
            ],
            _ => [
              {'Id': 'video-1', 'Name': '影片', 'Type': 'Movie'},
            ],
          };
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {'Items': items},
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

EmbyApi _pagedApi({
  required List<int> browseStarts,
  required List<String> detailRequests,
}) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final detailMatch = RegExp(
            r'^/Users/user-1/Items/(item-\d+)$',
          ).firstMatch(options.path);
          if (detailMatch != null) {
            final id = detailMatch.group(1)!;
            detailRequests.add(id);
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
            final id = ids.split(',').first;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'Items': [_pagedItem(int.parse(id.split('-').last))],
                },
              ),
            );
            return;
          }
          final startIndex = options.queryParameters['StartIndex'] as int? ?? 0;
          browseStarts.add(startIndex);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'Items': [
                  for (
                    var index = startIndex;
                    index < (startIndex + 60).clamp(0, 120);
                    index++
                  )
                    _pagedItem(index),
                ],
              },
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

Map<String, dynamic> _pagedItem(int index) => {
  'Id': 'item-$index',
  'Name': '影片 $index',
  'Type': 'Video',
  'MediaType': 'Video',
  'ImageTags': const <String, String>{},
  'BackdropImageTags': const <String>[],
  'Genres': const <String>[],
  'UserData': const <String, dynamic>{},
};

const _library = EmbyItem(
  id: 'movies',
  name: '电影',
  type: 'CollectionFolder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _folder = EmbyItem(
  id: 'folder-1',
  name: '电影目录',
  type: 'Folder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
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
