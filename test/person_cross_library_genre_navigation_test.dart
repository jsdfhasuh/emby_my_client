import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/home_shell.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/person_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shared_preferences_async_test_backend.dart';

void main() {
  testWidgets(
    'person works resolve genre navigation against their own library',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _CrossLibraryApi();
      final controller = _CrossLibraryController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: HomeShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('电影一'));
      await tester.pumpAndSettle();
      final movieDetail = tester.widget<ItemDetailScreen>(
        find.byType(ItemDetailScreen),
      );
      expect(movieDetail.libraryOrigin?.rootView.id, 'movies-library');

      final cast = find.byKey(const ValueKey('cast-link-person-1'));
      await tester.ensureVisible(cast);
      await tester.tap(cast);
      await tester.pumpAndSettle();
      expect(find.byType(PersonDetailScreen), findsOneWidget);

      final seriesWork = find.byKey(const ValueKey('person-work-series-1'));
      await tester.ensureVisible(seriesWork);
      await tester.tap(seriesWork);
      await tester.pumpAndSettle();

      final seriesDetail = tester.widget<ItemDetailScreen>(
        find.byType(ItemDetailScreen),
      );
      expect(seriesDetail.initialItem.id, 'series-1');
      expect(seriesDetail.libraryOrigin, isNull);

      final genreChip = find.byKey(const ValueKey('item-detail-genre-0'));
      await tester.ensureVisible(genreChip);
      await tester.tap(genreChip);
      await tester.pumpAndSettle();

      expect(api.viewsRequestCount, greaterThanOrEqualTo(1));
      expect(api.ancestorLookups, contains('tv-folder'));
      expect(api.ancestorLookups, isNot(contains('movies-library')));
      expect(api.genreRequests, hasLength(1));
      expect(api.genreRequests.single.parentId, 'tv-library');
      expect(api.mediaRequests, hasLength(1));
      expect(api.mediaRequests.single.parentId, 'tv-library');
      expect(api.mediaRequests.single.genreId, 'genre-tv');
      expect(api.genreRequests.single.parentId, isNot('movies-library'));
      expect(api.mediaRequests.single.parentId, isNot('movies-library'));
      expect(find.byType(LibraryBrowseScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Sci-Fi & Fantasy'), findsOneWidget);
    },
  );
}

class _CrossLibraryController extends AppController {
  _CrossLibraryController(this._api)
    : super(
        capabilities: PlatformCapabilities.ipad,
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
      );

  final EmbyApi _api;

  @override
  EmbyApi get api => _api;

  @override
  EmbySession? get session => _session;
}

class _CrossLibraryApi extends EmbyApi {
  _CrossLibraryApi() : super(_session, dio: Dio());

  final ancestorLookups = <String>[];
  final genreRequests = <_GenreRequest>[];
  final mediaRequests = <_MediaRequest>[];
  var viewsRequestCount = 0;

  @override
  Future<HomeData> getHomeBase() async => HomeData(
    views: const [_moviesLibrary, _tvLibrary],
    resume: const [],
    latestSections: const [
      HomeLatestSection(library: _moviesLibrary, items: [_movieSummary]),
    ],
  );

  @override
  Future<HomeLatestSection?> getHomeLatestSection(EmbyItem library) async =>
      null;

  @override
  Future<List<EmbyItem>> getViews() async {
    viewsRequestCount++;
    return const [_moviesLibrary, _tvLibrary];
  }

  @override
  Future<EmbyItem> getItem(String itemId) async {
    ancestorLookups.add(itemId);
    return switch (itemId) {
      'movie-1' => _movieDetail,
      'person-1' => _person,
      'series-1' => _seriesDetail,
      'tv-folder' => _tvFolder,
      'movie-folder' => _movieFolder,
      _ => throw StateError('Unexpected item lookup: $itemId'),
    };
  }

  @override
  Future<EmbyItemPage> getPersonItems({
    required String personId,
    int startIndex = 0,
    int limit = 60,
    PersonMediaFilter filter = PersonMediaFilter.all,
  }) async =>
      const EmbyItemPage(items: [_movieWork, _seriesWork], totalRecordCount: 2);

