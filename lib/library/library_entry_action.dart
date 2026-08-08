import '../models/emby_models.dart';
import 'library_browse_state.dart';

enum LibraryEntryAction { openDirectory, openDetail, openFacet }

LibraryEntryAction resolveLibraryEntryAction(
  LibraryBrowseScope scope,
  EmbyItem item,
) => switch (scope) {
  LibraryBrowseScope.genres ||
  LibraryBrowseScope.tags => LibraryEntryAction.openFacet,
  LibraryBrowseScope.media ||
  LibraryBrowseScope.directory ||
  LibraryBrowseScope.favorites ||
  LibraryBrowseScope.facet =>
    item.isFolder
        ? LibraryEntryAction.openDirectory
        : LibraryEntryAction.openDetail,
};
