import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_genre_resolver.dart';
import 'package:emby_my_client/library/library_root_resolver.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/home_shell.dart';
import 'package:emby_my_client/ui/home_shell_navigation.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'shared_preferences_async_test_backend.dart';

void main() {
  test(
    'genre navigation maps every resolver failure to fixed Snackbar text',
    () {
      expect(
        genreNavigationErrorMessage(
          const LibraryRootResolutionException(
            LibraryRootResolutionFailure.requestFailed,
          ),
        ),
        '分类加载失败，请重试',
      );
      for (final failure in [
        LibraryRootResolutionFailure.rootUnavailable,
        LibraryRootResolutionFailure.ancestorLoop,
        LibraryRootResolutionFailure.ancestorDepthExceeded,
      ]) {
        expect(
          genreNavigationErrorMessage(LibraryRootResolutionException(failure)),
          '无法确定该媒体所属的媒体库',
        );
      }

      for (final failure in [
        LibraryGenreResolutionFailure.requestFailed,
        LibraryGenreResolutionFailure.paginationStalled,
      ]) {
        expect(
          genreNavigationErrorMessage(LibraryGenreResolutionException(failure)),
          '分类加载失败，请重试',
        );
      }
      for (final failure in [
        LibraryGenreResolutionFailure.notFound,
        LibraryGenreResolutionFailure.ambiguous,
        LibraryGenreResolutionFailure.unsupportedProfile,
      ]) {
        expect(
          genreNavigationErrorMessage(LibraryGenreResolutionException(failure)),
          '当前媒体库没有找到该分类',
        );
      }

      expect(
        genreNavigationErrorMessage(StateError('raw error')),
        '分类加载失败，请重试',
      );
    },
  );

  testWidgets(
    'HomeShell opens one facet route with the resolved library query',
    (tester) async {
      _setViewport(tester);
      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _IntegrationApi();
      final controller = _IntegrationController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await _pumpShell(tester, controller);
      await _openResumeDetail(tester);

      final gate = Completer<EmbyItemPage>();
      api.genreGate = gate;
      final genreChip = find.byKey(const ValueKey('item-detail-genre-0'));
      await tester.ensureVisible(genreChip);
      await tester.tap(genreChip);
      await tester.pump();
      await tester.tap(genreChip);
      await tester.pump();

      expect(api.genreRequests, hasLength(1));
      gate.complete(_genrePage);
      await tester.pumpAndSettle();

      expect(find.byType(LibraryBrowseScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Sci-Fi & Fantasy'), findsOneWidget);
      expect(api.genreRequests.single.parentId, 'library-1');
      expect(api.genreRequests.single.startIndex, 0);
      expect(api.mediaRequests, hasLength(1));
      expect(api.mediaRequests.single.parentId, 'library-1');
      expect(api.mediaRequests.single.genreId, 'genre-1');
      expect(api.mediaRequests.single.startIndex, 0);
    },
  );

  testWidgets(
    'pending genre navigation cannot cover the real player route',
    skip: Platform.isWindows,
    (tester) async {
      MediaKit.ensureInitialized();
      _setViewport(tester);
      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _IntegrationApi();
      final controller = _IntegrationController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await _pumpShell(tester, controller);
      await _openResumeDetail(tester);

      final gate = Completer<EmbyItemPage>();
      api.genreGate = gate;
      await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
      await tester.pump();
      expect(api.genreRequests, hasLength(1));

      await tester.tap(find.text('播放'));
      await tester.pump();
      expect(find.byType(PlayerScreen), findsOneWidget);

      gate.complete(_genrePage);
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(LibraryBrowseScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryBrowseScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'facet detail playback returns with pagination and position intact',
    skip: Platform.isWindows,
    (tester) async {
      MediaKit.ensureInitialized();
      _setViewport(tester);
      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _IntegrationApi(largeFacetResult: true);
      final controller = _IntegrationController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await _pumpShell(tester, controller);
      await _openResumeDetail(tester);
      await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
      await tester.pumpAndSettle();
      final scrollable = _verticalScrollable();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-item-facet-media-60')),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;
      expect(api.mediaRequests.map((request) => request.startIndex), [0, 60]);

      await tester.tap(
        find.byKey(const ValueKey('library-item-facet-media-60')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailScreen), findsOneWidget);

      await tester.tap(find.text('播放'));
      await tester.pump();
      expect(find.byType(PlayerScreen), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LibraryBrowseScreen), findsOneWidget);
      expect(api.mediaRequests.map((request) => request.startIndex), [0, 60]);
      expect(position.pixels, closeTo(before, 1));
      expect(
        find.byKey(const ValueKey('library-item-facet-media-60')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'facet play all returns directly to the preserved facet route',
    skip: Platform.isWindows,
    (tester) async {
      MediaKit.ensureInitialized();
      _setViewport(tester);
      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _IntegrationApi(largeFacetResult: true);
      final controller = _IntegrationController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await _pumpShell(tester, controller);
      await _openResumeDetail(tester);
      await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
      await tester.pumpAndSettle();
      final scrollable = _verticalScrollable();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-item-facet-media-60')),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;
      final playAll = find.byKey(const ValueKey('library-play-all-button'));
      await tester.ensureVisible(playAll);
      await tester.tap(playAll);
      await tester.pumpAndSettle();

      expect(find.byType(ItemDetailScreen), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byType(LibraryBrowseScreen), findsOneWidget);
      expect(api.mediaRequests.map((request) => request.startIndex), [0, 60]);
      expect(position.pixels, closeTo(before, 1));
      expect(
        find.byKey(const ValueKey('library-item-facet-media-60')),
        findsOneWidget,
      );
    },
  );

  testWidgets('library changes invalidate root and genre navigation caches', (
    tester,
  ) async {
    _setViewport(tester);
    final preferences = SharedPreferencesAsyncTestBackend.install();
    addTearDown(preferences.restore);
    final api = _IntegrationApi();
    final controller = _IntegrationController(api);
    addTearDown(controller.dispose);
    addTearDown(api.dispose);
    addTearDown(api.realtime.stop);

    await _pumpShell(tester, controller);
    await _openResumeDetail(tester);
    await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
    await tester.pumpAndSettle();
    expect(api.genreRequests, hasLength(1));
    expect(api.genreRequests.single.parentId, 'library-1');
    expect(api.mediaRequests.single.parentId, 'library-1');
    expect(api.mediaRequests.single.genreId, 'genre-1');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await api.realtime.start();
    api.libraryVersion = 2;
    api.realtimeSocket.emitLibraryChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
    await tester.pumpAndSettle();
    expect(api.genreRequests, hasLength(2));
    expect(api.genreRequests.last.parentId, 'library-2');
    expect(api.mediaRequests.last.parentId, 'library-2');
    expect(api.mediaRequests.last.genreId, 'genre-2');
    expect(api.viewRequests, greaterThan(1));
    await tester.runAsync(api.realtime.stop);
  });

  testWidgets(
    'facet pagination and scroll position survive a detail round trip',
    (tester) async {
      _setViewport(tester);
      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _IntegrationApi(largeFacetResult: true);
      final controller = _IntegrationController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await _pumpShell(tester, controller);
      await _openResumeDetail(tester);
      await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
      await tester.pumpAndSettle();

      final scrollable = _verticalScrollable();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-item-facet-media-55')),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(api.mediaRequests.map((request) => request.startIndex), [0, 60]);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-item-facet-media-60')),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;

      await tester.tap(
        find.byKey(const ValueKey('library-item-facet-media-60')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(LibraryBrowseScreen), findsOneWidget);
      expect(api.mediaRequests.map((request) => request.startIndex), [0, 60]);
      expect(position.pixels, closeTo(before, 1));
      expect(
        find.byKey(const ValueKey('library-item-facet-media-60')),
        findsOneWidget,
      );
    },
  );
}

Future<void> _pumpShell(
  WidgetTester tester,
  _IntegrationController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      navigatorObservers: [homeShellRouteObserver],
      home: HomeShell(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openResumeDetail(WidgetTester tester) async {
  expect(find.byType(MediaLandscapeCard), findsOneWidget);
  await tester.tap(find.byType(MediaLandscapeCard));
  await tester.pumpAndSettle();
  expect(find.byType(ItemDetailScreen), findsOneWidget);
}

Finder _verticalScrollable() => find.byType(Scrollable).first;

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _IntegrationController extends AppController {
  _IntegrationController(this._integrationApi)
    : super(
        capabilities: PlatformCapabilities.ipad,
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
      );

  final EmbyApi _integrationApi;

  @override
  EmbyApi get api => _integrationApi;

  @override
  EmbySession? get session => _session;
}

class _IntegrationApi extends EmbyApi {
  factory _IntegrationApi({bool largeFacetResult = false}) =>
      _IntegrationApi._(largeFacetResult, _IntegrationSocket());

  _IntegrationApi._(this.largeFacetResult, this.realtimeSocket)
    : super(
        _session,
        dio: _integrationDio(),
        realtimeConnector: (_) async => realtimeSocket,
      );

  final bool largeFacetResult;
  final _IntegrationSocket realtimeSocket;
  final genreRequests = <_GenreRequest>[];
  final mediaRequests = <_MediaRequest>[];
  Completer<EmbyItemPage>? genreGate;
  int libraryVersion = 1;
  int viewRequests = 0;

  String get currentLibraryId => 'library-$libraryVersion';
  String get currentGenreId => 'genre-$libraryVersion';

  @override
  Future<HomeData> getHomeBase() async =>
      const HomeData(views: [_library], resume: [_resume], latestSections: []);

  @override
  Future<HomeLatestSection?> getHomeLatestSection(EmbyItem library) async =>
      null;

  @override
  Future<List<EmbyItem>> getViews() async {
    viewRequests++;
    return [_libraryFor(currentLibraryId)];
  }

  @override
  Future<EmbyItem> getItem(String itemId) async {
    if (itemId == _resume.id) return _resume;
    if (itemId == _folder.id) return _folderFor(currentLibraryId);
    if (itemId.startsWith('facet-media-')) {
      return _facetItem(itemId, parentId: currentLibraryId);
    }
    return _resume;
  }

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
    final gate = genreGate;
    if (gate != null) {
      genreGate = null;
      return gate.future;
    }
    return EmbyItemPage(
      items: [
        EmbyItem(
          id: currentGenreId,
          name: 'Sci-Fi & Fantasy',
          type: 'Genre',
          imageTags: const {},
          backdropImageTags: const [],
          genres: const [],
          userData: const EmbyUserData(),
        ),
      ],
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
    if (!largeFacetResult) {
      return EmbyItemPage(
        items: [_facetItem('facet-media-0', parentId: currentLibraryId)],
        rawItemCount: 1,
        totalRecordCount: 1,
      );
    }
    if (startIndex == 0) {
      return EmbyItemPage(
        items: [
          for (var index = 0; index < 60; index++)
            _facetItem('facet-media-$index', parentId: currentLibraryId),
        ],
        rawItemCount: 60,
        totalRecordCount: 61,
      );
    }
    if (startIndex == 60) {
      return EmbyItemPage(
        items: [_facetItem('facet-media-60', parentId: currentLibraryId)],
        rawItemCount: 1,
        totalRecordCount: 61,
      );
    }
    return const EmbyItemPage(items: [], totalRecordCount: 61);
  }

  @override
  Future<Map<String, EmbyUserData>> getUserDataForItems(
    Iterable<String> itemIds,
  ) async => const {};
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

Dio _integrationDio() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(requestOptions: options, statusCode: 204),
        );
      },
    ),
  );

class _IntegrationSocket implements EmbySocket {
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
          'ItemsUpdated': ['resume-1'],
        },
      }),
    );
  }

  @override
  void add(String data) {}

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    unawaited(_messages.close());
    return Future<void>.value();
  }
}

EmbyItem _libraryFor(String id) => EmbyItem(
  id: id,
  name: 'Movies',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

EmbyItem _folderFor(String parentId) => EmbyItem(
  id: _folder.id,
  name: _folder.name,
  type: _folder.type,
  parentId: parentId,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

EmbyItem _facetItem(String id, {required String parentId}) => EmbyItem(
  id: id,
  name: id,
  type: 'Movie',
  parentId: parentId,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

const _genrePage = EmbyItemPage(
  items: [_genre],
  rawItemCount: 1,
  totalRecordCount: 1,
);

const _genre = EmbyItem(
  id: 'genre-1',
  name: 'Sci-Fi & Fantasy',
  type: 'Genre',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _library = EmbyItem(
  id: 'library-1',
  name: 'Movies',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _folder = EmbyItem(
  id: 'folder-1',
  name: 'Movies Folder',
  type: 'Folder',
  parentId: 'library-1',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _resume = EmbyItem(
  id: 'resume-1',
  name: 'Resume Movie',
  type: 'Movie',
  parentId: 'folder-1',
  imageTags: {},
  backdropImageTags: [],
  genres: ['Sci-Fi & Fantasy'],
  userData: EmbyUserData(playbackPositionTicks: 1),
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
