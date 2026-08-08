import 'package:flutter/foundation.dart';

import 'library_alphabet_filter.dart';

enum LibraryBrowseScope { media, directory, genres, tags, favorites, facet }

extension LibraryBrowseScopeCapabilities on LibraryBrowseScope {
  bool get supportsMediaFilters => switch (this) {
    LibraryBrowseScope.media ||
    LibraryBrowseScope.favorites ||
    LibraryBrowseScope.facet => true,
    LibraryBrowseScope.directory ||
    LibraryBrowseScope.genres ||
    LibraryBrowseScope.tags => false,
  };

  bool get supportsSorting => switch (this) {
    LibraryBrowseScope.media ||
    LibraryBrowseScope.directory ||
    LibraryBrowseScope.favorites ||
    LibraryBrowseScope.facet => true,
    LibraryBrowseScope.genres || LibraryBrowseScope.tags => false,
  };
}

enum LibraryMediaType {
  all('Movie,Series,Video'),
  movie('Movie'),
  series('Series'),
  video('Video');

  const LibraryMediaType(this.apiValue);

  final String apiValue;
}

enum LibraryLocalMediaFilter { all, strm, regular }

enum LibraryPlayedFilter {
  all(null),
  played('IsPlayed'),
  unplayed('IsUnplayed');

  const LibraryPlayedFilter(this.apiValue);

  final String? apiValue;
}

enum LibrarySortBy {
  name('SortName'),
  dateAdded('DateCreated'),
  premiereDate('PremiereDate'),
  productionYear('ProductionYear'),
  communityRating('CommunityRating'),
  runtime('Runtime');

  const LibrarySortBy(this.apiValue);

  final String apiValue;
}

enum LibrarySortOrder {
  ascending('Ascending'),
  descending('Descending');

  const LibrarySortOrder(this.apiValue);

  final String apiValue;
}

enum LibraryFacetKind { genre, tag }

