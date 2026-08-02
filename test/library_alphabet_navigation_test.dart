import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('letter rail previews, filters, labels, and resets position', (
    tester,
  ) async {
    _setPhoneView(tester);
    final requests = <RequestOptions>[];
    final api = _alphabetApi(requests);

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-alphabet-button')),
      findsOneWidget,
    );
    expect(requests.single.queryParameters, isNot(contains('NameStartsWith')));
    expect(requests.single.queryParameters, isNot(contains('NameLessThan')));

    await tester.longPress(
      find.byKey(const ValueKey('library-alphabet-button')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('library-alphabet-rail')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-alphabet-barrier')));
    await tester.pump();

    final scrollable = _verticalScrollable();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-all-50')),
      500,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      isPositive,
    );

    await tester.tap(find.byKey(const ValueKey('library-alphabet-button')));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('library-alphabet-option-a'))),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('library-alphabet-option-m'))),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('library-alphabet-preview')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('library-alphabet-preview-label')),
          )
          .data,
      'M',
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters['NameStartsWith'], 'M');
    expect(requests.last.queryParameters, isNot(contains('NameLessThan')));
    expect(find.text('首字母：M'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-alphabet-preview')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('library-alphabet-rail')), findsNothing);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);

    final chip = find.byKey(const ValueKey('library-alphabet-filter-chip'));
    await tester.tap(
      find.descendant(of: chip, matching: find.byIcon(Icons.close)),
    );
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters, isNot(contains('NameStartsWith')));
    expect(requests.last.queryParameters, isNot(contains('NameLessThan')));
    expect(chip, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('symbols filter remains exclusive across server pagination', (
    tester,
  ) async {
    _setPhoneView(tester);
    final requests = <RequestOptions>[];
    final api = _alphabetApi(requests);

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await _selectAlphabet(tester, 'symbols');

    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters['NameLessThan'], 'A');
    expect(requests.last.queryParameters, isNot(contains('NameStartsWith')));
    expect(find.text('首字母：#'), findsOneWidget);

    final position = tester
        .state<ScrollableState>(_verticalScrollable())
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    final symbolPages = requests.where(
      (request) => request.queryParameters['NameLessThan'] == 'A',
    );
    expect(
      symbolPages.map((request) => request.queryParameters['StartIndex']),
      containsAllInOrder([0, 60]),
    );
    for (final request in symbolPages) {
      expect(request.queryParameters, isNot(contains('NameStartsWith')));
    }

    await _selectAlphabet(tester, 'all');
    expect(requests.last.queryParameters['StartIndex'], 0);
    expect(requests.last.queryParameters, isNot(contains('NameStartsWith')));
    expect(requests.last.queryParameters, isNot(contains('NameLessThan')));

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets(
    'non-name sorting and grouping views disable alphabet navigation',
    (tester) async {
      _setPhoneView(tester);
      final requests = <RequestOptions>[];
      final api = _alphabetApi(requests);

      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      await _selectAlphabet(tester, 'm');
      expect(find.text('首字母：M'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-sort-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('library-sort-dateAddedDescending')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-alphabet-button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-alphabet-filter-chip')),
        findsNothing,
      );
      expect(requests.last.queryParameters['SortBy'], 'DateCreated');
      expect(requests.last.queryParameters, isNot(contains('NameStartsWith')));
      expect(requests.last.queryParameters, isNot(contains('NameLessThan')));

      await tester.tap(find.byKey(const ValueKey('library-sort-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('library-sort-nameAscending')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-alphabet-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('library-section-folders')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-alphabet-button')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-alphabet-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('library-section-genres')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-alphabet-button')),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets('late alphabet response cannot replace the latest selection', (
    tester,
  ) async {
    _setPhoneView(tester);
    final api = _DeferredAlphabetApi();

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await _selectAlphabetWithoutSettling(tester, 'm');
    await _selectAlphabetWithoutSettling(tester, 'z');

    api.zRequest.complete(_page(prefix: 'z', startIndex: 0, total: 1));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-item-z-0')), findsOneWidget);

    api.mRequest.complete(_page(prefix: 'm', startIndex: 0, total: 1));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-item-z-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-item-m-0')), findsNothing);
    expect(api.filters, [const AllItems(), LetterItems('M'), LetterItems('Z')]);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('server alphabet errors never fall back to an unfiltered scan', (
    tester,
  ) async {
    _setPhoneView(tester);
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (options.queryParameters['NameStartsWith'] == 'M') {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 400,
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: _pageJson(prefix: 'all', startIndex: 0, total: 1),
              ),
            );
          },
        ),
      );
    final api = EmbyApi(_session, dio: dio);

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await _selectAlphabet(tester, 'm');

    expect(requests, hasLength(2));
    expect(requests.last.queryParameters['NameStartsWith'], 'M');
    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('首字母：M'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-alphabet-button')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('alphabet rail fits a compact landscape viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(852, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _alphabetApi(<RequestOptions>[]);

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-alphabet-button')));
    await tester.pump();

    final railRect = tester.getRect(
      find.byKey(const ValueKey('library-alphabet-rail')),
    );
    expect(railRect.left, greaterThanOrEqualTo(0));
    expect(railRect.top, greaterThanOrEqualTo(0));
    expect(railRect.right, lessThanOrEqualTo(852));
    expect(railRect.bottom, lessThanOrEqualTo(393));
    expect(
      find.byKey(const ValueKey('library-alphabet-option-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-alphabet-option-z')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });
}

void _setPhoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(EmbyApi api) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: LibraryBrowseScreen(api: api, view: _library),
);

Future<void> _selectAlphabet(WidgetTester tester, String key) async {
  await _selectAlphabetWithoutSettling(tester, key);
  await tester.pumpAndSettle();
}

Future<void> _selectAlphabetWithoutSettling(
  WidgetTester tester,
  String key,
) async {
  await tester.tap(find.byKey(const ValueKey('library-alphabet-button')));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey('library-alphabet-option-$key')));
  await tester.pump();
}

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable &&
      (widget.axisDirection == AxisDirection.down ||
          widget.axisDirection == AxisDirection.up),
);

EmbyApi _alphabetApi(List<RequestOptions> requests) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final query = options.queryParameters;
          final startIndex = query['StartIndex'] as int? ?? 0;
          final prefix =
              query['NameStartsWith']?.toString().toLowerCase() ??
              (query['NameLessThan'] == 'A' ? 'symbols' : 'all');
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _pageJson(
                prefix: prefix,
                startIndex: startIndex,
                total: 120,
              ),
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

class _DeferredAlphabetApi extends EmbyApi {
  _DeferredAlphabetApi() : super(_session, dio: Dio());

  final mRequest = Completer<EmbyItemPage>();
  final zRequest = Completer<EmbyItemPage>();
  final List<LibraryAlphabetFilter> filters = [];

  @override
  Future<EmbyItemPage> getLibraryItems({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryBrowseOptions options = const LibraryBrowseOptions(),
    String? genreId,
    String? tagId,
    bool favoritesFilter = false,
    bool includeMediaSources = false,
    String? nameStartsWith,
    String? nameLessThan,
  }) {
    final filter = nameStartsWith != null
        ? LetterItems(nameStartsWith)
        : nameLessThan != null
        ? const SymbolsItems()
        : const AllItems();
    filters.add(filter);
    return switch (filter) {
      LetterItems(letter: 'M') => mRequest.future,
      LetterItems(letter: 'Z') => zRequest.future,
      _ => Future.value(_page(prefix: 'all', startIndex: 0, total: 1)),
    };
  }
}

EmbyItemPage _page({
  required String prefix,
  required int startIndex,
  required int total,
}) => EmbyItemPage(
  items: [
    for (
      var index = startIndex;
      index < (startIndex + 60).clamp(0, total);
      index++
    )
      _item(prefix, index),
  ],
  totalRecordCount: total,
);

Map<String, dynamic> _pageJson({
  required String prefix,
  required int startIndex,
  required int total,
}) => {
  'TotalRecordCount': total,
  'Items': [
    for (
      var index = startIndex;
      index < (startIndex + 60).clamp(0, total);
      index++
    )
      _itemJson(prefix, index),
  ],
};

EmbyItem _item(String prefix, int index) =>
    EmbyItem.fromJson(_itemJson(prefix, index));

Map<String, dynamic> _itemJson(String prefix, int index) => {
  'Id': '$prefix-$index',
  'Name': '$prefix $index',
  'Type': 'Movie',
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
