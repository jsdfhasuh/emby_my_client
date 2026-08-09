import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';

typedef PhotoPageLoader =
    Future<EmbyItemPage> Function({
      required int startIndex,
      required int limit,
    });

@immutable
sealed class PhotoSequenceSource {
  PhotoSequenceSource({
    required this.queryFingerprint,
    required List<EmbyItem> initialItems,
    required this.initialItemId,
    required this.initialRawCursor,
    required this.initialTotalCount,
    required this.initialHasMore,
    required this.loadPage,
  }) : assert(queryFingerprint != ''),
       assert(initialRawCursor >= 0),
       assert(initialTotalCount == null || initialTotalCount >= 0),
       initialItems = List.unmodifiable(initialItems);

  final String queryFingerprint;
  final List<EmbyItem> initialItems;
  final String initialItemId;
  final int initialRawCursor;
  final int? initialTotalCount;
  final bool initialHasMore;
  final PhotoPageLoader loadPage;
}

final class DirectoryPhotoSource extends PhotoSequenceSource {
  DirectoryPhotoSource({
    required super.queryFingerprint,
    required super.initialItems,
    required super.initialItemId,
    required super.initialRawCursor,
    required super.initialTotalCount,
    required super.initialHasMore,
    required super.loadPage,
  });
}

final class FilteredLibraryPhotoSource extends PhotoSequenceSource {
  FilteredLibraryPhotoSource({
    required super.queryFingerprint,
    required super.initialItems,
    required super.initialItemId,
    required super.initialRawCursor,
    required super.initialTotalCount,
    required super.initialHasMore,
    required super.loadPage,
  });
}
