import 'library_browse_state.dart';

enum LibraryPaginationStrategy { stableOffset, identityRescan }

LibraryPaginationStrategy libraryPaginationStrategyFor(
  LibraryBrowseState state,
) {
  if (state.sortBy == LibrarySortBy.playCount ||
      state.scope == LibraryBrowseScope.favorites ||
      state.playedFilter != LibraryPlayedFilter.all) {
    return LibraryPaginationStrategy.identityRescan;
  }
  return LibraryPaginationStrategy.stableOffset;
}

bool libraryIdentityPrefixChanged({
  required Iterable<String> previousIds,
  required Iterable<String> rescannedIds,
}) {
  final previous = previousIds.iterator;
  final rescanned = rescannedIds.iterator;
  while (previous.moveNext()) {
    if (!rescanned.moveNext() || rescanned.current != previous.current) {
      return true;
    }
  }
  return false;
}
