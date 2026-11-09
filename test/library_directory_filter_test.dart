import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_directory_filter.dart';
import 'package:emby_my_client/library/library_raw_page_cursor.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an unfiltered directory keeps the original page and raw metadata', () {
    final page = EmbyItemPage(
      items: [_item('Photo'), _item('Unknown')],
      rawItemCount: 3,
      totalRecordCount: 95,
    );

    expect(
      filterLibraryDirectoryPage(page, const LibraryBrowseState.directory()),
      same(page),
    );
  });

  test('every child directory remains navigable through every filter', () {
    for (final type in ['Folder', 'CollectionFolder', 'PhotoAlbum']) {
      for (final played in [false, true]) {
        final item = _item(type, data: EmbyUserData(isPlayed: played));
        for (final mediaType in LibraryMediaType.values) {
          for (final playedFilter in LibraryPlayedFilter.values) {
            expect(
              libraryDirectoryItemMatches(
                item,
                _state(mediaType: mediaType, playedFilter: playedFilter),
              ),
              isTrue,
              reason: '$type / $mediaType / $playedFilter',
            );
          }
        }
      }
    }
  });

  test('media types filter leaves without changing their order', () {
    final page = EmbyItemPage(
      items: [
        _item('Photo', id: 'photo-before'),
        _item('Movie'),
        _item('Folder'),
        _item('Video'),
        _item('Series'),
        _item('Photo', id: 'photo-after'),
        _item('Episode'),
      ],
    );
    final expected = {
      LibraryMediaType.movie: ['Movie', 'Folder'],
      LibraryMediaType.series: ['Folder', 'Series'],
      LibraryMediaType.video: ['Folder', 'Video'],
      LibraryMediaType.photo: ['photo-before', 'Folder', 'photo-after'],
    };
    for (final entry in expected.entries) {
      expect(
        filterLibraryDirectoryPage(
          page,
          _state(mediaType: entry.key),
        ).items.map((item) => item.id),
        entry.value,
      );
    }
  });

  test('watch filters distinguish progress and give Played precedence', () {
    final page = EmbyItemPage(
      items: [
        _item('Video', id: 'new'),
        _item(
          'Video',
          id: 'position-only',
          data: const EmbyUserData(playbackPositionTicks: 20000000),
        ),
        _item(
          'Video',
          id: 'percentage-only',
          data: const EmbyUserData(playedPercentage: 25),
        ),
        _item(
          'Video',
          id: 'watched-replaying',
          data: const EmbyUserData(
            isPlayed: true,
            playbackPositionTicks: 20000000,
            playedPercentage: 25,
          ),
        ),
      ],
    );

    expect(
      filterLibraryDirectoryPage(
        page,
        _state(playedFilter: LibraryPlayedFilter.inProgress),
      ).items.map((item) => item.id),
      ['position-only', 'percentage-only'],
    );
    expect(
      filterLibraryDirectoryPage(
        page,
        _state(playedFilter: LibraryPlayedFilter.unplayed),
      ).items.map((item) => item.id),
      ['new', 'position-only', 'percentage-only'],
    );
    expect(
      filterLibraryDirectoryPage(
        page,
        _state(playedFilter: LibraryPlayedFilter.played),
      ).items.map((item) => item.id),
      ['watched-replaying'],
    );
  });

  test('photos have viewed state without becoming in-progress videos', () {
    final page = EmbyItemPage(
      items: [
        _item(
          'Photo',
          id: 'unviewed',
          data: const EmbyUserData(
            playedPercentage: 40,
            playbackPositionTicks: 100,
          ),
        ),
        _item('Photo', id: 'viewed', data: const EmbyUserData(isPlayed: true)),
      ],
    );
    final expected = {
      LibraryPlayedFilter.unplayed: ['unviewed'],
      LibraryPlayedFilter.played: ['viewed'],
      LibraryPlayedFilter.inProgress: <String>[],
    };
    for (final entry in expected.entries) {
      expect(
        filterLibraryDirectoryPage(
          page,
          _state(playedFilter: entry.key),
        ).items.map((item) => item.id),
        entry.value,
      );
    }
  });

  test('unsupported entries are not classified as unwatched leaf media', () {
    for (final type in ['Unknown', 'Audio', 'Series', 'Season']) {
      final item = _item(type);
      expect(libraryDirectoryItemMatches(item, _state()), isTrue);
      for (final filter in LibraryPlayedFilter.values) {
        if (filter == LibraryPlayedFilter.all) continue;
        expect(
          libraryDirectoryItemMatches(item, _state(playedFilter: filter)),
          isFalse,
        );
      }
    }
  });

  test('media type and watch state are both required for leaf results', () {
    final page = EmbyItemPage(
      items: [
        _item('Movie', data: const EmbyUserData(isPlayed: true)),
        _item('Video', id: 'new-video'),
        _item(
          'Video',
          id: 'watched-video',
          data: const EmbyUserData(isPlayed: true),
        ),
        _item('PhotoAlbum'),
      ],
      rawItemCount: 5,
      totalRecordCount: 30,
    );
    final filtered = filterLibraryDirectoryPage(
      page,
      _state(
        mediaType: LibraryMediaType.video,
        playedFilter: LibraryPlayedFilter.played,
      ),
    );

    expect(filtered.items.map((item) => item.id), [
      'watched-video',
      'PhotoAlbum',
    ]);
    expect(filtered.rawItemCount, 5);
    expect(filtered.totalRecordCount, 30);
  });

  test('a page with zero matches advances the raw cursor to later media', () {
    final state = _state(playedFilter: LibraryPlayedFilter.played);
    final firstPage = filterLibraryDirectoryPage(
      EmbyItemPage(
        items: List.generate(60, (index) => _item('Video', id: 'new-$index')),
        totalRecordCount: 61,
      ),
      state,
    );
    final firstCursor = advanceLibraryRawPageCursor(
      currentStartIndex: 0,
      rawItemCount: firstPage.rawItemCount,
      reportedTotalCount: firstPage.totalRecordCount,
      pageSize: 60,
    );

    expect(firstPage.items, isEmpty);
    expect(firstCursor.nextStartIndex, 60);
    expect(firstCursor.hasMore, isTrue);
    expect(firstCursor.paginationStalled, isFalse);

    final secondPage = filterLibraryDirectoryPage(
      EmbyItemPage(
        items: [_item('Video', data: const EmbyUserData(isPlayed: true))],
        totalRecordCount: 61,
      ),
      state,
    );
    final secondCursor = advanceLibraryRawPageCursor(
      currentStartIndex: firstCursor.nextStartIndex,
      currentTotalCount: firstCursor.totalCount,
      rawItemCount: secondPage.rawItemCount,
      reportedTotalCount: secondPage.totalRecordCount,
      pageSize: 60,
    );

    expect(secondPage.items.single.id, 'Video');
    expect(secondCursor.nextStartIndex, 61);
    expect(secondCursor.hasMore, isFalse);
    expect(secondCursor.paginationStalled, isFalse);
  });

  test(
    'unknown source totals remain unknown after filtering an entire page',
    () {
      final page = filterLibraryDirectoryPage(
        EmbyItemPage(
          items: List.generate(60, (index) => _item('Video', id: '$index')),
        ),
        _state(playedFilter: LibraryPlayedFilter.played),
      );
      final cursor = advanceLibraryRawPageCursor(
        currentStartIndex: 0,
        rawItemCount: page.rawItemCount,
        reportedTotalCount: page.totalRecordCount,
        pageSize: 60,
      );

      expect(page.items, isEmpty);
      expect(page.totalRecordCount, isNull);
      expect(cursor.nextStartIndex, 60);
      expect(cursor.hasMore, isTrue);
    },
  );
}

LibraryBrowseState _state({
  LibraryMediaType mediaType = LibraryMediaType.all,
  LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
}) => LibraryBrowseState(
  scope: LibraryBrowseScope.directory,
  mediaType: mediaType,
  playedFilter: playedFilter,
);

EmbyItem _item(
  String type, {
  String? id,
  EmbyUserData data = const EmbyUserData(),
}) => EmbyItem(
  id: id ?? type,
  name: id ?? type,
  type: type,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: data,
);
