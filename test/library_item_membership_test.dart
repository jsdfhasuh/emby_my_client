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

  test('in-progress membership uses progress and gives Played precedence', () {
    const state = LibraryBrowseState(
      playedFilter: LibraryPlayedFilter.inProgress,
    );
    const positionOnly = EmbyUserData(playbackPositionTicks: 100);
    const percentageOnly = EmbyUserData(playedPercentage: 25);
    const watchedReplaying = EmbyUserData(
      isPlayed: true,
      playbackPositionTicks: 100,
      playedPercentage: 25,
    );

    expect(libraryItemMatchesServerMembership(state, positionOnly), isTrue);
    expect(libraryItemMatchesServerMembership(state, percentageOnly), isTrue);
    expect(
      libraryItemMatchesServerMembership(state, watchedReplaying),
      isFalse,
    );
    expect(
      libraryItemMatchesServerMembership(state, const EmbyUserData()),
      isFalse,
    );
    expect(
      libraryItemMatchesServerMembership(
        state,
        const EmbyUserData(playCount: 1),
      ),
      isFalse,
    );
    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState(playedFilter: LibraryPlayedFilter.unplayed),
        positionOnly,
      ),
      isTrue,
    );
    expect(
      libraryItemMatchesServerMembership(
        const LibraryBrowseState(
          scope: LibraryBrowseScope.favorites,
          playedFilter: LibraryPlayedFilter.inProgress,
        ),
        positionOnly,
      ),
      isFalse,
    );
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
    expect(
      libraryBrowseHasServerMembershipCondition(
        const LibraryBrowseState(playedFilter: LibraryPlayedFilter.inProgress),
      ),
      isTrue,
    );
  });
}
