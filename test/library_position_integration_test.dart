import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('small continuous scrolling reuses the grid and visible cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _pagedApi(starts: <int>[], totalCount: 120);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(_verticalScrollable())
        .position;
    position.jumpTo(300);
    await tester.pump();

    final gridFinder = find.byType(SliverGrid);
    final initialGrid = tester.widget<SliverGrid>(gridFinder);
    final initialDelegate = initialGrid.delegate;
    final initialCards = <String, MediaPosterCard>{
      for (final element in find.byType(MediaPosterCard).evaluate())
        (element.widget as MediaPosterCard).item.id:
            element.widget as MediaPosterCard,
    };
    expect(initialCards, isNotEmpty);

    for (var step = 1; step <= 8; step++) {
      position.jumpTo(300 + step * 0.5);
      await tester.pump();
      final currentGrid = tester.widget<SliverGrid>(gridFinder);
      expect(identical(currentGrid, initialGrid), isTrue);
      expect(identical(currentGrid.delegate, initialDelegate), isTrue);
      for (final entry in initialCards.entries) {
        final cardFinder = find.byKey(ValueKey('library-item-${entry.key}'));
        expect(cardFinder, findsOneWidget);
        expect(
          identical(tester.widget<MediaPosterCard>(cardFinder), entry.value),
          isTrue,
        );
      }
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('layout stays O(1) after filtering two thousand local items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final counter = _ReadCounter();
    final api = _CountingLibraryApi(itemCount: 2000, counter: counter);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-strm')));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(_verticalScrollable())
        .position;
    position.jumpTo(300);
    await tester.pump();
    final readsAfterFilterBuild = counter.reads;
    expect(readsAfterFilterBuild, greaterThanOrEqualTo(2000));

    for (var step = 1; step <= 8; step++) {
      position.jumpTo(300 + step * 0.5);
      await tester.pump();
    }
    expect(counter.reads, readsAfterFilterBuild);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets(
    'reports server position continuously across pagination and resize',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final starts = <int>[];
      final api = _pagedApi(starts: starts, totalCount: 1286);

      await tester.pumpWidget(
        MaterialApp(
          home: LibraryBrowseScreen.root(api: api, view: _library),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('共 1,286 项'), findsNothing);
      expect(_opacity(tester), 0);

      final scrollable = _verticalScrollable();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await gesture.moveBy(const Offset(0, -420));
      await tester.pump();
      expect(_opacity(tester), 1);
      expect(find.text('共 1,286 项'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('library-position-range')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacity(tester), 1);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-item-item-55')),
        900,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();

      expect(starts, containsAllInOrder([0, 60]));
      final range = _visibleRange(tester);
      expect(range.$1, greaterThan(1));
      expect(range.$2, greaterThanOrEqualTo(range.$1));
      expect(_percentage(tester), lessThan(100));
      expect(find.text('共 1,286 项'), findsOneWidget);

      tester.view.physicalSize = const Size(852, 393);
      await tester.pumpAndSettle();
      final resizedRange = _visibleRange(tester);
      expect(resizedRange.$1, greaterThan(0));
      expect(resizedRange.$2, greaterThanOrEqualTo(resizedRange.$1));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets('local media filtering never invents a total or percentage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _pagedApi(starts: <int>[], totalCount: 180, includeStrm: true);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-strm')));
    await tester.pumpAndSettle();
    await _showOverlay(tester);

    expect(
      find.byKey(const ValueKey('library-position-range')),
      findsOneWidget,
    );
    expect(find.text('共 60 项'), findsNothing);
    expect(
      find.byKey(const ValueKey('library-position-percentage')),
      findsNothing,
    );
    expect(find.text('已匹配 60 项'), findsOneWidget);
    expect(find.text('已扫描 120/180 项'), findsOneWidget);
    expect(find.text('继续统计中'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('uses filtered server totals and shows remaining items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _pagedApi(
      starts: <int>[],
      totalCount: 1286,
      totalCountForRequest: (options) =>
          options.queryParameters['Filters'] == 'IsUnplayed' ? 137 : 1286,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未播放'));
    await tester.tap(find.text('查看结果'));
    await tester.pumpAndSettle();

    expect(find.text('未播放共 137 项'), findsOneWidget);
    await _showOverlay(tester);
    expect(find.text('共 137 项'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-position-remaining')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('local media filtering shows its matched total after scanning', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _pagedApi(starts: <int>[], totalCount: 120, includeStrm: true);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-strm')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-item-118')),
      900,
      scrollable: _verticalScrollable(),
    );
    await tester.pumpAndSettle();

    tester.state<ScrollableState>(_verticalScrollable()).position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('已匹配 60 项'), findsOneWidget);
    await _showOverlay(tester);
    expect(
      find.byKey(const ValueKey('library-position-total')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('shows typed position state across media and grouping grids', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _sectionApi();

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    await _showOverlay(tester);
    expect(
      find.byKey(const ValueKey('library-position-panel')),
      findsOneWidget,
    );

    tester.state<ScrollableState>(_verticalScrollable()).position.jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('library-section-directories')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-group-folder-0')),
      findsOneWidget,
    );
    await _showOverlay(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-position-total')))
          .data,
      '目录共 60 项',
    );
    expect(
      find.byKey(const ValueKey('library-position-percentage')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-position-remaining')),
      findsNothing,
    );

    tester.state<ScrollableState>(_verticalScrollable()).position.jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('library-section-genres')));
    await tester.pumpAndSettle();
    await _showOverlay(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-position-total')))
          .data,
      '分类共 60 项',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('sorting and refreshing clear the previous position state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <RequestOptions>[];
    final api = _pagedApi(starts: <int>[], totalCount: 120, requests: requests);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    await _showOverlay(tester);
    await tester.tap(find.byKey(const ValueKey('library-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-sort-dateAdded')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('library-sort-direction-button')),
    );
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters['SortBy'], 'DateCreated');
    expect(_opacity(tester), 0);

    await _showOverlay(tester);
    final requestCount = requests.length;
    await tester.tap(find.byKey(const ValueKey('library-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-more-refresh')));
    await tester.pumpAndSettle();

    expect(requests, hasLength(requestCount + 1));
    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(_opacity(tester), 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('realtime position restoration keeps the overlay hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final socket = _FakeEmbySocket();
    final starts = <int>[];
    final api = _pagedApi(
      starts: starts,
      totalCount: 120,
      realtimeConnector: (_) async => socket,
    );
    await api.realtime.start();

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = _verticalScrollable();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-item-70')),
      700,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 180));
    expect(_opacity(tester), 0);
    final position = tester.state<ScrollableState>(scrollable).position;
    final previousOffset = position.pixels;

    socket.emitLibraryChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(starts, [0, 60, 0, 60]);
    expect(position.pixels, closeTo(previousOffset, 1));
    expect(_opacity(tester), 0);
    expect(find.byKey(const ValueKey('library-position-panel')), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await tester.pump();
    expect(_opacity(tester), 1);
    await gesture.up();

    await tester.runAsync(api.realtime.stop);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(api.dispose);
  });
}

EmbyApi _pagedApi({
  required List<int> starts,
  required int totalCount,
  int Function(RequestOptions options)? totalCountForRequest,
  bool includeStrm = false,
  List<RequestOptions>? requests,
  EmbySocketConnector? realtimeConnector,
}) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path != '/Users/user-1/Items') {
            handler.resolve(
              Response<dynamic>(requestOptions: options, statusCode: 204),
            );
            return;
          }
          requests?.add(options);
          final start = options.queryParameters['StartIndex'] as int? ?? 0;
          final limit = options.queryParameters['Limit'] as int? ?? 60;
          final responseTotal =
              totalCountForRequest?.call(options) ?? totalCount;
          starts.add(start);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'TotalRecordCount': responseTotal,
                'Items': [
                  for (
                    var index = start;
                    index < math.min(start + limit, responseTotal);
                    index++
                  )
                    _item(index, isStrm: includeStrm && index.isEven),
                ],
              },
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio, realtimeConnector: realtimeConnector);
}

EmbyApi _sectionApi() {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final folders =
              options.queryParameters['IncludeItemTypes'] ==
              'Folder,CollectionFolder,Movie,Series,Episode,Video';
          final items = [
            for (var index = 0; index < 60; index++)
              folders
                  ? {
                      'Id': 'folder-$index',
                      'Name': '目录 $index',
                      'Type': 'Folder',
                    }
                  : _item(index),
          ];
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {'TotalRecordCount': items.length, 'Items': items},
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

Map<String, dynamic> _item(int index, {bool isStrm = false}) => {
  'Id': 'item-$index',
  'Name': '项目 $index',
  'Type': 'Movie',
  'MediaType': 'Video',
  'Path': isStrm ? '/media/item-$index.strm' : '/media/item-$index.mkv',
  'Container': isStrm ? 'strm' : 'mkv',
  'ImageTags': const <String, String>{},
  'BackdropImageTags': const <String>[],
  'Genres': const <String>[],
  'UserData': const <String, dynamic>{},
};

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

Future<void> _showOverlay(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(CustomScrollView)),
  );
  await gesture.moveBy(const Offset(0, -60));
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 50));
  expect(_opacity(tester), 1);
}

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.byKey(const ValueKey('library-position-overlay')),
    )
    .opacity;

