import 'dart:async';

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
  testWidgets(
    'stale pull refresh cannot pollute a directory or permanently block reload and paging',
    (tester) async {
      _setCompactView(tester);
      final api = _ControlledLibraryApi();
      await tester.pumpWidget(_rootApp(api));
      await tester.pumpAndSettle();

      final staleMedia = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.media && call.startIndex == 0,
      );
      await _pullToRefresh(tester);
      expect(api.mediaCalls(startIndex: 0), 2);

      await tester.tap(
        find.byKey(const ValueKey('library-section-directories')),
      );
      await _pumpAsyncWork(tester);
      expect(
        find.byKey(const ValueKey('library-group-directory-0')),
        findsOneWidget,
      );

      staleMedia.complete(_singleMediaPage('stale-media'));
      await tester.pumpAndSettle();
      expect(find.text('stale-media'), findsNothing);
      expect(
        find.byKey(const ValueKey('library-group-directory-0')),
        findsOneWidget,
      );

      final directoryRefresh = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.directory && call.startIndex == 0,
      );
      await _pullToRefresh(tester);
      expect(api.directoryStarts, [0, 0]);
      directoryRefresh.complete(_directoryPage(0));
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(_verticalScrollable())
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(api.directoryStarts, [0, 0, 60]);

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets(
    'a stale reload cannot clear a new generation token and rapid refresh stays single flight',
    (tester) async {
      final api = _ControlledLibraryApi();
      await tester.pumpWidget(_rootApp(api));
      await tester.pumpAndSettle();

      final staleMedia = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.media && call.startIndex == 0,
      );
      await _pullToRefresh(tester);

      await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
      await _pumpAsyncWork(tester);

      final activeFavoriteReload = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.favorites &&
            call.mediaType == LibraryMediaType.all &&
            call.startIndex == 0,
      );
      await _tapMenuRefresh(tester);
      final callsWithActiveReload = api.calls.length;

      staleMedia.complete(_singleMediaPage('stale-media'));
      await _pumpAsyncWork(tester);
      await _tapMenuRefresh(tester);
      expect(api.calls, hasLength(callsWithActiveReload));

      activeFavoriteReload.complete(_singleMediaPage('favorite-current'));
      await tester.pumpAndSettle();
      expect(find.text('favorite-current'), findsOneWidget);

      final rapidReload = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.favorites &&
            call.mediaType == LibraryMediaType.all &&
            call.startIndex == 0,
      );
      await _tapMenuRefresh(tester);
      final callsAfterFirstTap = api.calls.length;
      await _tapMenuRefresh(tester);
      expect(api.calls, hasLength(callsAfterFirstTap));

      rapidReload.complete(_singleMediaPage('favorite-rapid'));
      await tester.pumpAndSettle();
      expect(find.text('favorite-rapid'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets(
    'directory to favorites to movie invalidates both stale reloads',
    (tester) async {
      _setCompactView(tester);
      final api = _ControlledLibraryApi();
      await tester.pumpWidget(
        _rootApp(api, initialState: const LibraryBrowseState.directory()),
      );
      await tester.pumpAndSettle();

      final staleDirectory = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.directory && call.startIndex == 0,
      );
      await _pullToRefresh(tester);

      await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
      await _pumpAsyncWork(tester);
      final staleFavorites = api.deferNext(
        (call) =>
            call.scope == LibraryBrowseScope.favorites &&
            call.mediaType == LibraryMediaType.all &&
            call.startIndex == 0,
      );
      await _tapMenuRefresh(tester);

      await tester.tap(find.byKey(const ValueKey('library-media-type-movie')));
      await _pumpAsyncWork(tester);
      staleDirectory.complete(_directoryPage(0, prefix: 'stale-directory'));
      staleFavorites.complete(_singleMediaPage('stale-favorite'));
      await tester.pumpAndSettle();

      final selectedFavorite = tester.widget<FilterChip>(
        find.byKey(const ValueKey('library-section-favorites')),
      );
      final selectedMovie = tester.widget<ChoiceChip>(
        find.descendant(
          of: find.byKey(const ValueKey('library-media-type-movie')),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(selectedFavorite.selected, isTrue);
      expect(selectedMovie.selected, isTrue);
      expect(api.calls.last.scope, LibraryBrowseScope.favorites);
      expect(api.calls.last.mediaType, LibraryMediaType.movie);
      expect(find.text('stale-favorite'), findsNothing);
      expect(find.textContaining('stale-directory'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
    },
  );

  testWidgets('played filter switch during refresh ignores the stale result', (
    tester,
  ) async {
    final api = _ControlledLibraryApi();
    await tester.pumpWidget(_rootApp(api));
    await tester.pumpAndSettle();

    final staleRefresh = api.deferNext(
      (call) => call.scope == LibraryBrowseScope.media && call.startIndex == 0,
    );
    await _pullToRefresh(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-played-filter-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('未播放'));
    await tester.tap(find.text('查看结果'));
    await _pumpAsyncWork(tester);

    staleRefresh.complete(_singleMediaPage('stale-played-filter'));
    await tester.pumpAndSettle();
    expect(api.calls.last.playedFilter, LibraryPlayedFilter.unplayed);
    expect(find.textContaining('unplayed'), findsOneWidget);
    expect(find.text('stale-played-filter'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('sort switch during refresh ignores the stale result', (
    tester,
  ) async {
    final api = _ControlledLibraryApi();
    await tester.pumpWidget(_rootApp(api));
    await tester.pumpAndSettle();

    final staleRefresh = api.deferNext(
      (call) => call.scope == LibraryBrowseScope.media && call.startIndex == 0,
    );
    await _pullToRefresh(tester);
    await tester.tap(find.byKey(const ValueKey('library-sort-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('加入日期'));
    await _pumpAsyncWork(tester);

    staleRefresh.complete(_singleMediaPage('stale-sort'));
    await tester.pumpAndSettle();
    expect(api.calls.last.sortBy, LibrarySortBy.dateAdded);
    expect(find.textContaining('dateAdded'), findsOneWidget);
    expect(find.text('stale-sort'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });
}

Future<void> _pullToRefresh(WidgetTester tester) async {
  final indicator = tester.state<RefreshIndicatorState>(
    find.byType(RefreshIndicator),
  );
  unawaited(indicator.show());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapMenuRefresh(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-more-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('刷新').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpAsyncWork(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Widget _rootApp(
  EmbyApi api, {
  LibraryBrowseState initialState = const LibraryBrowseState(),
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: LibraryBrowseScreen.root(
    api: api,
    view: _library,
    categorySettings: _allCategorySettings,
    initialState: initialState,
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

typedef _CallMatcher = bool Function(_LibraryCall call);

class _DeferredCall {
  _DeferredCall(this.matches);

  final _CallMatcher matches;
  final Completer<EmbyItemPage> completer = Completer<EmbyItemPage>();
}

class _LibraryCall {
  const _LibraryCall({
    required this.scope,
    required this.startIndex,
    this.mediaType = LibraryMediaType.all,
    this.playedFilter = LibraryPlayedFilter.all,
    this.sortBy = LibrarySortBy.name,
  });

  final LibraryBrowseScope scope;
  final int startIndex;
  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
  final LibrarySortBy sortBy;
}

class _ControlledLibraryApi extends EmbyApi {
  _ControlledLibraryApi() : super(_session, dio: Dio());

  final List<_LibraryCall> calls = [];
  final List<_DeferredCall> _deferred = [];

  List<int> get directoryStarts => calls
      .where((call) => call.scope == LibraryBrowseScope.directory)
      .map((call) => call.startIndex)
      .toList(growable: false);

  int mediaCalls({required int startIndex}) => calls
      .where(
        (call) =>
            call.scope == LibraryBrowseScope.media &&
            call.startIndex == startIndex,
      )
      .length;

  Completer<EmbyItemPage> deferNext(_CallMatcher matcher) {
    final deferred = _DeferredCall(matcher);
    _deferred.add(deferred);
    return deferred.completer;
  }

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
  }) {
    final call = _LibraryCall(
      scope: favorites
          ? LibraryBrowseScope.favorites
          : LibraryBrowseScope.media,
      startIndex: startIndex,
      mediaType: mediaType,
      playedFilter: playedFilter,
      sortBy: sortBy,
    );
    return _respond(call);
  }

  @override
  Future<EmbyItemPage> getDirectoryChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
  }) => _respond(
    _LibraryCall(
      scope: LibraryBrowseScope.directory,
      startIndex: startIndex,
      sortBy: sortBy,
    ),
  );

  Future<EmbyItemPage> _respond(_LibraryCall call) {
    calls.add(call);
    final index = _deferred.indexWhere((entry) => entry.matches(call));
    if (index >= 0) return _deferred.removeAt(index).completer.future;
    return Future.value(_defaultPage(call));
  }

  EmbyItemPage _defaultPage(_LibraryCall call) {
    if (call.scope == LibraryBrowseScope.directory) {
      return _directoryPage(call.startIndex);
    }
    final prefix = call.scope == LibraryBrowseScope.favorites
        ? 'favorite'
        : 'media';
    return _singleMediaPage(
      '$prefix-${call.mediaType.name}-${call.playedFilter.name}-${call.sortBy.name}',
    );
  }
}

EmbyItemPage _singleMediaPage(String id) =>
    EmbyItemPage(items: [_item(id)], totalRecordCount: 1, rawItemCount: 1);

EmbyItemPage _directoryPage(int startIndex, {String prefix = 'directory'}) {
  final end = (startIndex + 60).clamp(0, 65);
  final items = [
    for (var index = startIndex; index < end; index++)
      _item('$prefix-$index', type: 'Folder'),
  ];
  return EmbyItemPage(
    items: items,
    totalRecordCount: 65,
    rawItemCount: items.length,
  );
}

EmbyItem _item(String id, {String type = 'Movie'}) => EmbyItem(
  id: id,
  name: id,
  type: type,
  mediaType: type == 'Folder' ? null : 'Video',
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