@immutable
class LibraryFacet {
  const LibraryFacet({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;
  final String name;
  final LibraryFacetKind kind;

  bool get isValid => id.trim().isNotEmpty && name.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryFacet &&
          id == other.id &&
          name == other.name &&
          kind == other.kind;

  @override
  int get hashCode => Object.hash(id, name, kind);
}

@immutable
class LibraryBrowseState {
  const LibraryBrowseState({
    this.scope = LibraryBrowseScope.media,
    this.mediaType = LibraryMediaType.all,
    this.playedFilter = LibraryPlayedFilter.all,
    this.localFilter = LibraryLocalMediaFilter.all,
    this.sortBy = LibrarySortBy.name,
    this.sortOrder = LibrarySortOrder.ascending,
    this.alphabetFilter = const AllItems(),
    this.facet,
  });

  const LibraryBrowseState.favorites()
    : scope = LibraryBrowseScope.favorites,
      mediaType = LibraryMediaType.all,
      playedFilter = LibraryPlayedFilter.all,
      localFilter = LibraryLocalMediaFilter.all,
      sortBy = LibrarySortBy.name,
      sortOrder = LibrarySortOrder.ascending,
      alphabetFilter = const AllItems(),
      facet = null;

  const LibraryBrowseState.directory({
    this.sortBy = LibrarySortBy.name,
    this.sortOrder = LibrarySortOrder.ascending,
  }) : scope = LibraryBrowseScope.directory,
       mediaType = LibraryMediaType.all,
       playedFilter = LibraryPlayedFilter.all,
       localFilter = LibraryLocalMediaFilter.all,
       alphabetFilter = const AllItems(),
       facet = null;

  const LibraryBrowseState.facet(LibraryFacet this.facet)
    : scope = LibraryBrowseScope.facet,
      mediaType = LibraryMediaType.all,
      playedFilter = LibraryPlayedFilter.all,
      localFilter = LibraryLocalMediaFilter.all,
      sortBy = LibrarySortBy.name,
      sortOrder = LibrarySortOrder.ascending,
      alphabetFilter = const AllItems();

  final LibraryBrowseScope scope;
  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
  final LibraryLocalMediaFilter localFilter;
  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
  final LibraryAlphabetFilter alphabetFilter;
  final LibraryFacet? facet;

  bool get alphabetEnabled =>
      scope.supportsMediaFilters &&
      sortBy == LibrarySortBy.name &&
      sortOrder == LibrarySortOrder.ascending;

  int get activeFilterCount =>
      (playedFilter == LibraryPlayedFilter.all ? 0 : 1) +
      (alphabetFilter.isAll ? 0 : 1);

  LibraryBrowseState copyWith({
    LibraryBrowseScope? scope,
    LibraryMediaType? mediaType,
    LibraryPlayedFilter? playedFilter,
    LibraryLocalMediaFilter? localFilter,
    LibrarySortBy? sortBy,
    LibrarySortOrder? sortOrder,
    LibraryAlphabetFilter? alphabetFilter,
    LibraryFacet? facet,
    bool clearFacet = false,
  }) => LibraryBrowseState(
    scope: scope ?? this.scope,
    mediaType: mediaType ?? this.mediaType,
    playedFilter: playedFilter ?? this.playedFilter,
    localFilter: localFilter ?? this.localFilter,
    sortBy: sortBy ?? this.sortBy,
    sortOrder: sortOrder ?? this.sortOrder,
    alphabetFilter: alphabetFilter ?? this.alphabetFilter,
    facet: clearFacet ? null : facet ?? this.facet,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryBrowseState &&
          scope == other.scope &&
          mediaType == other.mediaType &&
          playedFilter == other.playedFilter &&
          localFilter == other.localFilter &&
          sortBy == other.sortBy &&
          sortOrder == other.sortOrder &&
          alphabetFilter == other.alphabetFilter &&
          facet == other.facet;

  @override
  int get hashCode => Object.hash(
    scope,
    mediaType,
    playedFilter,
    localFilter,
    sortBy,
    sortOrder,
    alphabetFilter,
    facet,
  );
}

LibraryBrowseState normalizeLibraryBrowseState(LibraryBrowseState state) {
  switch (state.scope) {
    case LibraryBrowseScope.media:
    case LibraryBrowseScope.favorites:
      return _preserveIdentity(
        state,
        state.copyWith(
          alphabetFilter: _normalizedAlphabet(state),
          clearFacet: true,
        ),
      );
    case LibraryBrowseScope.facet:
      final facet = state.facet;
      if (facet == null || !facet.isValid) return const LibraryBrowseState();
      return _preserveIdentity(
        state,
        state.copyWith(alphabetFilter: _normalizedAlphabet(state)),
      );
    case LibraryBrowseScope.directory:
      return _preserveIdentity(
        state,
        LibraryBrowseState.directory(
          sortBy: state.sortBy,
          sortOrder: state.sortOrder,
        ),
      );
    case LibraryBrowseScope.genres:
    case LibraryBrowseScope.tags:
      return _preserveIdentity(state, LibraryBrowseState(scope: state.scope));
  }
}

LibraryBrowseState _preserveIdentity(
  LibraryBrowseState original,
  LibraryBrowseState normalized,
) => normalized == original ? original : normalized;

LibraryAlphabetFilter _normalizedAlphabet(LibraryBrowseState state) =>
    state.sortBy == LibrarySortBy.name &&
        state.sortOrder == LibrarySortOrder.ascending
    ? state.alphabetFilter
    : const AllItems();

sealed class LibraryBrowseEvent {
  const LibraryBrowseEvent();
}

final class LibraryScopeSelected extends LibraryBrowseEvent {
  const LibraryScopeSelected(this.scope);

  final LibraryBrowseScope scope;
}

final class LibraryMediaTypeSelected extends LibraryBrowseEvent {
  const LibraryMediaTypeSelected(this.mediaType);

  final LibraryMediaType mediaType;
}

final class LibraryPlayedFilterSelected extends LibraryBrowseEvent {
  const LibraryPlayedFilterSelected(this.playedFilter);

  final LibraryPlayedFilter playedFilter;
}

final class LibraryLocalFilterSelected extends LibraryBrowseEvent {
  const LibraryLocalFilterSelected(this.localFilter);

  final LibraryLocalMediaFilter localFilter;
}

final class LibrarySortChanged extends LibraryBrowseEvent {
  const LibrarySortChanged({required this.sortBy, required this.sortOrder});

  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
}

final class LibraryAlphabetFilterSelected extends LibraryBrowseEvent {
  const LibraryAlphabetFilterSelected(this.alphabetFilter);

  final LibraryAlphabetFilter alphabetFilter;
}

final class LibraryBrowseReset extends LibraryBrowseEvent {
  const LibraryBrowseReset();
}

LibraryBrowseState reduceLibraryBrowseState(
  LibraryBrowseState state,
  LibraryBrowseEvent event,
) {
  final current = normalizeLibraryBrowseState(state);
  final next = switch (event) {
    LibraryScopeSelected(:final scope) => _selectScope(current, scope),
    LibraryMediaTypeSelected(:final mediaType) =>
      current.scope.supportsMediaFilters
          ? current.copyWith(mediaType: mediaType)
          : current,
    LibraryPlayedFilterSelected(:final playedFilter) =>
      current.scope.supportsMediaFilters
          ? current.copyWith(playedFilter: playedFilter)
          : current,
    LibraryLocalFilterSelected(:final localFilter) =>
      current.scope.supportsMediaFilters
          ? current.copyWith(localFilter: localFilter)
          : current,
    LibrarySortChanged(:final sortBy, :final sortOrder) =>
      current.scope.supportsSorting
          ? current.copyWith(sortBy: sortBy, sortOrder: sortOrder)
          : current,
    LibraryAlphabetFilterSelected(:final alphabetFilter) =>
      current.alphabetEnabled
          ? current.copyWith(alphabetFilter: alphabetFilter)
          : current,
    LibraryBrowseReset() => const LibraryBrowseState(),
  };
  if (identical(next, current)) return current;
  final normalized = normalizeLibraryBrowseState(next);
  return normalized == current ? current : normalized;
}

LibraryBrowseState _selectScope(
  LibraryBrowseState current,
  LibraryBrowseScope selected,
) {
  if (selected == current.scope || selected == LibraryBrowseScope.facet) {
    return current;
  }
  final currentIsMediaScope = switch (current.scope) {
    LibraryBrowseScope.media || LibraryBrowseScope.favorites => true,
    _ => false,
  };
  final selectedIsMediaScope = switch (selected) {
    LibraryBrowseScope.media || LibraryBrowseScope.favorites => true,
    _ => false,
  };
  if (currentIsMediaScope && selectedIsMediaScope) {
    return current.copyWith(scope: selected);
  }
  return switch (selected) {
    LibraryBrowseScope.media => const LibraryBrowseState(),
    LibraryBrowseScope.favorites => const LibraryBrowseState.favorites(),
    LibraryBrowseScope.directory => LibraryBrowseState.directory(
      sortBy: current.sortBy,
      sortOrder: current.sortOrder,
    ),
    LibraryBrowseScope.genres ||
    LibraryBrowseScope.tags => LibraryBrowseState(scope: selected),
    LibraryBrowseScope.facet => current,
  };
}
