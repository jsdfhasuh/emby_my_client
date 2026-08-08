import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_item_membership.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('server membership combines favorites and played filters', () {
    const favoriteUnplayed = EmbyUserData(isFavorite: true);
    const favoritePlayed = EmbyUserData(isFavorite: true, isPlayed: true);
    const ordinaryUnplayed = EmbyUserData();

    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState(),
        ordinaryUnplayed,
      ),
      isTrue,
    );
    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState.favorites(),
        ordinaryUnplayed,
      ),
      isFalse,
    );
    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState(
          scope: LibraryBrowseScope.favorites,
          playedFilter: LibraryPlayedFilter.unplayed,
        ),
        favoriteUnplayed,
      ),
      isTrue,
    );
    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState(
          scope: LibraryBrowseScope.favorites,
          playedFilter: LibraryPlayedFilter.unplayed,
        ),
        favoritePlayed,
      ),
      isFalse,
    );
    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState(
          scope: LibraryBrowseScope.favorites,
          playedFilter: LibraryPlayedFilter.played,
        ),
        favoritePlayed,
      ),
      isTrue,
    );
  });

  test('local media filters never affect server membership', () {
    const userData = EmbyUserData(isFavorite: true);
    for (final localFilter in LibraryLocalMediaFilter.values) {
      expect(
        libraryItemMatchesServerMembership(
          LibraryBrowseState(
            scope: LibraryBrowseScope.favorites,
            localFilter: localFilter,
          ),
          userData,
        ),
        isTrue,
      );
    }
  });

  test('only favorites and played filters require unknown-ID reloads', () {
    expect(
      libraryBrowseHasServerMembershipCondition(const LibraryBrowseState()),
      isFalse,
    );
    expect(
      libraryBrowseHasServerMembershipCondition(
        const LibraryBrowseState.favorites(),
      ),
      isTrue,
    );
    expect(
      libraryBrowseHasServerMembershipCondition(
        const LibraryBrowseState(playedFilter: LibraryPlayedFilter.unplayed),
      ),
      isTrue,
    );
  });
}
