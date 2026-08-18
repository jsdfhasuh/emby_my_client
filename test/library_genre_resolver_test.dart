import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_genre_resolver.dart';
import 'package:emby_my_client/library/library_navigation_context.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('advances the genre cursor by raw item count', () async {
    final firstPage = EmbyItemPage(
      items: [
        for (var index = 0; index < 60; index++)
          _term('noise-$index', 'Noise $index'),
      ],
      rawItemCount: 60,
      totalRecordCount: 61,
    );
    final secondPage = EmbyItemPage(
      items: [_term('genre-1', 'Sci-Fi & Fantasy')],
      rawItemCount: 1,
      totalRecordCount: 61,
    );
    final api = _GenreApi(pages: {0: firstPage, 60: secondPage});
    addTearDown(api.dispose);

    final facet = await LibraryGenreResolver(
      api: api,
    ).resolve(origin: _origin, genreName: 'Sci-Fi & Fantasy');

    expect(
      facet,
      const LibraryFacet(
        id: 'genre-1',
        name: 'Sci-Fi & Fantasy',
        kind: LibraryFacetKind.genre,
      ),
    );
    expect(api.starts, [0, 60]);
    expect(api.parentIds, ['library-1', 'library-1']);
    expect(api.limits, [60, 60]);
    expect(api.profiles, [
      LibraryContentProfile.movies,
      LibraryContentProfile.movies,
    ]);
  });

  test('re-reads the index when the first lookup misses', () async {
    var pageLoaderCalls = 0;
    final api = _GenreApi(
      pageLoader: (_) {
        pageLoaderCalls++;
        return pageLoaderCalls == 1
            ? EmbyItemPage(
                items: [_term('old-id', 'Other')],
                rawItemCount: 1,
                totalRecordCount: 1,
              )
            : EmbyItemPage(
                items: [_term('genre-1', 'Drama')],
                rawItemCount: 1,
                totalRecordCount: 1,
              );
      },
    );
    addTearDown(api.dispose);

    final facet = await LibraryGenreResolver(
      api: api,
    ).resolve(origin: _origin, genreName: 'Drama');

    expect(facet.id, 'genre-1');
    expect(api.starts, [0, 0]);
  });

  test(
    'rejects ambiguous normalized names instead of choosing an ID',
    () async {
      final api = _GenreApi(
        pages: {
          0: EmbyItemPage(
            items: [
              _term('genre-a', 'Sci-Fi   & Fantasy'),
              _term('genre-b', ' sci-fi & fantasy '),
            ],
            rawItemCount: 2,
            totalRecordCount: 2,
          ),
        },
      );
      addTearDown(api.dispose);

      await expectLater(
        LibraryGenreResolver(
          api: api,
        ).resolve(origin: _origin, genreName: 'Sci-Fi & Fantasy'),
        throwsA(
          isA<LibraryGenreResolutionException>().having(
            (error) => error.failure,
            'failure',
            LibraryGenreResolutionFailure.ambiguous,
          ),
        ),
      );
    },
  );

  test('rejects fuzzy substring matches and reports a miss', () async {
    final api = _GenreApi(
      pages: {
        0: EmbyItemPage(
          items: [_term('genre-1', 'Science Fiction')],
          rawItemCount: 1,
          totalRecordCount: 1,
        ),
      },
    );
    addTearDown(api.dispose);

    await expectLater(
      LibraryGenreResolver(
        api: api,
      ).resolve(origin: _origin, genreName: 'Science'),
      throwsA(
        isA<LibraryGenreResolutionException>().having(
          (error) => error.failure,
          'failure',
          LibraryGenreResolutionFailure.notFound,
        ),
      ),
    );
    expect(api.starts, [0, 0]);
  });

  test('fails when a genre page does not advance its raw cursor', () async {
    final api = _GenreApi(
      pages: {
        0: EmbyItemPage(items: const [], rawItemCount: 0, totalRecordCount: 1),
      },
    );
    addTearDown(api.dispose);

    await expectLater(
      LibraryGenreResolver(
        api: api,
      ).resolve(origin: _origin, genreName: 'Drama'),
      throwsA(
        isA<LibraryGenreResolutionException>().having(
          (error) => error.failure,
          'failure',
          LibraryGenreResolutionFailure.paginationStalled,
        ),
      ),
    );
    expect(api.starts, [0]);
  });

  test('does not query profiles that do not support genres', () async {
    final api = _GenreApi(pages: const {});
    addTearDown(api.dispose);
    const origin = LibraryBrowseOrigin(
      rootView: _photoLibrary,
      profile: LibraryContentProfile.photos,
    );

    await expectLater(
      LibraryGenreResolver(
        api: api,
      ).resolve(origin: origin, genreName: 'Photos'),
      throwsA(
        isA<LibraryGenreResolutionException>().having(
          (error) => error.failure,
          'failure',
          LibraryGenreResolutionFailure.unsupportedProfile,
        ),
      ),
    );
    expect(api.starts, isEmpty);
  });
}

class _GenreApi extends EmbyApi {
  _GenreApi({this.pages = const {}, this.pageLoader})
    : super(_session, dio: Dio());

  final Map<int, EmbyItemPage> pages;
  final EmbyItemPage Function(int startIndex)? pageLoader;
  final starts = <int>[];
  final parentIds = <String>[];
  final limits = <int>[];
  final profiles = <LibraryContentProfile>[];

  @override
  Future<EmbyItemPage> getLibraryGenres({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
    int startIndex = 0,
    int limit = 60,
  }) async {
    starts.add(startIndex);
    parentIds.add(parentId);
    limits.add(limit);
    profiles.add(profile);
    return pageLoader?.call(startIndex) ??
        pages[startIndex] ??
        const EmbyItemPage(items: [], rawItemCount: 0, totalRecordCount: 0);
  }
}

LibraryBrowseOrigin get _origin => const LibraryBrowseOrigin(
  rootView: _movieLibrary,
  profile: LibraryContentProfile.movies,
);

EmbyItem _term(String id, String name) => EmbyItem(
  id: id,
  name: name,
  type: 'Genre',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

const _movieLibrary = EmbyItem(
  id: 'library-1',
  name: 'Movies',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _photoLibrary = EmbyItem(
  id: 'photos-1',
  name: 'Photos',
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
