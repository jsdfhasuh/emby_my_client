import '../models/emby_models.dart';
import 'library_browse_state.dart';
import 'library_watch_status.dart';

/// Filters leaf entries without removing navigation into child directories.
///
/// The source count and cursor belong to the unfiltered directory response.
/// Keeping them intact lets callers advance past pages with no matching media;
/// callers must not present [EmbyItemPage.totalRecordCount] as a filtered total.
EmbyItemPage filterLibraryDirectoryPage(
  EmbyItemPage page,
  LibraryBrowseState state,
) {
  if (state.mediaType == LibraryMediaType.all &&
      state.playedFilter == LibraryPlayedFilter.all) {
    return page;
  }
  return EmbyItemPage(
    items: page.items
        .where((item) => libraryDirectoryItemMatches(item, state))
        .toList(growable: false),
    totalRecordCount: page.totalRecordCount,
    rawItemCount: page.rawItemCount,
  );
}

bool libraryDirectoryItemMatches(EmbyItem item, LibraryBrowseState state) {
  if (item.isLibraryContainer) return true;

  final matchesType = switch (state.mediaType) {
    LibraryMediaType.all => true,
    LibraryMediaType.movie => item.type == 'Movie',
    LibraryMediaType.series => item.type == 'Series',
    LibraryMediaType.video => item.type == 'Video',
    LibraryMediaType.photo => item.isPhoto,
  };
  if (!matchesType) return false;
  if (state.playedFilter == LibraryPlayedFilter.all) return true;

  final status = LibraryWatchStatus.forItem(item);
  if (status == null) return false;
  return switch (state.playedFilter) {
    LibraryPlayedFilter.all => true,
    LibraryPlayedFilter.played => status.state == LibraryWatchState.watched,
    LibraryPlayedFilter.unplayed => status.state != LibraryWatchState.watched,
    LibraryPlayedFilter.inProgress =>
      status.state == LibraryWatchState.inProgress,
  };
}
