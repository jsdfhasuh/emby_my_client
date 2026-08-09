import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const facet = LibraryFacet(
    id: 'facet-1',
    name: 'Facet',
    kind: LibraryFacetKind.genre,
  );
  final alphabets = <LibraryAlphabetFilter>[
    const AllItems(),
    LetterItems('m'),
    const SymbolsItems(),
  ];

  test('default and reset state use the fixed media baseline', () {
    const state = LibraryBrowseState(
      scope: LibraryBrowseScope.favorites,
      mediaType: LibraryMediaType.movie,
      playedFilter: LibraryPlayedFilter.unplayed,
      localFilter: LibraryLocalMediaFilter.strm,
      sortBy: LibrarySortBy.runtime,
      sortOrder: LibrarySortOrder.descending,
      alphabetFilter: SymbolsItems(),
    );

    expect(
      reduceLibraryBrowseState(state, const LibraryBrowseReset()),
      const LibraryBrowseState(),
    );
  });

  test('normalizes the complete browse state cartesian product', () {
    for (final scope in LibraryBrowseScope.values) {
      for (final mediaType in LibraryMediaType.values) {
        for (final playedFilter in LibraryPlayedFilter.values) {
          for (final localFilter in LibraryLocalMediaFilter.values) {
            for (final sortBy in LibrarySortBy.values) {
              for (final sortOrder in LibrarySortOrder.values) {
                for (final alphabet in alphabets) {
                  for (final candidateFacet in <LibraryFacet?>[null, facet]) {
                    final normalized = normalizeLibraryBrowseState(
                      LibraryBrowseState(
                        scope: scope,
                        mediaType: mediaType,
                        playedFilter: playedFilter,
                        localFilter: localFilter,
                        sortBy: sortBy,
                        sortOrder: sortOrder,
                        alphabetFilter: alphabet,
                        facet: candidateFacet,
                      ),
                    );

                    expect(normalizeLibraryBrowseState(normalized), normalized);
                    switch (normalized.scope) {
                      case LibraryBrowseScope.media:
                      case LibraryBrowseScope.favorites:
                        expect(normalized.facet, isNull);
                      case LibraryBrowseScope.facet:
                        expect(normalized.facet, isNotNull);
                        expect(normalized.facet!.isValid, isTrue);
                      case LibraryBrowseScope.directory:
                        expect(normalized.mediaType, LibraryMediaType.all);
                        expect(
                          normalized.playedFilter,
                          LibraryPlayedFilter.all,
                        );
                        expect(
                          normalized.localFilter,
                          LibraryLocalMediaFilter.all,
                        );
                        expect(normalized.alphabetFilter.isAll, isTrue);
                        expect(normalized.facet, isNull);
                      case LibraryBrowseScope.genres:
                      case LibraryBrowseScope.tags:
                        expect(normalized.mediaType, LibraryMediaType.all);
                        expect(
                          normalized.playedFilter,
                          LibraryPlayedFilter.all,
                        );
                        expect(
                          normalized.localFilter,
                          LibraryLocalMediaFilter.all,
                        );
                        expect(normalized.sortBy, LibrarySortBy.name);
                        expect(
                          normalized.sortOrder,
                          LibrarySortOrder.ascending,
                        );
                        expect(normalized.alphabetFilter.isAll, isTrue);
                        expect(normalized.facet, isNull);
                    }
                    if (!normalized.alphabetEnabled) {
                      expect(normalized.alphabetFilter.isAll, isTrue);
                    }
                    if (normalized.mediaType == LibraryMediaType.photo) {
                      expect(normalized.playedFilter, LibraryPlayedFilter.all);
                    }
                    if (!normalized.mediaType.supportsLocalSourceFilter) {
                      expect(
                        normalized.localFilter,
                        LibraryLocalMediaFilter.all,
                      );
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  });

  test('media and favorites preserve compatible filters both ways', () {
    final media = LibraryBrowseState(
      mediaType: LibraryMediaType.movie,
      playedFilter: LibraryPlayedFilter.unplayed,
      localFilter: LibraryLocalMediaFilter.strm,
      alphabetFilter: LetterItems('q'),
    );

    final favorites = reduceLibraryBrowseState(
      media,
      const LibraryScopeSelected(LibraryBrowseScope.favorites),
    );
    expect(favorites.scope, LibraryBrowseScope.favorites);
    expect(favorites.mediaType, media.mediaType);
    expect(favorites.playedFilter, media.playedFilter);
    expect(favorites.localFilter, media.localFilter);
    expect(favorites.alphabetFilter, media.alphabetFilter);

    final restored = reduceLibraryBrowseState(
      favorites,
      const LibraryScopeSelected(LibraryBrowseScope.media),
    );
    expect(restored, media);
  });

  test('returning from non-media scopes uses explicit defaults', () {
    const directory = LibraryBrowseState.directory(
      sortBy: LibrarySortBy.runtime,
      sortOrder: LibrarySortOrder.descending,
    );

    expect(
      reduceLibraryBrowseState(
        directory,
        const LibraryScopeSelected(LibraryBrowseScope.media),
      ),
      const LibraryBrowseState(),
    );
    expect(
      reduceLibraryBrowseState(
        directory,
        const LibraryScopeSelected(LibraryBrowseScope.favorites),
      ),
      const LibraryBrowseState.favorites(),
    );
  });

  test('sort normalization clears an incompatible alphabet filter', () {
    final state = LibraryBrowseState(alphabetFilter: LetterItems('z'));
    final sorted = reduceLibraryBrowseState(
      state,
      const LibrarySortChanged(
        sortBy: LibrarySortBy.dateAdded,
        sortOrder: LibrarySortOrder.descending,
      ),
    );

    expect(sorted.alphabetFilter.isAll, isTrue);
    expect(
      reduceLibraryBrowseState(
        sorted,
        LibraryAlphabetFilterSelected(LetterItems('a')),
      ),
      same(sorted),
    );
  });

  test('same selections are identity-preserving no-ops', () {
    const state = LibraryBrowseState();

    expect(
      reduceLibraryBrowseState(
        state,
        const LibraryScopeSelected(LibraryBrowseScope.media),
      ),
      same(state),
    );
    expect(
      reduceLibraryBrowseState(
        state,
        const LibraryMediaTypeSelected(LibraryMediaType.all),
      ),
      same(state),
    );
    expect(
      reduceLibraryBrowseState(
        state,
        const LibraryPlayedFilterSelected(LibraryPlayedFilter.all),
      ),
      same(state),
    );
    expect(
      reduceLibraryBrowseState(
        state,
        const LibraryLocalFilterSelected(LibraryLocalMediaFilter.all),
      ),
      same(state),
    );
    expect(
      reduceLibraryBrowseState(
        state,
        const LibrarySortChanged(
          sortBy: LibrarySortBy.name,
          sortOrder: LibrarySortOrder.ascending,
        ),
      ),
      same(state),
    );
    expect(
      reduceLibraryBrowseState(
        state,
        const LibraryAlphabetFilterSelected(AllItems()),
      ),
      same(state),
    );
  });

  test('facet states require a valid typed facet', () {
    expect(
      normalizeLibraryBrowseState(
        const LibraryBrowseState(scope: LibraryBrowseScope.facet),
      ),
      const LibraryBrowseState(),
    );
    expect(
      normalizeLibraryBrowseState(
        const LibraryBrowseState(
          scope: LibraryBrowseScope.facet,
          facet: LibraryFacet(
            id: '',
            name: 'Facet',
            kind: LibraryFacetKind.tag,
          ),
        ),
      ),
      const LibraryBrowseState(),
    );
    expect(
      normalizeLibraryBrowseState(const LibraryBrowseState.facet(facet)),
      const LibraryBrowseState.facet(facet),
    );
  });

  test('non-media scopes reject media-only events', () {
    const directory = LibraryBrowseState.directory();

    expect(
      reduceLibraryBrowseState(
        directory,
        const LibraryMediaTypeSelected(LibraryMediaType.movie),
      ),
      same(directory),
    );
    expect(
      reduceLibraryBrowseState(
        directory,
        const LibraryPlayedFilterSelected(LibraryPlayedFilter.played),
      ),
      same(directory),
    );
    expect(
      reduceLibraryBrowseState(
        directory,
        const LibraryLocalFilterSelected(LibraryLocalMediaFilter.regular),
      ),
      same(directory),
    );
  });

  test(
    'filter draft applies atomically and photo clears incompatible filters',
    () {
      const state = LibraryBrowseState(
        mediaType: LibraryMediaType.movie,
        localFilter: LibraryLocalMediaFilter.strm,
        playedFilter: LibraryPlayedFilter.unplayed,
      );
      final draft = LibraryFilterDraft.fromState(
        state,
      ).copyWith(mediaType: LibraryMediaType.photo);

      expect(draft.mediaType, LibraryMediaType.photo);
      expect(draft.localFilter, LibraryLocalMediaFilter.all);
      expect(draft.playedFilter, LibraryPlayedFilter.all);
      expect(
        reduceLibraryBrowseState(state, LibraryFiltersApplied(draft)),
        const LibraryBrowseState(mediaType: LibraryMediaType.photo),
      );
      expect(draft.reset(), const LibraryFilterDraft());
    },
  );

  test('series clears local source filters without clearing played state', () {
    const candidate = LibraryBrowseState(
      mediaType: LibraryMediaType.series,
      localFilter: LibraryLocalMediaFilter.strm,
      playedFilter: LibraryPlayedFilter.unplayed,
    );

    expect(
      normalizeLibraryBrowseState(candidate),
      const LibraryBrowseState(
        mediaType: LibraryMediaType.series,
        playedFilter: LibraryPlayedFilter.unplayed,
      ),
    );
    expect(
      const LibraryFilterDraft(
        mediaType: LibraryMediaType.movie,
        localFilter: LibraryLocalMediaFilter.regular,
        playedFilter: LibraryPlayedFilter.played,
      ).copyWith(mediaType: LibraryMediaType.series),
      const LibraryFilterDraft(
        mediaType: LibraryMediaType.series,
        playedFilter: LibraryPlayedFilter.played,
      ),
    );
  });

  test('favorites and photo remain compatible after normalization', () {
    const state = LibraryBrowseState(
      scope: LibraryBrowseScope.favorites,
      mediaType: LibraryMediaType.photo,
      localFilter: LibraryLocalMediaFilter.regular,
      playedFilter: LibraryPlayedFilter.played,
    );

    expect(
      normalizeLibraryBrowseState(state),
      const LibraryBrowseState(
        scope: LibraryBrowseScope.favorites,
        mediaType: LibraryMediaType.photo,
      ),
    );
  });

  test('category visibility normalizes hidden root selections', () {
    const visibility = LibraryCategoryVisibilityChanged(
      showMovies: false,
      showSeries: true,
      showVideos: true,
      showFavorites: false,
      showDirectory: false,
    );
    const favoriteMovie = LibraryBrowseState(
      scope: LibraryBrowseScope.favorites,
      mediaType: LibraryMediaType.movie,
      playedFilter: LibraryPlayedFilter.unplayed,
      localFilter: LibraryLocalMediaFilter.strm,
    );

    final media = reduceLibraryBrowseState(favoriteMovie, visibility);
    expect(media.scope, LibraryBrowseScope.media);
    expect(media.mediaType, LibraryMediaType.all);
    expect(media.playedFilter, LibraryPlayedFilter.unplayed);
    expect(media.localFilter, LibraryLocalMediaFilter.strm);
    expect(
      reduceLibraryBrowseState(
        const LibraryBrowseState.directory(
          sortBy: LibrarySortBy.runtime,
          sortOrder: LibrarySortOrder.descending,
        ),
        visibility,
      ),
      const LibraryBrowseState(),
    );
  });

  test('category visibility is an identity no-op for visible selections', () {
    const state = LibraryBrowseState(mediaType: LibraryMediaType.series);
    const visibility = LibraryCategoryVisibilityChanged(
      showMovies: false,
      showSeries: true,
      showVideos: false,
      showFavorites: false,
      showDirectory: false,
    );

    expect(reduceLibraryBrowseState(state, visibility), same(state));
  });
}
