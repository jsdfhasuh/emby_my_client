import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/settings/library_sort_preferences.dart';
import 'package:emby_my_client/ui/home_screen.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('root state restores the stored sort before it is pushed', () async {
    final store = MemoryLibrarySortPreferenceStore();
    final api = _SortApi();
    await store.save(_scope, _library.id, _playCountDescending);

    final state = await restoreLibraryRootSortState(
      api: api,
      libraryId: _library.id,
      store: store,
    );

    expect(state.sortBy, LibrarySortBy.playCount);
    expect(state.sortOrder, LibrarySortOrder.descending);
  });

  testWidgets('HomeScreen enters a library with the restored first query', (
    tester,
  ) async {
    final store = MemoryLibrarySortPreferenceStore();
    final api = _SortApi();
    await store.save(_scope, _library.id, _playCountDescending);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: HomeScreen(
            api: api,
            categorySettings: _allCategories,
            sortPreferenceStore: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_library.name));
    await tester.pumpAndSettle();

    expect(api.mediaCalls, isNotEmpty);
    expect(api.mediaCalls.first.sortBy, LibrarySortBy.playCount);
    expect(api.mediaCalls.first.sortOrder, LibrarySortOrder.descending);
  });

  testWidgets('LibraryScreen enters a library with the restored first query', (
    tester,
  ) async {
    final store = MemoryLibrarySortPreferenceStore();
    final api = _SortApi();
    await store.save(_scope, _library.id, _playCountDescending);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryScreen(
          api: api,
          categorySettings: _allCategories,
          sortPreferenceStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_library.name));
    await tester.pumpAndSettle();

    expect(api.mediaCalls, isNotEmpty);
    expect(api.mediaCalls.first.sortBy, LibrarySortBy.playCount);
    expect(api.mediaCalls.first.sortOrder, LibrarySortOrder.descending);
  });

  testWidgets(
    'root sort selection and direction are persisted asynchronously',
    (tester) async {
      final store = MemoryLibrarySortPreferenceStore();
      final api = _SortApi();

      await tester.pumpWidget(_rootApp(api, store));
      await tester.pumpAndSettle();

      await _selectSort(tester, 'playCount');
      expect(
        await store.load(_scope, _library.id),
        const LibrarySortPreference(
          sortBy: LibrarySortBy.playCount,
          sortOrder: LibrarySortOrder.ascending,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('library-sort-direction-button')),
      );
      await tester.pumpAndSettle();
      expect(await store.load(_scope, _library.id), _playCountDescending);
    },
  );

  testWidgets('reset clears an existing sort preference', (tester) async {
    final store = MemoryLibrarySortPreferenceStore();
    final api = _SortApi();
    await store.save(_scope, _library.id, _playCountDescending);

    await tester.pumpWidget(
      _rootApp(
        api,
        store,
        initialState: const LibraryBrowseState(
          sortBy: LibrarySortBy.playCount,
          sortOrder: LibrarySortOrder.descending,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _reset(tester);

    expect(await store.load(_scope, _library.id), isNull);
    expect(find.byTooltip('排序方式'), findsOneWidget);
    expect(api.mediaCalls.last.sortBy, LibrarySortBy.name);
    expect(api.mediaCalls.last.sortOrder, LibrarySortOrder.ascending);
  });

  testWidgets('reset clears a stored value even when the reducer is a no-op', (
    tester,
  ) async {
    final store = MemoryLibrarySortPreferenceStore();
    final api = _SortApi();
    await store.save(_scope, _library.id, _playCountDescending);

    await tester.pumpWidget(_rootApp(api, store));
    await tester.pumpAndSettle();
    await _reset(tester);

    expect(await store.load(_scope, _library.id), isNull);
  });

  testWidgets('preference load and save failures do not block browsing', (
    tester,
  ) async {
    final store = _FailingSortPreferenceStore();
    final api = _SortApi();

    final restored = await restoreLibraryRootSortState(
      api: api,
      libraryId: _library.id,
      store: store,
    );
    expect(restored, const LibraryBrowseState());

    await tester.pumpWidget(_rootApp(api, store));
    await tester.pumpAndSettle();
    await _selectSort(tester, 'playCount');

    expect(api.mediaCalls.last.sortBy, LibrarySortBy.playCount);
    expect(api.mediaCalls, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('directory pages do not persist temporary sorting', (
    tester,
  ) async {
    final store = MemoryLibrarySortPreferenceStore();
    final api = _SortApi();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: LibraryBrowseScreen.directory(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-section-bar')), findsNothing);
    expect(await store.load(_scope, _library.id), isNull);
  });
}

MaterialApp _rootApp(
  _SortApi api,
  LibrarySortPreferenceStore store, {
  LibraryBrowseState initialState = const LibraryBrowseState(),
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: LibraryBrowseScreen.root(
    api: api,
    view: _library,
    categorySettings: _allCategories,
    sortPreferenceStore: store,
    initialState: initialState,
  ),
);

Future<void> _selectSort(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('library-sort-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('library-sort-$name')));
  await tester.pumpAndSettle();
}

Future<void> _reset(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-more-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('library-more-reset')));
  await tester.pumpAndSettle();
}

class _FailingSortPreferenceStore implements LibrarySortPreferenceStore {
  @override
  Future<LibrarySortPreference?> load(ServerScope scope, String libraryId) =>
      Future<LibrarySortPreference?>.error(StateError('fixture'));

  @override
  Future<void> save(
    ServerScope scope,
    String libraryId,
    LibrarySortPreference preference,
  ) => Future<void>.error(StateError('fixture'));

  @override
  Future<void> clearLibrary(ServerScope scope, String libraryId) =>
      Future<void>.error(StateError('fixture'));

  @override
  Future<void> clear(ServerScope scope) =>
      Future<void>.error(StateError('fixture'));
}

class _SortApi extends EmbyApi {
  _SortApi() : super(_session, dio: Dio());

  final List<_MediaCall> mediaCalls = [];

  @override
  Future<HomeData> getHomeBase() async =>
      const HomeData(views: [_library], resume: [], latestSections: []);

  @override
  Future<HomeLatestSection?> getHomeLatestSection(EmbyItem library) async =>
      null;

  @override
  Future<List<EmbyItem>> getViews() async => const [_library];

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
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
    mediaCalls.add(
      _MediaCall(sortBy: sortBy, sortOrder: sortOrder, parentId: parentId),
    );
    return const EmbyItemPage(
      items: [_movie],
      rawItemCount: 1,
      totalRecordCount: 1,
    );
  }

  @override
  Future<EmbyItemPage> getDirectoryChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
  }) async =>
      const EmbyItemPage(items: [_movie], rawItemCount: 1, totalRecordCount: 1);
}

class _MediaCall {
  const _MediaCall({
    required this.sortBy,
    required this.sortOrder,
    required this.parentId,
  });

  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
  final String parentId;
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Server',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _scope = ServerScope(serverId: 'server-1', userId: 'user-1');

const _library = EmbyItem(
  id: 'library-1',
  name: 'Test Library',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _movie = EmbyItem(
  id: 'movie-1',
  name: 'Test Movie',
  type: 'Movie',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _playCountDescending = LibrarySortPreference(
  sortBy: LibrarySortBy.playCount,
  sortOrder: LibrarySortOrder.descending,
);

const _allCategories = LibraryCategorySettings(
  showMovies: true,
  showSeries: true,
  showVideos: true,
  showFavorites: true,
  showFolders: true,
);
