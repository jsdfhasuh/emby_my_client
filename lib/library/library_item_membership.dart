import '../models/emby_models.dart';
import 'library_browse_state.dart';

bool libraryBrowseHasServerMembershipCondition(LibraryBrowseState state) =>
    state.scope == LibraryBrowseScope.favorites ||
    state.playedFilter != LibraryPlayedFilter.all;

bool libraryItemMatchesServerMembership(
  LibraryBrowseState state,
  EmbyUserData userData,
) {
  if (state.scope == LibraryBrowseScope.favorites && !userData.isFavorite) {
    return false;
  }
  return switch (state.playedFilter) {
    LibraryPlayedFilter.all => true,
    LibraryPlayedFilter.played => userData.isPlayed,
    LibraryPlayedFilter.unplayed => !userData.isPlayed,
  };
}
