import 'package:flutter/foundation.dart';

enum LibraryRawPageDisposition { hasMore, complete, paginationStalled }

@immutable
class LibraryRawPageCursorUpdate {
  const LibraryRawPageCursorUpdate({
    required this.nextStartIndex,
    required this.totalCount,
    required this.totalChanged,
    required this.dirty,
    required this.disposition,
  });

  final int nextStartIndex;
  final int? totalCount;
  final bool totalChanged;
  final bool dirty;
  final LibraryRawPageDisposition disposition;

  bool get hasMore => disposition == LibraryRawPageDisposition.hasMore;

  bool get paginationStalled =>
      disposition == LibraryRawPageDisposition.paginationStalled;
}

LibraryRawPageCursorUpdate advanceLibraryRawPageCursor({
  required int currentStartIndex,
  required int rawItemCount,
  required int pageSize,
  int? currentTotalCount,
  int? reportedTotalCount,
  bool dirty = false,
}) {
  if (currentStartIndex < 0) {
    throw ArgumentError.value(
      currentStartIndex,
      'currentStartIndex',
      'must not be negative',
    );
  }
  if (rawItemCount < 0) {
    throw ArgumentError.value(
      rawItemCount,
      'rawItemCount',
      'must not be negative',
    );
  }
  if (pageSize <= 0) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
  }
  if (currentTotalCount != null && currentTotalCount < 0) {
    throw ArgumentError.value(
      currentTotalCount,
      'currentTotalCount',
      'must not be negative',
    );
  }
  if (reportedTotalCount != null && reportedTotalCount < 0) {
    throw ArgumentError.value(
      reportedTotalCount,
      'reportedTotalCount',
      'must not be negative',
    );
  }

  final totalChanged =
      currentTotalCount != null &&
      reportedTotalCount != null &&
      currentTotalCount != reportedTotalCount;
  final totalCount = reportedTotalCount ?? currentTotalCount;
  final nextStartIndex = currentStartIndex + rawItemCount;
  final disposition = switch ((rawItemCount, totalCount)) {
    (0, final int total) when nextStartIndex < total =>
      LibraryRawPageDisposition.paginationStalled,
    (0, _) => LibraryRawPageDisposition.complete,
    (_, final int total) when nextStartIndex < total =>
      LibraryRawPageDisposition.hasMore,
    (_, final int _) => LibraryRawPageDisposition.complete,
    (_, null) when rawItemCount == pageSize =>
      LibraryRawPageDisposition.hasMore,
    _ => LibraryRawPageDisposition.complete,
  };

  return LibraryRawPageCursorUpdate(
    nextStartIndex: nextStartIndex,
    totalCount: totalCount,
    totalChanged: totalChanged,
    dirty: dirty || totalChanged,
    disposition: disposition,
  );
}

class LibraryPaginationStalled implements Exception {
  const LibraryPaginationStalled();

  @override
  String toString() => 'LibraryPaginationStalled';
}

class LibraryResultChanged implements Exception {
  const LibraryResultChanged();

  @override
  String toString() => 'LibraryResultChanged';
}
