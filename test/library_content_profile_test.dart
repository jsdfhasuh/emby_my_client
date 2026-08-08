import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('collection types resolve to deterministic content profiles', () {
    expect(
      LibraryContentProfile.fromCollectionType('movies').kind,
      LibraryContentProfileKind.movies,
    );
    expect(
      LibraryContentProfile.fromCollectionType(' TVSHOWS ').kind,
      LibraryContentProfileKind.tvShows,
    );
    expect(
      LibraryContentProfile.fromCollectionType('homevideos').kind,
      LibraryContentProfileKind.homeVideosAndPhotos,
    );
    expect(
      LibraryContentProfile.fromCollectionType('photos').kind,
      LibraryContentProfileKind.photos,
    );
    expect(
      LibraryContentProfile.fromCollectionType('mixed').kind,
      LibraryContentProfileKind.mixed,
    );
    expect(
      LibraryContentProfile.fromCollectionType(null).kind,
      LibraryContentProfileKind.unknown,
    );
    expect(
      LibraryContentProfile.fromCollectionType('future-value').kind,
      LibraryContentProfileKind.unknown,
    );
  });

  test('home video and photo profile exposes the frozen mixed mapping', () {
    const profile = LibraryContentProfile.homeVideosAndPhotos;

    expect(
      profile.includeItemTypesFor(LibraryMediaType.all),
      'Movie,Video,Photo',
    );
    expect(profile.includeItemTypesFor(LibraryMediaType.movie), 'Movie');
    expect(profile.includeItemTypesFor(LibraryMediaType.video), 'Video');
    expect(profile.includeItemTypesFor(LibraryMediaType.photo), 'Photo');
    expect(
      () => profile.includeItemTypesFor(LibraryMediaType.series),
      throwsArgumentError,
    );
  });

  test('unknown libraries retain conservative mixed capabilities', () {
    const profile = LibraryContentProfile.unknown;

    expect(
      profile.allowedScopes,
      containsAll(<LibraryBrowseScope>{
        LibraryBrowseScope.media,
        LibraryBrowseScope.directory,
        LibraryBrowseScope.genres,
        LibraryBrowseScope.tags,
        LibraryBrowseScope.favorites,
      }),
    );
    expect(
      profile.includeItemTypesFor(LibraryMediaType.all),
      'Movie,Series,Video,Photo',
    );
  });

  test('profile capabilities intersect with user visibility settings', () {
    const profile = LibraryContentProfile.mixed;
    const settings = LibraryCategorySettings(
      showMovies: true,
      showSeries: false,
      showVideos: true,
      showPhotos: false,
      showFavorites: false,
      showFolders: false,
    );

    expect(profile.visibleScopes(settings), {
      LibraryBrowseScope.media,
      LibraryBrowseScope.genres,
      LibraryBrowseScope.tags,
    });
    expect(profile.visibleMediaTypes(settings), {
      LibraryMediaType.all,
      LibraryMediaType.movie,
      LibraryMediaType.video,
    });
  });

  test('photo profile removes unsupported roots and filter capabilities', () {
    const profile = LibraryContentProfile.photos;

    expect(profile.supportsGenres, isFalse);
    expect(profile.supportsTags, isFalse);
    expect(profile.supportsPlayedFilter, isFalse);
    expect(profile.supportsLocalSourceFilter, isFalse);
    expect(profile.supportsPlayAll, isFalse);
    expect(profile.visibleScopes(const LibraryCategorySettings()), {
      LibraryBrowseScope.media,
      LibraryBrowseScope.directory,
      LibraryBrowseScope.favorites,
    });
  });
}
