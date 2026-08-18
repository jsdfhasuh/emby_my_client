import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'library_browse_state.dart';
import 'library_navigation_context.dart';
import 'library_raw_page_cursor.dart';

enum LibraryGenreResolutionFailure {
  notFound,
  ambiguous,
  paginationStalled,
  unsupportedProfile,
  requestFailed,
}

class LibraryGenreResolutionException implements Exception {
  const LibraryGenreResolutionException(this.failure);

  final LibraryGenreResolutionFailure failure;

  @override
  String toString() => 'LibraryGenreResolutionException(${failure.name})';
}

class LibraryGenreResolver {
  LibraryGenreResolver({required this.api});

  static const pageSize = 60;

  final EmbyApi api;
  final Map<String, LibraryFacet> _cache = {};
  final Map<String, Future<LibraryFacet>> _inFlight = {};

  Future<LibraryFacet> resolve({
    required LibraryBrowseOrigin origin,
    required String genreName,
  }) async {
    final normalizedName = normalizeLibraryGenreName(genreName);
    final libraryId = origin.rootView.id.trim();
    if (libraryId.isEmpty || normalizedName.isEmpty) {
      throw const LibraryGenreResolutionException(
        LibraryGenreResolutionFailure.notFound,
      );
    }
    if (!origin.profile.supportsGenres) {
      throw const LibraryGenreResolutionException(
        LibraryGenreResolutionFailure.unsupportedProfile,
      );
    }

    final cacheKey = _cacheKey(libraryId, normalizedName);
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    final active = _inFlight[cacheKey];
    if (active != null) return active;

    final future = _resolveUncached(
      origin: origin,
      requestedName: genreName.trim(),
      normalizedName: normalizedName,
      cacheKey: cacheKey,
    );
    _inFlight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[cacheKey], future)) _inFlight.remove(cacheKey);
    }
  }

  Future<LibraryFacet> _resolveUncached({
    required LibraryBrowseOrigin origin,
    required String requestedName,
    required String normalizedName,
    required String cacheKey,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final entries = await _readGenreIndex(origin);
      final facet = _match(
        entries,
        requestedName: requestedName,
        normalizedName: normalizedName,
      );
      if (facet != null) {
        _cache[cacheKey] = facet;
        return facet;
      }
    }
    throw const LibraryGenreResolutionException(
      LibraryGenreResolutionFailure.notFound,
    );
  }

  Future<List<EmbyItem>> _readGenreIndex(LibraryBrowseOrigin origin) async {
    final entries = <EmbyItem>[];
    var startIndex = 0;
    try {
      while (true) {
        final page = await api.getLibraryGenres(
          parentId: origin.rootView.id,
          profile: origin.profile,
          startIndex: startIndex,
          limit: pageSize,
        );
        entries.addAll(
          page.items.where(
            (item) => item.id.trim().isNotEmpty && item.name.trim().isNotEmpty,
          ),
        );
        final cursor = advanceLibraryRawPageCursor(
          currentStartIndex: startIndex,
          rawItemCount: page.rawItemCount,
          pageSize: pageSize,
          reportedTotalCount: page.totalRecordCount,
        );
        if (cursor.paginationStalled) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }
        if (!cursor.hasMore) return entries;
        if (cursor.nextStartIndex <= startIndex) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }
        startIndex = cursor.nextStartIndex;
      }
    } on LibraryGenreResolutionException {
      rethrow;
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'library',
        'Failed to load library genre index',
        error: error,
        stackTrace: stackTrace,
      );
      throw const LibraryGenreResolutionException(
        LibraryGenreResolutionFailure.requestFailed,
      );
    }
  }

  LibraryFacet? _match(
    List<EmbyItem> entries, {
    required String requestedName,
    required String normalizedName,
  }) {
    final idsByNormalizedName = <String, Set<String>>{};
    for (final entry in entries) {
      final normalized = normalizeLibraryGenreName(entry.name);
      if (normalized.isEmpty) continue;
      idsByNormalizedName
          .putIfAbsent(normalized, () => <String>{})
          .add(entry.id.trim());
    }
    if ((idsByNormalizedName[normalizedName]?.length ?? 0) > 1) {
      throw const LibraryGenreResolutionException(
        LibraryGenreResolutionFailure.ambiguous,
      );
    }

    final exact = entries.where((entry) => entry.name == requestedName);
    final trimmed = entries.where(
      (entry) => entry.name.trim() == requestedName.trim(),
    );
    final normalized = entries.where(
      (entry) => normalizeLibraryGenreName(entry.name) == normalizedName,
    );
    final matched =
        exact.firstOrNull ?? trimmed.firstOrNull ?? normalized.firstOrNull;
    if (matched == null) return null;
    return LibraryFacet(
      id: matched.id.trim(),
      name: matched.name,
      kind: LibraryFacetKind.genre,
    );
  }

  String _cacheKey(String libraryId, String normalizedName) =>
      '$libraryId\u0000$normalizedName';
}

String normalizeLibraryGenreName(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
