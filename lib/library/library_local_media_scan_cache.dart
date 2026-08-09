import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';
import 'library_alphabet_filter.dart';
import 'library_browse_state.dart';

enum LibraryLocalMediaKind { strm, regular, unknown }

enum LibraryScanStatus { queued, scanning, paused, complete, cancelled }

enum LibraryScanErrorKind {
  unauthorized,
  requestFailed,
  paginationStalled,
  capacityReached,
}

@immutable
class LibraryScanKey {
  const LibraryScanKey({
    required this.scopeNamespace,
    required this.libraryId,
    required this.scope,
    required this.mediaType,
    required this.playedFilter,
    required this.facet,
    required this.sortBy,
    required this.sortOrder,
    required this.alphabetFilter,
  });

  factory LibraryScanKey.fromBrowseState({
    required String scopeNamespace,
    required String libraryId,
    required LibraryBrowseState state,
  }) => LibraryScanKey(
    scopeNamespace: scopeNamespace,
    libraryId: libraryId,
    scope: state.scope,
    mediaType: state.mediaType,
    playedFilter: state.playedFilter,
    facet: state.facet,
    sortBy: state.sortBy,
    sortOrder: state.sortOrder,
    alphabetFilter: state.alphabetFilter,
  );

  final String scopeNamespace;
  final String libraryId;
  final LibraryBrowseScope scope;
  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
  final LibraryFacet? facet;
  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
  final LibraryAlphabetFilter alphabetFilter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryScanKey &&
          scopeNamespace == other.scopeNamespace &&
          libraryId == other.libraryId &&
          scope == other.scope &&
          mediaType == other.mediaType &&
          playedFilter == other.playedFilter &&
          facet == other.facet &&
          sortBy == other.sortBy &&
          sortOrder == other.sortOrder &&
          alphabetFilter == other.alphabetFilter;

  @override
  int get hashCode => Object.hash(
    scopeNamespace,
    libraryId,
    scope,
    mediaType,
    playedFilter,
    facet,
    sortBy,
    sortOrder,
    alphabetFilter,
  );
}

@immutable
class LibraryLocalScanSnapshot {
  const LibraryLocalScanSnapshot({
    required this.status,
    required this.rawCursor,
    required this.scannedRawCount,
    required this.sourceTotalCount,
    required this.strmCount,
    required this.regularCount,
    required this.unknownCount,
    required this.complete,
    required this.dirty,
    required this.safeError,
  });

  final LibraryScanStatus status;
  final int rawCursor;
  final int scannedRawCount;
  final int? sourceTotalCount;
  final int strmCount;
  final int regularCount;
  final int unknownCount;
  final bool complete;
  final bool dirty;
  final LibraryScanErrorKind? safeError;

  bool get canRetry => status == LibraryScanStatus.paused;
}

class LibraryLocalMediaScanCacheEntry {
  LibraryLocalMediaScanCacheEntry(this.key);

  final LibraryScanKey key;
  final Map<String, EmbyItem> itemsById = {};
  final List<String> orderedSourceIds = [];
  final Set<String> strmIds = {};
  final Set<String> regularIds = {};
  final Set<String> unknownIds = {};

  LibraryScanStatus status = LibraryScanStatus.queued;
  LibraryScanErrorKind? safeError;
  int rawCursor = 0;
  int scannedRawCount = 0;
  int? sourceTotalCount;
  bool dirty = false;
  int generation = 0;

  int get candidateCount => itemsById.length;

  LibraryLocalScanSnapshot get snapshot => LibraryLocalScanSnapshot(
    status: status,
    rawCursor: rawCursor,
    scannedRawCount: scannedRawCount,
    sourceTotalCount: sourceTotalCount,
    strmCount: strmIds.length,
    regularCount: regularIds.length,
    unknownCount: unknownIds.length,
    complete: status == LibraryScanStatus.complete,
    dirty: dirty,
    safeError: safeError,
  );

  void updateTotal(int? total) {
    if (total == null) return;
    final previous = sourceTotalCount;
    if (previous != null && previous != total) dirty = true;
    sourceTotalCount = total;
  }

