import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
          home: LibraryBrowseScreen(api: api, view: _library),
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
    final api = _pagedApi(starts: <int>[], totalCount: 120, includeStrm: true);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen(api: api, view: _library),
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
    expect(find.byKey(const ValueKey('library-position-total')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-position-percentage')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('does not attach position state to grouping grids', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _sectionApi();

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen(api: api, view: _library),
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
    await tester.tap(find.byKey(const ValueKey('library-section-folders')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-position-panel')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-group-folder-0')),
      findsOneWidget,
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
        home: LibraryBrowseScreen(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    await _showOverlay(tester);
    await tester.tap(find.byKey(const ValueKey('library-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('library-sort-dateAddedDescending')),
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
}

EmbyApi _pagedApi({
  required List<int> starts,
  required int totalCount,
  bool includeStrm = false,
  List<RequestOptions>? requests,
}) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests?.add(options);
          final start = options.queryParameters['StartIndex'] as int? ?? 0;
          final limit = options.queryParameters['Limit'] as int? ?? 60;
          starts.add(start);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'TotalRecordCount': totalCount,
                'Items': [
                  for (
                    var index = start;
                    index < math.min(start + limit, totalCount);
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
  return EmbyApi(_session, dio: dio);
}

EmbyApi _sectionApi() {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final folders =
              options.queryParameters['IncludeItemTypes'] == 'Folder';
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
