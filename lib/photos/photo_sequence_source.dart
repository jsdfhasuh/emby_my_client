import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';

enum MediaViewerMode {
  photosOnly,
  homeMedia;

  bool accepts(EmbyItem item) => switch (this) {
    MediaViewerMode.photosOnly => item.isPhoto,
    MediaViewerMode.homeMedia => item.isPhoto || item.isPlayable,
  };
}

typedef PhotoPageLoader =
    Future<EmbyItemPage> Function({
      required int startIndex,
      required int limit,
    });

@immutable
final class MediaViewerResult {
  MediaViewerResult({
    required this.queryFingerprint,
    required List<EmbyItem> rawItems,
    required this.currentItemId,
    required this.nextStartIndex,
    required this.totalCount,
    required this.totalDirty,
    required this.hasMore,
  }) : assert(queryFingerprint != ''),
       assert(nextStartIndex >= 0),
       assert(totalCount == null || totalCount >= 0),
       rawItems = List.unmodifiable(rawItems);

  final String queryFingerprint;
  final List<EmbyItem> rawItems;
  final String? currentItemId;
  final int nextStartIndex;
  final int? totalCount;
  final bool totalDirty;
  final bool hasMore;
}

@immutable
sealed class PhotoSequenceSource {
  PhotoSequenceSource({
    this.mode = MediaViewerMode.photosOnly,
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

  final MediaViewerMode mode;
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
    super.mode = MediaViewerMode.photosOnly,
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
    super.mode = MediaViewerMode.photosOnly,
    required super.queryFingerprint,
    required super.initialItems,
    required super.initialItemId,
    required super.initialRawCursor,
    required super.initialTotalCount,
    required super.initialHasMore,
    required super.loadPage,
  });
}
