import '../models/emby_models.dart';
import 'library_browse_state.dart';
import 'library_content_profile.dart';

enum LibraryEntryAction {
  openDirectory,
  openPhoto,
  openDetail,
  openFacet,
  unsupported,
}

LibraryEntryAction resolveLibraryEntryAction(
  LibraryContentProfile profile,
  LibraryBrowseScope scope,
  EmbyItem item,
) => switch (scope) {
  LibraryBrowseScope.genres ||
  LibraryBrowseScope.tags => LibraryEntryAction.openFacet,
  LibraryBrowseScope.media ||
  LibraryBrowseScope.directory ||
  LibraryBrowseScope.favorites ||
  LibraryBrowseScope.facet => _resolveContentEntry(profile, item),
};

LibraryEntryAction _resolveContentEntry(
  LibraryContentProfile profile,
  EmbyItem item,
) {
  if (item.isLibraryContainer) return LibraryEntryAction.openDirectory;
  if (item.isPhoto) {
    return profile.allowedMediaTypes.contains(LibraryMediaType.photo)
        ? LibraryEntryAction.openPhoto
        : LibraryEntryAction.unsupported;
  }
  return switch (item.type) {
    'Movie' ||
    'Series' ||
    'Episode' ||
    'Video' => LibraryEntryAction.openDetail,
    _ => LibraryEntryAction.unsupported,
  };
}
