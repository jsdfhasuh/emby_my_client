import 'package:flutter/foundation.dart';

import '../settings/library_category_settings.dart';
import 'library_browse_state.dart';

enum LibraryContentProfileKind {
  movies,
  tvShows,
  homeVideosAndPhotos,
  photos,
  mixed,
  unknown,
}

@immutable
class LibraryContentProfile {
  const LibraryContentProfile._({
    required this.kind,
    required this.allowedScopes,
    required this.allowedMediaTypes,
    required this.supportsGenres,
    required this.supportsTags,
    required this.supportsFavorites,
    required this.supportsDirectories,
    required this.supportsPlayedFilter,
    required this.supportsLocalSourceFilter,
    required this.supportsPlayAll,
    required String allItemTypes,
  }) : _allItemTypes = allItemTypes;

  factory LibraryContentProfile.fromCollectionType(String? collectionType) {
    return switch (collectionType?.trim().toLowerCase()) {
      'movies' => movies,
      'tvshows' => tvShows,
      'homevideos' => homeVideosAndPhotos,
      'photos' => photos,
      'mixed' => mixed,
      null || '' => unknown,
      _ => unknown,
    };
  }

  final LibraryContentProfileKind kind;
  final Set<LibraryBrowseScope> allowedScopes;
  final Set<LibraryMediaType> allowedMediaTypes;
  final bool supportsGenres;
  final bool supportsTags;
  final bool supportsFavorites;
  final bool supportsDirectories;
  final bool supportsPlayedFilter;
  final bool supportsLocalSourceFilter;
  final bool supportsPlayAll;
  final String _allItemTypes;

  static const _allRootScopes = <LibraryBrowseScope>{
    LibraryBrowseScope.media,
    LibraryBrowseScope.directory,
    LibraryBrowseScope.genres,
    LibraryBrowseScope.tags,
    LibraryBrowseScope.favorites,
  };

  static const movies = LibraryContentProfile._(
    kind: LibraryContentProfileKind.movies,
    allowedScopes: _allRootScopes,
    allowedMediaTypes: {LibraryMediaType.all, LibraryMediaType.movie},
    supportsGenres: true,
    supportsTags: true,
    supportsFavorites: true,
    supportsDirectories: true,
    supportsPlayedFilter: true,
    supportsLocalSourceFilter: true,
    supportsPlayAll: true,
    allItemTypes: 'Movie',
  );

  static const tvShows = LibraryContentProfile._(
    kind: LibraryContentProfileKind.tvShows,
    allowedScopes: _allRootScopes,
    allowedMediaTypes: {LibraryMediaType.all, LibraryMediaType.series},
    supportsGenres: true,
    supportsTags: true,
    supportsFavorites: true,
    supportsDirectories: true,
    supportsPlayedFilter: true,
    supportsLocalSourceFilter: false,
    supportsPlayAll: false,
    allItemTypes: 'Series',
  );

  static const homeVideosAndPhotos = LibraryContentProfile._(
    kind: LibraryContentProfileKind.homeVideosAndPhotos,
    allowedScopes: _allRootScopes,
    allowedMediaTypes: {
      LibraryMediaType.all,
      LibraryMediaType.movie,
      LibraryMediaType.video,
      LibraryMediaType.photo,
    },
    supportsGenres: true,
    supportsTags: true,
    supportsFavorites: true,
    supportsDirectories: true,
    supportsPlayedFilter: true,
    supportsLocalSourceFilter: true,
    supportsPlayAll: true,
    allItemTypes: 'Movie,Video,Photo',
  );

  static const photos = LibraryContentProfile._(
    kind: LibraryContentProfileKind.photos,
    allowedScopes: {
      LibraryBrowseScope.media,
      LibraryBrowseScope.directory,
      LibraryBrowseScope.favorites,
    },
    allowedMediaTypes: {LibraryMediaType.all, LibraryMediaType.photo},
    supportsGenres: false,
    supportsTags: false,
    supportsFavorites: true,
    supportsDirectories: true,
    supportsPlayedFilter: false,
    supportsLocalSourceFilter: false,
    supportsPlayAll: false,
    allItemTypes: 'Photo',
  );

  static const mixed = LibraryContentProfile._(
    kind: LibraryContentProfileKind.mixed,
    allowedScopes: _allRootScopes,
    allowedMediaTypes: {
      LibraryMediaType.all,
      LibraryMediaType.movie,
      LibraryMediaType.series,
      LibraryMediaType.video,
      LibraryMediaType.photo,
    },
    supportsGenres: true,
    supportsTags: true,
    supportsFavorites: true,
    supportsDirectories: true,
    supportsPlayedFilter: true,
    supportsLocalSourceFilter: true,
    supportsPlayAll: true,
    allItemTypes: 'Movie,Series,Video,Photo',
  );

  static const unknown = LibraryContentProfile._(
    kind: LibraryContentProfileKind.unknown,
    allowedScopes: _allRootScopes,
    allowedMediaTypes: {
      LibraryMediaType.all,
      LibraryMediaType.movie,
      LibraryMediaType.series,
      LibraryMediaType.video,
      LibraryMediaType.photo,
    },
    supportsGenres: true,
    supportsTags: true,
    supportsFavorites: true,
    supportsDirectories: true,
    supportsPlayedFilter: true,
    supportsLocalSourceFilter: true,
    supportsPlayAll: true,
    allItemTypes: 'Movie,Series,Video,Photo',
  );

  Set<LibraryBrowseScope> visibleScopes(LibraryCategorySettings settings) =>
      Set.unmodifiable(
        allowedScopes.where((scope) {
          if (scope == LibraryBrowseScope.directory) {
            return settings.showFolders;
          }
          if (scope == LibraryBrowseScope.favorites) {
            return settings.showFavorites;
          }
          return true;
        }),
      );

  Set<LibraryMediaType> visibleMediaTypes(LibraryCategorySettings settings) =>
      Set.unmodifiable(
        allowedMediaTypes.where((mediaType) {
          return switch (mediaType) {
            LibraryMediaType.all => true,
            LibraryMediaType.movie => settings.showMovies,
            LibraryMediaType.series => settings.showSeries,
            LibraryMediaType.video => settings.showVideos,
            LibraryMediaType.photo => settings.showPhotos,
          };
        }),
      );

  String includeItemTypesFor(LibraryMediaType mediaType) {
    if (!allowedMediaTypes.contains(mediaType)) {
      throw ArgumentError.value(
        mediaType,
        'mediaType',
        'Media type is not supported by ${kind.name}',
      );
    }
    return switch (mediaType) {
      LibraryMediaType.all => _allItemTypes,
      LibraryMediaType.movie => 'Movie',
      LibraryMediaType.series => 'Series',
      LibraryMediaType.video => 'Video',
      LibraryMediaType.photo => 'Photo',
    };
  }
}