(int, int) _visibleRange(WidgetTester tester) {
  final label = tester
      .widget<Text>(find.byKey(const ValueKey('library-position-range')))
      .data!;
  final values = label.split('\u2013').map(int.parse).toList(growable: false);
  return (values[0], values[1]);
}

int _percentage(WidgetTester tester) {
  final label = tester
      .widget<Text>(find.byKey(const ValueKey('library-position-percentage')))
      .data!;
  return int.parse(label.substring(0, label.length - 1));
}

class _ReadCounter {
  int reads = 0;
}

class _CountingLibraryApi extends EmbyApi {
  _CountingLibraryApi({required this.itemCount, required this.counter})
    : super(_session, dio: Dio());

  final int itemCount;
  final _ReadCounter counter;

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
  }) async => EmbyItemPage(
    items: [
      for (var index = 0; index < itemCount; index++)
        _CountingItem(index: index, counter: counter),
    ],
    totalRecordCount: itemCount,
  );
}

class _CountingItem extends EmbyItem {
  _CountingItem({required int index, required this.counter})
    : _strm = index.isEven,
      super(
        id: 'counting-$index',
        name: '计数项目 $index',
        type: 'Movie',
        mediaType: 'Video',
        imageTags: const {},
        backdropImageTags: const [],
        genres: const [],
        userData: const EmbyUserData(),
      );

  final bool _strm;
  final _ReadCounter counter;

  @override
  bool get isStrm {
    counter.reads++;
    return _strm;
  }
}

class _FakeEmbySocket implements EmbySocket {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();
  bool _closed = false;

  @override
  Stream<dynamic> get messages => _messages.stream;

  void emitLibraryChanged() {
    _messages.add(
      jsonEncode({
        'MessageType': 'LibraryChanged',
        'Data': {
          'ItemsUpdated': ['item-70'],
        },
      }),
    );
  }

  @override
  void add(String data) {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _messages.close();
  }
}

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

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
