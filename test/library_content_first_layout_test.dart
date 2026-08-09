import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_grid_geometry.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/home_shell_navigation.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/widgets/library_mixed_entry_card.dart';
import 'package:emby_my_client/ui/widgets/library_photo_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_filter_test_helpers.dart';

void main() {
  test('all iPad library geometries use five columns', () {
    expect(libraryIPadMediaGridGeometry.crossAxisCount, 5);
    expect(libraryIPadPhotoGridGeometry.crossAxisCount, 5);
    expect(libraryIPadMixedGridGeometry.crossAxisCount, 5);
    expect(libraryIPadDirectoryGridGeometry.crossAxisCount, 5);
    expect(libraryIPadFacetGridGeometry.crossAxisCount, 5);
  });

  testWidgets('cancel, barrier, and back discard the filter draft', (
    tester,
  ) async {
    final api = _LayoutApi();
    await tester.pumpWidget(_libraryApp(api));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));

    await openLibraryFilter(tester);
    await selectLibraryMediaType(tester, 'movie');
    await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
    await _finishSheetAnimation(tester);
    expect(api.calls, hasLength(1));

    await openLibraryFilter(tester);
    expect(_isSelected(tester, 'library-media-type-all'), isTrue);
    await selectLibraryMediaType(tester, 'movie');
    await tester.tapAt(const Offset(8, 80));
    await _finishSheetAnimation(tester);
    expect(find.byKey(const ValueKey('library-filter-apply')), findsNothing);
    expect(api.calls, hasLength(1));

    await openLibraryFilter(tester);
    expect(_isSelected(tester, 'library-media-type-all'), isTrue);
    await selectLibraryPlayedFilter(tester, 'unplayed');
    await tester.binding.handlePopRoute();
    await _finishSheetAnimation(tester);
    expect(api.calls, hasLength(1));

    await openLibraryFilter(tester);
    expect(_isSelected(tester, 'library-media-type-all'), isTrue);
    expect(_isSelected(tester, 'library-played-all'), isTrue);
    await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
    await _finishSheetAnimation(tester);
    expect(tester.takeException(), isNull);

    await _dispose(tester, api);
  });

  testWidgets('reset changes only the draft until apply', (tester) async {
    final api = _LayoutApi();
    await tester.pumpWidget(
      _libraryApp(
        api,
        initialState: const LibraryBrowseState(
          mediaType: LibraryMediaType.movie,
          playedFilter: LibraryPlayedFilter.unplayed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));

    await openLibraryFilter(tester);
    expect(_isSelected(tester, 'library-media-type-movie'), isTrue);
    expect(_isSelected(tester, 'library-played-unplayed'), isTrue);
    await tester.tap(find.byKey(const ValueKey('library-filter-reset')));
    await tester.pump();
    expect(_isSelected(tester, 'library-media-type-all'), isTrue);
    expect(_isSelected(tester, 'library-played-all'), isTrue);
    expect(api.calls, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
    await _finishSheetAnimation(tester);
    await openLibraryFilter(tester);
    expect(_isSelected(tester, 'library-media-type-movie'), isTrue);
    expect(_isSelected(tester, 'library-played-unplayed'), isTrue);
    await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
    await _finishSheetAnimation(tester);

    await _dispose(tester, api);
  });

  testWidgets('apply changes all draft dimensions in one request', (
    tester,
  ) async {
    final api = _LayoutApi();
    final scanService = _scanService(api);
    await tester.pumpWidget(_libraryApp(api, scanService: scanService));
    await tester.pumpAndSettle();

    await openLibraryFilter(tester);
    await selectLibraryMediaType(tester, 'all');
    await selectLibraryLocalFilter(tester, 'all');
    await selectLibraryPlayedFilter(tester, 'all');
    await applyLibraryFilter(tester);
    expect(api.calls, hasLength(1));

    await openLibraryFilter(tester);
    await selectLibraryMediaType(tester, 'movie');
    await selectLibraryPlayedFilter(tester, 'unplayed');
    expect(api.calls, hasLength(1));
    await applyLibraryFilter(tester);

    expect(api.calls, hasLength(2));
    expect(api.calls.last.mediaType, LibraryMediaType.movie);
    expect(api.calls.last.playedFilter, LibraryPlayedFilter.unplayed);
    await _dispose(tester, api, scanService: scanService);
  });

  testWidgets('photo draft clears source and played filters', (tester) async {
    final api = _LayoutApi();
    final scanService = _scanService(api);
    await tester.pumpWidget(
      _libraryApp(api, view: _homeVideosLibrary, scanService: scanService),
    );
    await tester.pumpAndSettle();

    await openLibraryFilter(tester);
    await selectLibraryLocalFilter(tester, 'strm');
    await selectLibraryPlayedFilter(tester, 'unplayed');
    await selectLibraryMediaType(tester, 'photo');
    expect(find.text('来源'), findsNothing);
    expect(find.text('播放状态'), findsNothing);
    expect(api.calls, hasLength(1));
    await applyLibraryFilter(tester);

    expect(api.calls, hasLength(2));
    expect(api.calls.last.mediaType, LibraryMediaType.photo);
    expect(api.calls.last.playedFilter, LibraryPlayedFilter.all);
    expect(find.byTooltip('筛选 · 图片'), findsOneWidget);

    await openLibraryFilter(tester);
    expect(_isSelected(tester, 'library-media-type-photo'), isTrue);
    expect(find.text('来源'), findsNothing);
    expect(find.text('播放状态'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
    await _finishSheetAnimation(tester);
    await _dispose(tester, api, scanService: scanService);
  });

  testWidgets('unavailable scanning hides source filters on iPad and Android', (
    tester,
  ) async {
    for (final capabilities in [
      PlatformCapabilities.ipad,
      PlatformCapabilities.android,
    ]) {
      final api = _LayoutApi();
      await tester.pumpWidget(
        _libraryApp(api, view: _homeVideosLibrary, capabilities: capabilities),
      );
      await tester.pumpAndSettle();

      await openLibraryFilter(tester);
      expect(find.text('来源'), findsNothing);
      expect(find.text('STRM'), findsNothing);
      expect(find.text('普通媒体'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
      await _finishSheetAnimation(tester);
      expect(api.calls, hasLength(1));
      await _dispose(tester, api);
    }
  });

  testWidgets('historical STRM state normalizes before its first query', (
    tester,
  ) async {
    for (final capabilities in [
      PlatformCapabilities.ipad,
      PlatformCapabilities.android,
    ]) {
      final api = _LayoutApi();
      await tester.pumpWidget(
        _libraryApp(
          api,
          view: _homeVideosLibrary,
          initialState: const LibraryBrowseState(
            localFilter: LibraryLocalMediaFilter.strm,
          ),
          capabilities: capabilities,
        ),
      );
      await tester.pumpAndSettle();

      expect(api.calls, hasLength(1));
      expect(api.scanCalls, 0);
      expect(find.byTooltip('筛选 · STRM'), findsNothing);
      expect(find.textContaining('STRM 统计'), findsNothing);
      expect(find.byKey(const ValueKey('library-item-grid-0')), findsOneWidget);
      await _dispose(tester, api);
    }
  });

  testWidgets('a shutting down scan service falls back to one media query', (
    tester,
  ) async {
    final api = _LayoutApi();
    final scanService = _scanService(api);
    await tester.pumpWidget(
      _libraryApp(
        api,
        view: _homeVideosLibrary,
        initialState: const LibraryBrowseState(
          localFilter: LibraryLocalMediaFilter.strm,
        ),
        scanService: scanService,
      ),
    );
    await tester.pumpAndSettle();
    expect(api.scanCalls, 1);
    expect(api.calls, isEmpty);

    await scanService.cancelAll();
    await tester.pumpAndSettle();

    expect(scanService.isAvailable, isFalse);
    expect(api.calls, hasLength(1));
    expect(api.scanCalls, 1);
    await openLibraryFilter(tester);
    expect(find.text('来源'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
    await _finishSheetAnimation(tester);
    await _dispose(tester, api, scanService: scanService);
  });

  testWidgets('pure photo libraries hide ineffective filtering', (
    tester,
  ) async {
    final api = _LayoutApi();
    await tester.pumpWidget(_libraryApp(api, view: _photoLibrary));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-filter-button')), findsNothing);
    expect(find.text('媒体类型'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester, api);
  });

  testWidgets('iPad landscape shows one chrome and a visible five-column row', (
    tester,
  ) async {
    _setView(tester, const Size(1024, 768));
    final api = _LayoutApi(itemCount: 12);
    var homeCalls = 0;
    var searchCalls = 0;
    var settingsCalls = 0;
    var accountCalls = 0;
    final navigation = HomeShellNavigationActions(
      showHome: () => homeCalls++,
      showSearch: () => searchCalls++,
      openSettings: () async => settingsCalls++,
      openAccount: () async => accountCalls++,
    );

    await tester.pumpWidget(
      _libraryApp(
        api,
        capabilities: PlatformCapabilities.ipad,
        navigationActions: navigation,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('媒体类型'), findsNothing);
    expect(find.byKey(const ValueKey('library-filter-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('large-screen-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('large-screen-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('large-screen-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('large-screen-account')), findsOneWidget);

    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final geometry = grid.gridDelegate as LibraryGridGeometry;
    expect(geometry.crossAxisCount, 5);
    final firstRow = [
      for (var index = 0; index < 5; index++)
        tester.getRect(find.byKey(ValueKey('library-item-grid-$index'))),
    ];
    for (final rect in firstRow.skip(1)) {
      expect(rect.top, closeTo(firstRow.first.top, 0.1));
    }
    final secondRow = tester.getRect(
      find.byKey(const ValueKey('library-item-grid-5')),
    );
    expect(secondRow.top, greaterThan(firstRow.first.top));
    expect(firstRow.first.top, greaterThanOrEqualTo(0));
    expect(firstRow.first.bottom, lessThanOrEqualTo(768));

    await tester.tap(find.byKey(const ValueKey('large-screen-home')));
    await tester.tap(find.byKey(const ValueKey('large-screen-search')));
    await tester.tap(find.byKey(const ValueKey('large-screen-settings')));
    await tester.tap(find.byKey(const ValueKey('large-screen-account')));
    await tester.pump();
    expect((homeCalls, searchCalls, settingsCalls, accountCalls), (1, 1, 1, 1));
    expect(tester.takeException(), isNull);
    await _dispose(tester, api);
  });

  testWidgets('mixed iPad results use typed four-by-three cards', (
    tester,
  ) async {
    _setView(tester, const Size(1024, 768));
    final api = _LayoutApi(itemCount: 8);

    await tester.pumpWidget(
      _libraryApp(
        api,
        view: _homeVideosLibrary,
        capabilities: PlatformCapabilities.ipad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LibraryMixedEntryCard), findsWidgets);
    expect(find.byType(LibraryPhotoCard), findsNothing);
    final geometry =
        tester.widget<SliverGrid>(find.byType(SliverGrid)).gridDelegate
            as LibraryGridGeometry;
    expect(geometry, isA<LibraryMixedGridGeometry>());
    expect(geometry.crossAxisCount, 5);
    expect(geometry.childAspectRatio, 4 / 3);
    expect(tester.takeException(), isNull);
    await _dispose(tester, api);
  });

  testWidgets('pure photo iPad results use square photo cards', (tester) async {
    _setView(tester, const Size(1024, 768));
    final api = _LayoutApi(itemCount: 8);

    await tester.pumpWidget(
      _libraryApp(
        api,
        view: _photoLibrary,
        capabilities: PlatformCapabilities.ipad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LibraryPhotoCard), findsWidgets);
    expect(find.byType(LibraryMixedEntryCard), findsNothing);
    final geometry =
        tester.widget<SliverGrid>(find.byType(SliverGrid)).gridDelegate
            as LibraryGridGeometry;
    expect(geometry, isA<LibraryPhotoGridGeometry>());
    expect(geometry.crossAxisCount, 5);
    expect(geometry.childAspectRatio, 1);
    expect(tester.takeException(), isNull);
    await _dispose(tester, api);
  });

  testWidgets('Android keeps compact chrome and adaptive columns', (
    tester,
  ) async {
    _setView(tester, const Size(800, 600));
    final api = _LayoutApi(itemCount: 8);
    final navigation = HomeShellNavigationActions(
      showHome: () {},
      showSearch: () {},
      openSettings: () async {},
      openAccount: () async {},
    );

    await tester.pumpWidget(
      _libraryApp(
        api,
        capabilities: PlatformCapabilities.android,
        navigationActions: navigation,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('large-screen-home')), findsNothing);
    expect(find.byKey(const ValueKey('large-screen-search')), findsNothing);
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final geometry = grid.gridDelegate as LibraryGridGeometry;
    expect(geometry.crossAxisCount, isNull);
    expect(tester.takeException(), isNull);
    await _dispose(tester, api);
  });

  for (final entry in const [
    (Size(1024, 768), 2.0),
    (Size(1366, 1024), 1.3),
    (Size(768, 1024), 2.0),
  ]) {
    testWidgets(
      'iPad library fits ${entry.$1.width}x${entry.$1.height} at ${entry.$2}x text',
      (tester) async {
        _setView(tester, entry.$1);
        final api = _LayoutApi(itemCount: 8);
        await tester.pumpWidget(
          _libraryApp(
            api,
            capabilities: PlatformCapabilities.ipad,
            textScale: entry.$2,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('library-item-grid-0')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await _dispose(tester, api);
      },
    );
  }
}

bool _isSelected(WidgetTester tester, String key) =>
    tester.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

Future<void> _finishSheetAnimation(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _dispose(
  WidgetTester tester,
  EmbyApi api, {
  LibraryLocalMediaScanService? scanService,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  if (scanService != null) {
    await scanService.cancelAll();
    scanService.dispose();
  }
  await api.dispose();
}

Widget _libraryApp(
  EmbyApi api, {
  EmbyItem view = _movieLibrary,
  LibraryBrowseState initialState = const LibraryBrowseState(),
  PlatformCapabilities capabilities = PlatformCapabilities.android,
  HomeShellNavigationActions? navigationActions,
  LibraryLocalMediaScanService? scanService,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: LibraryBrowseScreen.root(
    api: api,
    view: view,
    initialState: initialState,
    profile: LibraryContentProfile.fromCollectionType(view.collectionType),
    categorySettings: _allSettings,
    platformCapabilities: capabilities,
    navigationActions: navigationActions,
    libraryScanService: scanService,
  ),
);

class _LayoutCall {
  const _LayoutCall({required this.mediaType, required this.playedFilter});

  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
}

class _LayoutApi extends EmbyApi {
  _LayoutApi({this.itemCount = 1}) : super(_session, dio: Dio());

  final int itemCount;
  final List<_LayoutCall> calls = [];
  int scanCalls = 0;

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
    calls.add(_LayoutCall(mediaType: mediaType, playedFilter: playedFilter));
    return _page(mediaType: mediaType, profile: profile);
  }

  @override
  Future<EmbyItemPage> getLocalMediaScanCandidates({
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
    scanCalls++;
    return _page(
      mediaType: mediaType,
      profile: LibraryContentProfile.homeVideosAndPhotos,
    );
  }

  EmbyItemPage _page({
    required LibraryMediaType mediaType,
    required LibraryContentProfile profile,
  }) {
    final type =
        mediaType == LibraryMediaType.photo ||
            profile.kind == LibraryContentProfileKind.photos
        ? 'Photo'
        : 'Movie';
    final items = [
      for (var index = 0; index < itemCount; index++)
        EmbyItem(
          id: 'grid-$index',
          name: '测试项目 $index',
          type: type,
          mediaType: type == 'Photo' ? 'Photo' : 'Video',
          imageTags: const {},
          backdropImageTags: const [],
          genres: const [],
          userData: const EmbyUserData(),
        ),
    ];
    return EmbyItemPage(
      items: items,
      totalRecordCount: items.length,
      rawItemCount: items.length,
    );
  }
}

LibraryLocalMediaScanService _scanService(EmbyApi api) =>
    LibraryLocalMediaScanService(
      api: api,
      scope: ServerScope.fromSession(api.session),
      delay: (_) => Future<void>.value(),
    );

const _allSettings = LibraryCategorySettings(
  showMovies: true,
  showSeries: true,
  showVideos: true,
  showPhotos: true,
  showFavorites: true,
  showFolders: true,
);

const _movieLibrary = EmbyItem(
  id: 'library-movie',
  name: '电影',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _homeVideosLibrary = EmbyItem(
  id: 'library-homevideos',
  name: '家庭视频和照片',
  type: 'CollectionFolder',
  collectionType: 'homevideos',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _photoLibrary = EmbyItem(
  id: 'library-photos',
  name: '图片',
  type: 'CollectionFolder',
  collectionType: 'photos',
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
