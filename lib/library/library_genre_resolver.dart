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
  static const maxGenrePages = 128;
  static const maxGenreTerms = 10000;

  final EmbyApi api;
  final Map<String, LibraryFacet> _cache = {};
  final Map<String, Future<LibraryFacet>> _inFlight = {};
  int _cacheGeneration = 0;

  void clear() {
    _cacheGeneration++;
    _cache.clear();
    _inFlight.clear();
  }

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

    final cacheKey = _cacheKey(libraryId, origin, normalizedName);
    for (var retry = 0; retry < 2; retry++) {
      final generation = _cacheGeneration;
      final cached = _cache[cacheKey];
      if (cached != null) return cached;
      final active = _inFlight[cacheKey];
      if (active != null) {
        final facet = await active;
        if (generation == _cacheGeneration) return facet;
        continue;
      }

      final future = _resolveUncached(
        origin: origin,
        requestedName: genreName.trim(),
        normalizedName: normalizedName,
        cacheKey: cacheKey,
        cacheGeneration: generation,
      );
      _inFlight[cacheKey] = future;
      try {
        final facet = await future;
        if (generation == _cacheGeneration) return facet;
      } finally {
        if (identical(_inFlight[cacheKey], future)) _inFlight.remove(cacheKey);
      }
    }
    throw const LibraryGenreResolutionException(
      LibraryGenreResolutionFailure.requestFailed,
    );
  }

  Future<LibraryFacet> _resolveUncached({
    required LibraryBrowseOrigin origin,
    required String requestedName,
    required String normalizedName,
    required String cacheKey,
    required int cacheGeneration,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final entries = await _readGenreIndex(origin);
      final facet = _match(
        entries,
        requestedName: requestedName,
        normalizedName: normalizedName,
      );
      if (facet != null) {
        if (cacheGeneration == _cacheGeneration) _cache[cacheKey] = facet;
        return facet;
      }
    }
    throw const LibraryGenreResolutionException(
      LibraryGenreResolutionFailure.notFound,
    );
  }

  Future<List<EmbyItem>> _readGenreIndex(LibraryBrowseOrigin origin) async {
    final entriesById = <String, EmbyItem>{};
    final seenGenreIds = <String>{};
    final pageFingerprints = <String>{};
    var startIndex = 0;
    var pageCount = 0;
    int? totalCount;
    try {
      while (true) {
        if (pageCount >= maxGenrePages) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }
        pageCount++;
        final page = await api.getLibraryGenres(
          parentId: origin.rootView.id.trim(),
          profile: origin.profile,
          startIndex: startIndex,
          limit: pageSize,
        );
        final validItems = page.items
            .where(
              (item) =>
                  item.id.trim().isNotEmpty && item.name.trim().isNotEmpty,
            )
            .toList(growable: false);
        final fingerprintParts =
            validItems
                .map(
                  (item) =>
                      '${item.id.trim()}\u0000${normalizeLibraryGenreName(item.name)}',
                )
                .toList()
              ..sort();
        final fingerprint =
            '${page.rawItemCount}\u0000${fingerprintParts.join('\u0001')}';
        if (!pageFingerprints.add(fingerprint)) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }

        var newGenreCount = 0;
        for (final item in validItems) {
          final id = item.id.trim();
          if (seenGenreIds.add(id)) {
            newGenreCount++;
            entriesById[id] = item;
          }
        }
        if (entriesById.length > maxGenreTerms) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }

        final cursor = advanceLibraryRawPageCursor(
          currentStartIndex: startIndex,
          rawItemCount: page.rawItemCount,
          pageSize: pageSize,
          currentTotalCount: totalCount,
          reportedTotalCount: page.totalRecordCount,
        );
        totalCount = cursor.totalCount;
        if (cursor.paginationStalled) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }
        if (cursor.hasMore && newGenreCount == 0) {
          throw const LibraryGenreResolutionException(
            LibraryGenreResolutionFailure.paginationStalled,
          );
        }
        if (!cursor.hasMore) return entriesById.values.toList(growable: false);
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

  String _cacheKey(
    String libraryId,
    LibraryBrowseOrigin origin,
    String normalizedName,
  ) => '$libraryId\u0000${origin.profile.kind}\u0000$normalizedName';
}

String normalizeLibraryGenreName(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
