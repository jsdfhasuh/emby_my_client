import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
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

    final page = await api.getLibraryMediaItems(parentId: 'library-1');
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
    expect(query['IncludeItemTypes'], 'Movie,Series,Video');
    expect(query['SortBy'], 'SortName');
    expect(query['SortOrder'], 'Ascending');
    expect(query['Fields'], allOf(contains('Path'), contains('MediaSources')));
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
        startIndex: 60,
        limit: 30,
        mediaType: LibraryMediaType.movie,
        playedFilter: LibraryPlayedFilter.unplayed,
        favorites: true,
        sortBy: LibrarySortBy.dateAdded,
        sortOrder: LibrarySortOrder.descending,
        alphabetFilter: LetterItems('m'),
        genreId: 'genre-1',
      );
      await api.getLibraryMediaItems(
        parentId: 'library-1',
        tagId: 'tag-1',
        alphabetFilter: const SymbolsItems(),
      );

      final genre = requests.first.queryParameters;
      expect(genre['StartIndex'], 60);
      expect(genre['Limit'], 30);
      expect(genre['IncludeItemTypes'], 'Movie');
      expect(genre['Filters'], 'IsFavorite,IsUnplayed');
      expect(genre, isNot(contains('IsFavorite')));
      expect(genre['SortBy'], 'DateCreated');
      expect(genre['SortOrder'], 'Descending');
      expect(genre['NameStartsWith'], 'M');
      expect(genre, isNot(contains('NameLessThan')));
      expect(genre['GenreIds'], 'genre-1');
      expect(genre, isNot(contains('TagIds')));

      final tag = requests.last.queryParameters;
      expect(tag['TagIds'], 'tag-1');
      expect(tag['NameLessThan'], 'A');
      expect(tag, isNot(contains('GenreIds')));
      expect(tag, isNot(contains('NameStartsWith')));

      await expectLater(
        api.getLibraryMediaItems(
          parentId: 'library-1',
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
      sortBy: LibrarySortBy.productionYear,
      sortOrder: LibrarySortOrder.descending,
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
      'Folder,CollectionFolder,Movie,Series,Episode,Video',
    );
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

  test('genre and tag index queries keep their exact term shape', () async {
    final requests = <RequestOptions>[];
    final api = _api((options, handler) {
      requests.add(options);
      handler.resolve(_response(options));
    });
    addTearDown(api.dispose);

    await api.getLibraryGenres(parentId: 'library-1', startIndex: 4, limit: 10);
    await api.getLibraryTags(parentId: 'library-1', startIndex: 14, limit: 20);

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
      expect(query['IncludeItemTypes'], 'Movie,Series,Video');
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
      await api.getLibraryMediaItems(parentId: 'library-1'),
      await api.getDirectoryChildren(parentId: 'library-1'),
      await api.getLibraryGenres(parentId: 'library-1'),
      await api.getLibraryTags(parentId: 'library-1'),
    ];

    for (final page in pages) {
      expect(page.rawItemCount, 4);
      expect(page.items.map((item) => item.id), ['same', 'same']);
      expect(page.totalRecordCount, 4);
    }
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
