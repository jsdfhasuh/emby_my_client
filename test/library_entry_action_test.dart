import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_entry_action.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves every mixed directory item by its real type', () {
    for (final type in ['Folder', 'CollectionFolder']) {
      expect(
        resolveLibraryEntryAction(LibraryBrowseScope.directory, _item(type)),
        LibraryEntryAction.openDirectory,
      );
    }
    for (final type in ['Movie', 'Series', 'Episode', 'Video']) {
      expect(
        resolveLibraryEntryAction(LibraryBrowseScope.directory, _item(type)),
        LibraryEntryAction.openDetail,
      );
    }
  });

  test('media scopes open folders as directories and media as details', () {
    for (final scope in [
      LibraryBrowseScope.media,
      LibraryBrowseScope.favorites,
      LibraryBrowseScope.facet,
    ]) {
      expect(
        resolveLibraryEntryAction(scope, _item('Folder')),
        LibraryEntryAction.openDirectory,
      );
      expect(
        resolveLibraryEntryAction(scope, _item('Movie')),
        LibraryEntryAction.openDetail,
      );
    }
  });

  test('genre and tag indexes always open a facet', () {
    for (final scope in [LibraryBrowseScope.genres, LibraryBrowseScope.tags]) {
      expect(
        resolveLibraryEntryAction(scope, _item('Genre')),
        LibraryEntryAction.openFacet,
      );
    }
  });
}

EmbyItem _item(String type) => EmbyItem(
  id: type,
  name: type,
  type: type,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);