  void addOrUpdate(EmbyItem item, LibraryLocalMediaKind kind) {
    final isNew = !itemsById.containsKey(item.id);
    itemsById[item.id] = item;
    if (isNew) orderedSourceIds.add(item.id);
    strmIds.remove(item.id);
    regularIds.remove(item.id);
    unknownIds.remove(item.id);
    switch (kind) {
      case LibraryLocalMediaKind.strm:
        strmIds.add(item.id);
      case LibraryLocalMediaKind.regular:
        regularIds.add(item.id);
      case LibraryLocalMediaKind.unknown:
        unknownIds.add(item.id);
    }
  }

  List<EmbyItem> itemsFor(LibraryLocalMediaFilter filter) {
    final selectedIds = switch (filter) {
      LibraryLocalMediaFilter.all => itemsById.keys.toSet(),
      LibraryLocalMediaFilter.strm => strmIds,
      LibraryLocalMediaFilter.regular => regularIds,
    };
    return List.unmodifiable(
      orderedSourceIds
          .where(selectedIds.contains)
          .map((id) => itemsById[id])
          .whereType<EmbyItem>(),
    );
  }
}

class LibraryLocalMediaScanCache {
  LibraryLocalMediaScanCache({this.maxCompletedSessions = 3});

  final int maxCompletedSessions;
  final LinkedHashMap<LibraryScanKey, LibraryLocalMediaScanCacheEntry>
  _entries = LinkedHashMap();

  Iterable<LibraryLocalMediaScanCacheEntry> get entries => _entries.values;

  LibraryLocalMediaScanCacheEntry? operator [](LibraryScanKey key) =>
      _entries[key];

  LibraryLocalMediaScanCacheEntry putIfAbsent(LibraryScanKey key) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }
    final created = LibraryLocalMediaScanCacheEntry(key);
    _entries[key] = created;
    return created;
  }

  void touchCompleted(LibraryScanKey key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    _entries[key] = entry;
    while (_entries.values
            .where(
              (candidate) => candidate.status == LibraryScanStatus.complete,
            )
            .length >
        maxCompletedSessions) {
      final oldestCompleted = _entries.entries
          .where(
            (candidate) => candidate.value.status == LibraryScanStatus.complete,
          )
          .firstOrNull;
      if (oldestCompleted == null) break;
      _entries.remove(oldestCompleted.key);
    }
  }

  void remove(LibraryScanKey key) => _entries.remove(key);

  void clear() => _entries.clear();
}

bool isLibraryLocalMediaCandidate(EmbyItem item) =>
    item.type == 'Movie' || item.type == 'Episode' || item.type == 'Video';

LibraryLocalMediaKind classifyLibraryLocalMedia(EmbyItem item) {
  if (!isLibraryLocalMediaCandidate(item)) {
    return LibraryLocalMediaKind.unknown;
  }
  if (item.isStrm) return LibraryLocalMediaKind.strm;

  final references = <(String?, String?)>[];
  if (_hasValue(item.path) || _hasValue(item.container)) {
    references.add((item.path, item.container));
  }
  for (final source in item.mediaSources) {
    references.add((source.path, source.container));
  }
  if (references.isEmpty) return LibraryLocalMediaKind.unknown;
  for (final reference in references) {
    if (!_isSafeRegularReference(reference.$1, reference.$2)) {
      return LibraryLocalMediaKind.unknown;
    }
  }
  return LibraryLocalMediaKind.regular;
}

bool _isSafeRegularReference(String? path, String? container) {
  final normalizedPath = path?.trim() ?? '';
  final normalizedContainer = container?.trim() ?? '';
  if (normalizedPath.isEmpty && normalizedContainer.isEmpty) return false;
  if (_hasControlCharacters(normalizedPath) ||
      _hasControlCharacters(normalizedContainer)) {
    return false;
  }
  final pathLooksValid =
      normalizedPath.isEmpty ||
      normalizedPath.contains('.') ||
      normalizedPath.contains('/') ||
      normalizedPath.contains(r'\');
  final containerLooksValid =
      normalizedContainer.isEmpty ||
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(normalizedContainer);
  return pathLooksValid && containerLooksValid;
}

bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

bool _hasControlCharacters(String value) =>
    value.codeUnits.any((codeUnit) => codeUnit < 0x20 || codeUnit == 0x7f);