  @override
  Future<Map<String, EmbyUserData>> getUserDataForItems(
    Iterable<String> itemIds,
  ) async => const {};

  @override
  Future<List<EmbyItem>> getSeasons(String seriesId) async => const [];

  @override
  Future<List<EmbyItem>> getEpisodes(
    String seriesId, {
    String? seasonId,
  }) async => const [];

  @override
  Future<EmbyItemPage> getLibraryGenres({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
    int startIndex = 0,
    int limit = 60,
  }) async {
    genreRequests.add(
      _GenreRequest(
        parentId: parentId,
        profile: profile,
        startIndex: startIndex,
        limit: limit,
      ),
    );
    return const EmbyItemPage(
      items: [_tvGenre],
      rawItemCount: 1,
      totalRecordCount: 1,
    );
  }

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
    mediaRequests.add(
      _MediaRequest(
        parentId: parentId,
        profile: profile,
        startIndex: startIndex,
        genreId: genreId,
      ),
    );
    return const EmbyItemPage(
      items: [_facetSeries],
      rawItemCount: 1,
      totalRecordCount: 1,
    );
  }
}

class _GenreRequest {
  const _GenreRequest({
    required this.parentId,
    required this.profile,
    required this.startIndex,
    required this.limit,
  });

  final String parentId;
  final LibraryContentProfile profile;
  final int startIndex;
  final int limit;
}

class _MediaRequest {
  const _MediaRequest({
    required this.parentId,
    required this.profile,
    required this.startIndex,
    required this.genreId,
  });

  final String parentId;
  final LibraryContentProfile profile;
  final int startIndex;
  final String? genreId;
}

const _moviesLibrary = EmbyItem(
  id: 'movies-library',
  name: '电影库',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _tvLibrary = EmbyItem(
  id: 'tv-library',
  name: '电视剧库',
  type: 'CollectionFolder',
  collectionType: 'tvshows',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _movieFolder = EmbyItem(
  id: 'movie-folder',
  name: '电影目录',
  type: 'Folder',
  parentId: 'movies-library',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _tvFolder = EmbyItem(
  id: 'tv-folder',
  name: '电视剧目录',
  type: 'Folder',
  parentId: 'tv-library',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _movieSummary = EmbyItem(
  id: 'movie-1',
  name: '电影一',
  type: 'Movie',
  parentId: 'movie-folder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _movieDetail = EmbyItem(
  id: 'movie-1',
  name: '电影一',
  type: 'Movie',
  parentId: 'movie-folder',
  imageTags: {},
  backdropImageTags: [],
  genres: ['Drama'],
  people: [EmbyPerson(id: 'person-1', name: '演员一', type: 'Actor', role: '主角')],
  userData: EmbyUserData(),
);

const _movieWork = EmbyItem(
  id: 'movie-1',
  name: '电影一',
  type: 'Movie',
  parentId: 'movie-folder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _seriesWork = EmbyItem(
  id: 'series-1',
  name: '电视剧一',
  type: 'Series',
  parentId: 'tv-folder',
  imageTags: {},
  backdropImageTags: [],
  genres: ['Sci-Fi & Fantasy'],
  userData: EmbyUserData(),
);

const _seriesDetail = EmbyItem(
  id: 'series-1',
  name: '电视剧一',
  type: 'Series',
  parentId: 'tv-folder',
  imageTags: {},
  backdropImageTags: [],
  genres: ['Sci-Fi & Fantasy'],
  userData: EmbyUserData(),
);

const _person = EmbyItem(
  id: 'person-1',
  name: '演员一',
  type: 'Person',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _tvGenre = EmbyItem(
  id: 'genre-tv',
  name: 'Sci-Fi & Fantasy',
  type: 'Genre',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _facetSeries = EmbyItem(
  id: 'facet-series-1',
  name: '分类电视剧一',
  type: 'Series',
  parentId: 'tv-library',
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
