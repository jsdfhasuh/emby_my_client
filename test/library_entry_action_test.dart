import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_entry_action.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves every mixed directory item by its real type', () {
    for (final type in ['Folder', 'CollectionFolder', 'PhotoAlbum']) {
      expect(
        resolveLibraryEntryAction(
          LibraryContentProfile.mixed,
          LibraryBrowseScope.directory,
          _item(type),
        ),
        LibraryEntryAction.openDirectory,
      );
    }
    for (final type in ['Movie', 'Series', 'Episode', 'Video']) {
      expect(
        resolveLibraryEntryAction(
          LibraryContentProfile.mixed,
          LibraryBrowseScope.directory,
          _item(type),
        ),
        LibraryEntryAction.openDetail,
      );
    }
    expect(
      resolveLibraryEntryAction(
        LibraryContentProfile.mixed,
        LibraryBrowseScope.directory,
        _item('Photo'),
      ),
      LibraryEntryAction.openPhoto,
    );
  });

  test('media scopes open folders as directories and media as details', () {
    for (final scope in [
      LibraryBrowseScope.media,
      LibraryBrowseScope.favorites,
      LibraryBrowseScope.facet,
    ]) {
      expect(
        resolveLibraryEntryAction(
          LibraryContentProfile.mixed,
          scope,
          _item('Folder'),
        ),
        LibraryEntryAction.openDirectory,
      );
      expect(
        resolveLibraryEntryAction(
          LibraryContentProfile.mixed,
          scope,
          _item('Movie'),
        ),
        LibraryEntryAction.openDetail,
      );
    }
  });

  test('genre and tag indexes always open a facet', () {
    for (final scope in [LibraryBrowseScope.genres, LibraryBrowseScope.tags]) {
      expect(
        resolveLibraryEntryAction(
          LibraryContentProfile.mixed,
          scope,
          _item('Genre'),
        ),
        LibraryEntryAction.openFacet,
      );
    }
  });

  test('photos never enter details and unsupported types fail closed', () {
    expect(
      resolveLibraryEntryAction(
        LibraryContentProfile.homeVideosAndPhotos,
        LibraryBrowseScope.media,
        _item('Photo'),
      ),
      LibraryEntryAction.openPhoto,
    );
    expect(
      resolveLibraryEntryAction(
        LibraryContentProfile.movies,
        LibraryBrowseScope.media,
        _item('Photo'),
      ),
      LibraryEntryAction.unsupported,
    );
    expect(
      resolveLibraryEntryAction(
        LibraryContentProfile.unknown,
        LibraryBrowseScope.media,
        _item('FutureType'),
      ),
      LibraryEntryAction.unsupported,
    );
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
