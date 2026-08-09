import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_filter_test_helpers.dart';

void main() {
  testWidgets('root scope chips honor folder and favorite visibility', (
    tester,
  ) async {
    final api = _VisibilityApi();
    await tester.pumpWidget(_rootApp(api, settings: _allSettings));
    await tester.pumpAndSettle();

    expect(_scopeChip('directories'), findsOneWidget);
    expect(_scopeChip('favorites'), findsOneWidget);
    expect(_scopeChip('media'), findsOneWidget);
    expect(_scopeChip('genres'), findsOneWidget);
    expect(_scopeChip('tags'), findsOneWidget);

    await tester.pumpWidget(
      _rootApp(
        api,
        settings: _allSettings.copyWith(
          showFolders: false,
          showFavorites: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_scopeChip('directories'), findsNothing);
    expect(_scopeChip('favorites'), findsNothing);
    expect(_scopeChip('media'), findsOneWidget);
    expect(_scopeChip('genres'), findsOneWidget);
    expect(_scopeChip('tags'), findsOneWidget);
    expect(api.calls, hasLength(1));
    await _dispose(tester, api);
  });

  testWidgets('hiding the selected favorite and movie returns to media all', (
    tester,
  ) async {
    final api = _VisibilityApi();
    const initialState = LibraryBrowseState(
      scope: LibraryBrowseScope.favorites,
      mediaType: LibraryMediaType.movie,
      playedFilter: LibraryPlayedFilter.unplayed,
      localFilter: LibraryLocalMediaFilter.strm,
    );
    await tester.pumpWidget(
      _rootApp(api, settings: _allSettings, initialState: initialState),
    );
    await tester.pumpAndSettle();
    expect(api.calls.single.scope, LibraryBrowseScope.favorites);

    await tester.pumpWidget(
      _rootApp(
        api,
        settings: _allSettings.copyWith(
          showFavorites: false,
          showMovies: false,
        ),
        initialState: initialState,
      ),
    );
    await tester.pumpAndSettle();

    expect(_scopeChip('favorites'), findsNothing);
    expect(tester.widget<FilterChip>(_scopeChip('media')).selected, isTrue);
    await openLibraryFilter(tester);
    expect(_mediaTypeChip(LibraryMediaType.movie), findsNothing);
    expect(
      tester.widget<ChoiceChip>(_mediaTypeChip(LibraryMediaType.all)).selected,
      isTrue,
    );
    expect(api.calls, hasLength(2));
    expect(api.calls.last.scope, LibraryBrowseScope.media);
    expect(api.calls.last.mediaType, LibraryMediaType.all);
    expect(api.calls.last.playedFilter, LibraryPlayedFilter.unplayed);
    await _dispose(tester, api);
  });

  testWidgets('hiding the selected directory returns to media defaults', (
    tester,
  ) async {
    final api = _VisibilityApi();
    const initialState = LibraryBrowseState.directory(
      sortBy: LibrarySortBy.runtime,
      sortOrder: LibrarySortOrder.descending,
    );
    await tester.pumpWidget(
      _rootApp(api, settings: _allSettings, initialState: initialState),
    );
    await tester.pumpAndSettle();
    expect(api.calls.single.scope, LibraryBrowseScope.directory);

    await tester.pumpWidget(
      _rootApp(
        api,
        settings: _allSettings.copyWith(showFolders: false),
        initialState: initialState,
      ),
    );
    await tester.pumpAndSettle();

    expect(_scopeChip('directories'), findsNothing);
    expect(tester.widget<FilterChip>(_scopeChip('media')).selected, isTrue);
    expect(api.calls, hasLength(2));
    expect(api.calls.last.scope, LibraryBrowseScope.media);
    expect(api.calls.last.mediaType, LibraryMediaType.all);
    expect(api.calls.last.sortBy, LibrarySortBy.name);
    await _dispose(tester, api);
  });

  testWidgets('hiding a selected media type normalizes it to all', (
    tester,
  ) async {
    final api = _VisibilityApi();
    const initialState = LibraryBrowseState(mediaType: LibraryMediaType.movie);
    await tester.pumpWidget(
      _rootApp(api, settings: _allSettings, initialState: initialState),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _rootApp(
        api,
        settings: _allSettings.copyWith(showMovies: false),
        initialState: initialState,
      ),
    );
    await tester.pumpAndSettle();

    await openLibraryFilter(tester);
    expect(_mediaTypeChip(LibraryMediaType.movie), findsNothing);
    expect(
      tester.widget<ChoiceChip>(_mediaTypeChip(LibraryMediaType.all)).selected,
      isTrue,
    );
    expect(api.calls, hasLength(2));
    expect(api.calls.last.mediaType, LibraryMediaType.all);
    await _dispose(tester, api);
  });

  testWidgets('all remains usable when every optional media type is hidden', (
    tester,
  ) async {
    final api = _VisibilityApi();
    await tester.pumpWidget(
      _rootApp(api, settings: const LibraryCategorySettings()),
    );
    await tester.pumpAndSettle();

    expect(find.text('媒体类型'), findsNothing);
    expect(_mediaTypeChip(LibraryMediaType.all), findsNothing);
    expect(_mediaTypeChip(LibraryMediaType.movie), findsNothing);
    expect(_mediaTypeChip(LibraryMediaType.series), findsNothing);
    expect(_mediaTypeChip(LibraryMediaType.video), findsNothing);
    expect(api.calls.single.mediaType, LibraryMediaType.all);
    await _dispose(tester, api);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('root visibility is identical on ${platform.name}', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final api = _VisibilityApi();
        await tester.pumpWidget(
          _rootApp(
            api,
            settings: const LibraryCategorySettings(
              showFolders: false,
              showFavorites: false,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(_scopeChip('directories'), findsNothing);
        expect(_scopeChip('favorites'), findsNothing);
        expect(_scopeChip('media'), findsOneWidget);
        expect(_scopeChip('genres'), findsOneWidget);
        expect(_scopeChip('tags'), findsOneWidget);
        expect(find.text('浏览方式'), findsNothing);
        expect(
          find.byKey(const ValueKey('library-section-bar')),
          findsOneWidget,
        );
        expect(find.text('媒体类型'), findsNothing);
        expect(_mediaTypeChip(LibraryMediaType.all), findsNothing);
        await _dispose(tester, api);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('nested directory and facet pages ignore root scope visibility', (
    tester,
  ) async {
    final api = _VisibilityApi();
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.directory(
          key: const ValueKey('nested-directory'),
          api: api,
          view: _directory,
          categorySettings: const LibraryCategorySettings(
            showFolders: false,
            showFavorites: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Directory'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-section-bar')), findsNothing);
    expect(api.calls.single.scope, LibraryBrowseScope.directory);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.facet(
          key: const ValueKey('nested-facet'),
          api: api,
          view: _library,
          facet: const LibraryFacet(
            id: 'genre-1',
            name: 'Genre',
            kind: LibraryFacetKind.genre,
          ),
          categorySettings: const LibraryCategorySettings(
            showFolders: false,
            showFavorites: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Genre'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-section-bar')), findsNothing);
    expect(api.calls.last.scope, LibraryBrowseScope.facet);
    await _dispose(tester, api);
  });
}

class _VisibilityCall {
  const _VisibilityCall({
    required this.scope,
    this.mediaType = LibraryMediaType.all,
    this.playedFilter = LibraryPlayedFilter.all,
    this.sortBy = LibrarySortBy.name,
  });

  final LibraryBrowseScope scope;
  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
  final LibrarySortBy sortBy;
}

class _VisibilityApi extends EmbyApi {
  _VisibilityApi() : super(_session, dio: Dio());

  final List<_VisibilityCall> calls = [];

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
    calls.add(
      _VisibilityCall(
        scope: genreId != null || tagId != null
            ? LibraryBrowseScope.facet
            : favorites
            ? LibraryBrowseScope.favorites
            : LibraryBrowseScope.media,
        mediaType: mediaType,
        playedFilter: playedFilter,
        sortBy: sortBy,
      ),
    );
    return _page(_mediaItem);
  }

  @override
  Future<EmbyItemPage> getDirectoryChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
  }) async {
    calls.add(
      _VisibilityCall(scope: LibraryBrowseScope.directory, sortBy: sortBy),
    );
    return _page(_childDirectory);
  }
}

Widget _rootApp(
  EmbyApi api, {
  required LibraryCategorySettings settings,
  LibraryBrowseState initialState = const LibraryBrowseState(),
}) => MaterialApp(
  home: LibraryBrowseScreen.root(
    key: const ValueKey('visibility-library'),
    api: api,
    view: _library,
    categorySettings: settings,
    initialState: initialState,
  ),
);

Finder _scopeChip(String name) => find.byWidgetPredicate(
  (widget) =>
      widget is FilterChip &&
      widget.key == ValueKey<String>('library-section-$name'),
);

Finder _mediaTypeChip(LibraryMediaType mediaType) =>
    find.byKey(ValueKey<String>('library-media-type-${mediaType.name}'));

Future<void> _dispose(WidgetTester tester, EmbyApi api) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await api.dispose();
}

EmbyItemPage _page(EmbyItem item) =>
    EmbyItemPage(items: [item], totalRecordCount: 1, rawItemCount: 1);

const _allSettings = LibraryCategorySettings(
  showMovies: true,
  showSeries: true,
  showVideos: true,
  showFavorites: true,
  showFolders: true,
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
  name: 'Library',
  type: 'CollectionFolder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _directory = EmbyItem(
  id: 'directory-1',
  name: 'Directory',
  type: 'Folder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _childDirectory = EmbyItem(
  id: 'child-directory',
  name: 'Child directory',
  type: 'Folder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _mediaItem = EmbyItem(
  id: 'media-1',
  name: 'Media',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(isFavorite: true),
);
