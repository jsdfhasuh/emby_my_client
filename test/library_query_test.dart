import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/models/emby_models.dart' show EmbySession;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('media query has the exact approved default shape', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    final page = await api.getLibraryMediaItems(
      parentId: 'library-1',
      profile: LibraryContentProfile.movies,
    );
    final query = captured!.queryParameters;

    expect(captured!.path, '/Users/user-1/Items');
    expect(query.keys.toSet(), {
      'ParentId',
      'StartIndex',
      'Limit',
      'Recursive',
      'IncludeItemTypes',
      'SortBy',
      'SortOrder',
      'Fields',
      'EnableUserData',
      'EnableImages',
      'EnableTotalRecordCount',
    });
    expect(query['ParentId'], 'library-1');
    expect(query['StartIndex'], 0);
    expect(query['Limit'], 60);
    expect(query['Recursive'], isTrue);
    expect(query['IncludeItemTypes'], 'Movie');
    expect(query['SortBy'], 'SortName');
    expect(query['SortOrder'], 'Ascending');
    expect(query['Fields'], allOf(contains('Path'), contains('MediaSources')));
    expect(query['EnableUserData'], isTrue);
    expect(page.rawItemCount, 1);
  });

  test(
    'favorites, played, media type and facet form one media query',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_response(options));
      });
      addTearDown(api.dispose);

      await api.getLibraryMediaItems(
        parentId: 'library-1',
        profile: LibraryContentProfile.mixed,
        startIndex: 60,
        limit: 30,
        mediaType: LibraryMediaType.movie,
        playedFilter: LibraryPlayedFilter.unplayed,
        favorites: true,
        sortBy: LibrarySortBy.playCount,
        sortOrder: LibrarySortOrder.descending,
        alphabetFilter: LetterItems('m'),
        genreId: 'genre-1',
      );
      await api.getLibraryMediaItems(
        parentId: 'library-1',
        profile: LibraryContentProfile.mixed,
        startIndex: 60,
        limit: 30,
        mediaType: LibraryMediaType.movie,
        playedFilter: LibraryPlayedFilter.played,
        tagId: 'tag-1',
        sortBy: LibrarySortBy.playCount,
        sortOrder: LibrarySortOrder.ascending,
        alphabetFilter: const SymbolsItems(),
      );

      final genre = requests.first.queryParameters;
      expect(genre['StartIndex'], 60);
      expect(genre['Limit'], 30);
      expect(genre['IncludeItemTypes'], 'Movie');
      expect(genre['Filters'], 'IsFavorite,IsUnplayed');
      expect(genre, isNot(contains('IsFavorite')));
      expect(genre['SortBy'], 'PlayCount');
      expect(genre['SortOrder'], 'Descending');
      expect(genre['EnableUserData'], isTrue);
      expect(genre['NameStartsWith'], 'M');
      expect(genre, isNot(contains('NameLessThan')));
      expect(genre['GenreIds'], 'genre-1');
      expect(genre, isNot(contains('TagIds')));

      final tag = requests.last.queryParameters;
      expect(tag['StartIndex'], 60);
      expect(tag['Limit'], 30);
      expect(tag['Filters'], 'IsPlayed');
      expect(tag['TagIds'], 'tag-1');
      expect(tag['SortBy'], 'PlayCount');
      expect(tag['SortOrder'], 'Ascending');
      expect(tag['EnableUserData'], isTrue);
      expect(tag['NameLessThan'], 'A');
      expect(tag, isNot(contains('GenreIds')));
      expect(tag, isNot(contains('NameStartsWith')));

      await expectLater(
        api.getLibraryMediaItems(
          parentId: 'library-1',
          profile: LibraryContentProfile.mixed,
          genreId: 'genre-1',
          tagId: 'tag-1',
        ),
        throwsArgumentError,
      );
      expect(requests, hasLength(2));
    },
  );

  test('directory query has only hierarchy-safe parameters', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    await api.getDirectoryChildren(
      parentId: 'folder-1',
      startIndex: 12,
      limit: 24,
      sortBy: LibrarySortBy.playCount,
      sortOrder: LibrarySortOrder.ascending,
    );
    final query = captured!.queryParameters;

    expect(query.keys.toSet(), {
      'ParentId',
      'StartIndex',
      'Limit',
      'Recursive',
      'IncludeItemTypes',
      'SortBy',
      'SortOrder',
      'Fields',
      'EnableUserData',
      'EnableImages',
      'EnableTotalRecordCount',
    });
    expect(query['ParentId'], 'folder-1');
    expect(query['StartIndex'], 12);
    expect(query['Limit'], 24);
    expect(query['Recursive'], isFalse);
    expect(
      query['IncludeItemTypes'],
      'Folder,CollectionFolder,PhotoAlbum,Movie,Series,Episode,Video,Photo',
    );
    expect(query['SortBy'], 'PlayCount');
    expect(query['SortOrder'], 'Ascending');
    expect(query['EnableUserData'], isTrue);
    for (final forbidden in [
      'Filters',
      'IsFavorite',
      'IsPlayed',
      'IsUnplayed',
      'NameStartsWith',
      'NameLessThan',
      'GenreIds',
      'TagIds',
    ]) {
      expect(query, isNot(contains(forbidden)));
    }
  });

  test('local source scan carries play count in both directions', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    await api.getLocalMediaScanCandidates(
      parentId: 'library-1',
      sortBy: LibrarySortBy.playCount,
      sortOrder: LibrarySortOrder.ascending,
    );
    await api.getLocalMediaScanCandidates(
      parentId: 'library-1',
      sortBy: LibrarySortBy.playCount,
      sortOrder: LibrarySortOrder.descending,
    );

    expect(requests.map((request) => request.queryParameters['SortBy']), [
      'PlayCount',
      'PlayCount',
    ]);
    expect(requests.map((request) => request.queryParameters['SortOrder']), [
      'Ascending',
      'Descending',
    ]);
    expect(
      requests.every(
        (request) => request.queryParameters['EnableUserData'] == true,
      ),
      isTrue,
    );
  });

  test('local source scan query uses only source-bearing candidates', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 37,
            'Items': [_item('candidate-1')],
          },
        ),
      );
    });
    addTearDown(api.dispose);

    for (final parentId in ['homevideos-1', 'mixed-1']) {
      final page = await api.getLocalMediaScanCandidates(
        parentId: parentId,
        startIndex: 60,
        limit: 30,
        favorites: true,
        playedFilter: LibraryPlayedFilter.unplayed,
        sortBy: LibrarySortBy.playCount,
        sortOrder: LibrarySortOrder.descending,
        alphabetFilter: LetterItems('m'),
        genreId: 'genre-1',
      );
      expect(page.totalRecordCount, 37);
      expect(page.rawItemCount, 1);
    }

    for (final request in requests) {
      final query = request.queryParameters;
      expect(request.path, '/Users/user-1/Items');
      expect(query['Recursive'], isTrue);
      expect(query['IncludeItemTypes'], 'Movie,Episode,Video');
      expect(query['IncludeItemTypes'], isNot(contains('Photo')));
      expect(query['IncludeItemTypes'], isNot(contains('Series')));
      expect(query['Filters'], 'IsFavorite,IsUnplayed');
      expect(query['SortBy'], 'PlayCount');
      expect(query['SortOrder'], 'Descending');
      expect(query['NameStartsWith'], 'M');
      expect(query['GenreIds'], 'genre-1');
      expect(query['Fields'], contains('Path'));
      expect(query['Fields'], contains('Container'));
      expect(query['Fields'], contains('MediaSources'));
      expect(query['EnableTotalRecordCount'], isTrue);
      expect(query['EnableUserData'], isTrue);
    }
  });

  test('local source scan media types use a strict intersection', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    await api.getLocalMediaScanCandidates(
      parentId: 'library-1',
      mediaType: LibraryMediaType.movie,
    );
    await api.getLocalMediaScanCandidates(
      parentId: 'library-1',
      mediaType: LibraryMediaType.video,
    );
    expect(
      requests.map((request) => request.queryParameters['IncludeItemTypes']),
      ['Movie', 'Video'],
    );

    for (final unsupported in [
      LibraryMediaType.series,
      LibraryMediaType.photo,
    ]) {
      await expectLater(
        api.getLocalMediaScanCandidates(
          parentId: 'library-1',
          mediaType: unsupported,
        ),
        throwsArgumentError,
      );
    }
    expect(requests, hasLength(2));
  });

  test('genre and tag index queries keep their exact term shape', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    await api.getLibraryGenres(
      parentId: 'library-1',
      profile: LibraryContentProfile.homeVideosAndPhotos,
      startIndex: 4,
      limit: 10,
    );
    await api.getLibraryTags(
      parentId: 'library-1',
      profile: LibraryContentProfile.homeVideosAndPhotos,
      startIndex: 14,
      limit: 20,
    );

    expect(requests.map((request) => request.path), ['/Genres', '/Tags']);
    for (final request in requests) {
      final query = request.queryParameters;
      expect(query.keys.toSet(), {
        'UserId',
        'ParentId',
        'StartIndex',
        'Limit',
        'Recursive',
        'IncludeItemTypes',
        'SortBy',
        'SortOrder',
        'Fields',
        'EnableImages',
        'EnableTotalRecordCount',
      });
      expect(query['Recursive'], isTrue);
      expect(query['IncludeItemTypes'], 'Movie,Video,Photo');
      expect(query['SortBy'], 'SortName');
      expect(query['SortOrder'], 'Ascending');
      expect(query, isNot(contains('Filters')));
    }
  });

  test('all explicit library pages retain the raw response count', () async {
    final api = _api((options, handler) {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: {
            'TotalRecordCount': 4,
            'Items': [_item('same'), _item('same'), _item(''), 'not-a-map'],
          },
        ),
      );
    });
    addTearDown(api.dispose);

    final pages = [
      await api.getLibraryMediaItems(
        parentId: 'library-1',
        profile: LibraryContentProfile.mixed,
      ),
      await api.getDirectoryChildren(parentId: 'library-1'),
      await api.getLibraryGenres(
        parentId: 'library-1',
        profile: LibraryContentProfile.mixed,
      ),
      await api.getLibraryTags(
        parentId: 'library-1',
        profile: LibraryContentProfile.mixed,
      ),
      await api.getLocalMediaScanCandidates(parentId: 'library-1'),
    ];

    for (final page in pages) {
      expect(page.rawItemCount, 4);
      expect(page.items.map((item) => item.id), ['same', 'same']);
      expect(page.totalRecordCount, 4);
    }
  });

  test('home video and photo media queries use exact profile types', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    for (final mediaType in <LibraryMediaType>[
      LibraryMediaType.all,
      LibraryMediaType.video,
      LibraryMediaType.photo,
    ]) {
      await api.getLibraryMediaItems(
        parentId: 'library-1',
        profile: LibraryContentProfile.homeVideosAndPhotos,
        mediaType: mediaType,
      );
    }

    expect(
      requests.map((request) => request.queryParameters['IncludeItemTypes']),
      ['Movie,Video,Photo', 'Video', 'Photo'],
    );
    await expectLater(
      api.getLibraryMediaItems(
        parentId: 'library-1',
        profile: LibraryContentProfile.homeVideosAndPhotos,
        mediaType: LibraryMediaType.series,
      ),
      throwsArgumentError,
    );

    await api.getLibraryMediaItems(
      parentId: 'mixed-1',
      profile: LibraryContentProfile.mixed,
    );
    expect(
      requests.last.queryParameters['IncludeItemTypes'],
      'Movie,Series,Video,Photo',
    );
  });

  test(
    'photo queries preserve pure, favorite, genre and tag semantics',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_response(options));
      });
      addTearDown(api.dispose);

      await api.getLibraryMediaItems(
        parentId: 'photos-1',
        profile: LibraryContentProfile.photos,
      );
      await api.getLibraryMediaItems(
        parentId: 'mixed-1',
        profile: LibraryContentProfile.mixed,
        mediaType: LibraryMediaType.photo,
        favorites: true,
      );
      await api.getLibraryMediaItems(
        parentId: 'mixed-1',
        profile: LibraryContentProfile.mixed,
        mediaType: LibraryMediaType.photo,
        genreId: 'genre-1',
      );
      await api.getLibraryMediaItems(
        parentId: 'mixed-1',
        profile: LibraryContentProfile.mixed,
        mediaType: LibraryMediaType.photo,
        tagId: 'tag-1',
      );

      final pure = requests[0].queryParameters;
      expect(pure['Recursive'], isTrue);
      expect(pure['IncludeItemTypes'], 'Photo');
      expect(pure, isNot(contains('Filters')));

      final favorite = requests[1].queryParameters;
      expect(favorite['IncludeItemTypes'], 'Photo');
      expect(favorite['Filters'], 'IsFavorite');
      expect(favorite, isNot(contains('GenreIds')));
      expect(favorite, isNot(contains('TagIds')));

      final genre = requests[2].queryParameters;
      expect(genre['IncludeItemTypes'], 'Photo');
      expect(genre['GenreIds'], 'genre-1');
      expect(genre, isNot(contains('Filters')));
      expect(genre, isNot(contains('TagIds')));

      final tag = requests[3].queryParameters;
      expect(tag['IncludeItemTypes'], 'Photo');
      expect(tag['TagIds'], 'tag-1');
      expect(tag, isNot(contains('Filters')));
      expect(tag, isNot(contains('GenreIds')));
    },
  );

  test('photo query is explicit and retains raw response count', () async {
    RequestOptions? captured;
    final api = _api((options, handler) {
      captured = options;
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    final page = await api.getPhotoItems(
      parentId: 'album-1',
      startIndex: 60,
      limit: 30,
      recursive: false,
    );

    expect(captured!.queryParameters['IncludeItemTypes'], 'Photo');
    expect(captured!.queryParameters['Recursive'], isFalse);
    expect(captured!.queryParameters['StartIndex'], 60);
    expect(page.rawItemCount, 1);
  });
}

EmbyApi _api(
  void Function(RequestOptions options, RequestInterceptorHandler handler)
  onRequest,
) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return EmbyApi(_session, dio: dio);
}

Response<dynamic> _response(RequestOptions options) => Response<dynamic>(
  requestOptions: options,
  statusCode: 200,
  data: {
    'TotalRecordCount': 1,
    'Items': [_item('item-1')],
  },
);

Map<String, dynamic> _item(String id) => {
  'Id': id,
  'Name': 'Item',
  'Type': 'Movie',
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
