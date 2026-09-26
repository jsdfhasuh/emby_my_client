import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../images/emby_image_request.dart';
import '../images/photo_prefetcher.dart';
import '../library/library_pagination_strategy.dart';
import '../library/library_raw_page_cursor.dart';
import '../models/emby_models.dart';
import 'photo_sequence_source.dart';

typedef PhotoImageRequestBuilder = EmbyImageRequest? Function(EmbyItem item);

class PhotoViewerController extends ChangeNotifier {
  PhotoViewerController({
    required PhotoSequenceSource source,
    required PhotoImageRequestBuilder imageRequestFor,
    required PhotoPrefetcher prefetcher,
    this.pageSize = 60,
    this.loadAheadThreshold = 8,
    this.controlsHideDelay = const Duration(seconds: 4),
  }) : _source = source,
       _imageRequestFor = imageRequestFor,
       _prefetcher = prefetcher,
       _hasMore = source.initialHasMore,
       _nextStartIndex = source.initialRawCursor,
       _totalCount = source.initialTotalCount,
       _totalDirty = source.initialTotalDirty {
    _rawItems.addAll(
      source.initialItems.where((item) => _seenItemIds.add(item.id)),
    );
    _mediaItems.addAll(_rawItems.where(source.mode.accepts));
    final initialIndex = _mediaItems.indexWhere(
      (item) => item.id == source.initialItemId,
    );
    _currentIndex = initialIndex < 0 ? 0 : initialIndex;
    _scheduleHideControls();
    _schedulePrefetch();
    unawaited(loadMoreIfNeeded());
  }

  final int pageSize;
  final int loadAheadThreshold;
  final Duration controlsHideDelay;
  final PhotoSequenceSource _source;
  final PhotoImageRequestBuilder _imageRequestFor;
  final PhotoPrefetcher _prefetcher;
  final List<EmbyItem> _rawItems = [];
  final List<EmbyItem> _mediaItems = [];
  final Set<String> _seenItemIds = {};

  int _currentIndex = 0;
  int _nextStartIndex;
  int? _totalCount;
  bool _totalDirty;
  bool _reportedTotalBelowLoaded = false;
  bool _hasMore;
  bool _loadingMore = false;
  bool _controlsVisible = true;
  bool _disposed = false;
  Object? _loadMoreError;
  Timer? _hideTimer;

  List<EmbyItem> get mediaItems => List.unmodifiable(_mediaItems);
  List<EmbyItem> get photos => mediaItems;
  int get currentIndex => _currentIndex;
  bool get hasMore => _hasMore;
  bool get isLoadingMore => _loadingMore;
  bool get controlsVisible => _controlsVisible;
  Object? get loadMoreError => _loadMoreError;
  bool get canGoPrevious => _currentIndex > 0;
  bool get canGoNext => _currentIndex + 1 < _mediaItems.length;
  String get queryFingerprint => _source.queryFingerprint;
  int get nextStartIndex => _nextStartIndex;
  int? get totalCount => _totalCount;
  bool get totalDirty => _totalDirty;
  String? get currentItemId =>
      _mediaItems.isEmpty ? null : _mediaItems[_currentIndex].id;
  MediaViewerResult get result => MediaViewerResult(
    queryFingerprint: _source.queryFingerprint,
    rawItems: _rawItems,
    currentItemId: currentItemId,
    nextStartIndex: _nextStartIndex,
    totalCount: _totalCount,
    totalDirty: _totalDirty,
    hasMore: _hasMore,
    paginationStrategy: _source.paginationStrategy,
  );

  String get positionLabel {
    if (_mediaItems.isEmpty) return '0 / 0';
    return '${_currentIndex + 1} / ${_mediaItems.length}${_hasMore ? '+' : ''}';
  }

  void setCurrentIndex(int index) {
    if (_disposed || index < 0 || index >= _mediaItems.length) return;
    if (_currentIndex != index) {
      _currentIndex = index;
      _loadMoreError = null;
      _notify();
    }
    showControlsTemporarily();
    _schedulePrefetch();
    if (_mediaItems.length - _currentIndex <= loadAheadThreshold) {
      unawaited(loadMoreIfNeeded());
    }
  }

  void refreshPrefetch() {
    _schedulePrefetch();
  }

  Future<void> loadMoreIfNeeded({bool force = false}) async {
    if (_disposed || _loadingMore || !_hasMore) return;
    if (!force && _mediaItems.length - _currentIndex > loadAheadThreshold) {
      return;
    }
    _loadingMore = true;
    _loadMoreError = null;
    _notify();
    try {
      if (_source.paginationStrategy ==
          LibraryPaginationStrategy.identityRescan) {
        await _loadIdentityRescan();
      } else {
        await _loadStableOffset();
      }
      _schedulePrefetch();
    } catch (error, stackTrace) {
      if (!_disposed) {
        DiagnosticLog.instance.error(
          'photo',
          'Photo viewer page load failed',
          error: error,
          stackTrace: stackTrace,
        );
        _loadMoreError = error;
      }
    } finally {
      if (!_disposed) {
        _loadingMore = false;
        _notify();
      }
    }
  }

  Future<void> _loadStableOffset() async {
    var addedMedia = 0;
    do {
      final startIndex = _nextStartIndex;
      final page = await _source.loadPage(
        startIndex: startIndex,
        limit: pageSize,
      );
      if (_disposed) return;
      final cursor = advanceLibraryRawPageCursor(
        currentStartIndex: startIndex,
        currentTotalCount: _totalCount,
        reportedTotalCount: page.totalRecordCount,
        rawItemCount: page.rawItemCount,
        pageSize: pageSize,
        dirty: _totalDirty,
      );
      final additions = page.items
          .where((item) => _seenItemIds.add(item.id))
          .toList();
      _rawItems.addAll(additions);
      final media = additions.where(_source.mode.accepts).toList();
      _mediaItems.addAll(media);
      addedMedia += media.length;
      _nextStartIndex = cursor.nextStartIndex;
      _totalCount = cursor.totalCount;
      _totalDirty = cursor.dirty;
      _hasMore = cursor.hasMore || cursor.paginationStalled;
      _recordCursorDiagnostics(cursor);
      if (cursor.paginationStalled) {
        throw const LibraryPaginationStalled();
      }
    } while (_hasMore && addedMedia == 0);
  }

  Future<void> _loadIdentityRescan() async {
    final previousRawIds = _rawItems.map((item) => item.id).toList();
    final previousMediaIds = _mediaItems.map((item) => item.id).toSet();
    final previousCurrentItemId = currentItemId;
    final previousCurrentIndex = _currentIndex;
    final previousRawCursor = _nextStartIndex;
    final rescannedItems = <EmbyItem>[];
    final rescannedIds = <String>{};
    var scanStartIndex = 0;
    var scanTotalCount = _totalCount;
    var scanDirty = _totalDirty;
    var scanHasMore = true;
    var foundNewMedia = false;

    do {
      final page = await _source.loadPage(
        startIndex: scanStartIndex,
        limit: pageSize,
      );
      if (_disposed) return;
      final cursor = advanceLibraryRawPageCursor(
        currentStartIndex: scanStartIndex,
        currentTotalCount: scanTotalCount,
        reportedTotalCount: page.totalRecordCount,
        rawItemCount: page.rawItemCount,
        pageSize: pageSize,
        dirty: scanDirty,
      );
      for (final item in page.items) {
        if (!rescannedIds.add(item.id)) continue;
        rescannedItems.add(item);
        if (_source.mode.accepts(item) && !previousMediaIds.contains(item.id)) {
          foundNewMedia = true;
        }
      }
      scanStartIndex = cursor.nextStartIndex;
      scanTotalCount = cursor.totalCount;
      scanDirty = cursor.dirty;
      scanHasMore = cursor.hasMore || cursor.paginationStalled;
      _recordCursorDiagnostics(cursor);
      if (cursor.paginationStalled) {
        throw const LibraryPaginationStalled();
      }
    } while (scanHasMore &&
        (scanStartIndex <= previousRawCursor || !foundNewMedia));

    scanDirty =
        scanDirty ||
        libraryIdentityPrefixChanged(
          previousIds: previousRawIds,
          rescannedIds: rescannedItems.map((item) => item.id),
        );
    _rawItems
      ..clear()
      ..addAll(rescannedItems);
    _seenItemIds
      ..clear()
      ..addAll(rescannedIds);
    _mediaItems
      ..clear()
      ..addAll(rescannedItems.where(_source.mode.accepts));
    if (_mediaItems.isEmpty) {
      _currentIndex = 0;
    } else {
      final restoredIndex = previousCurrentItemId == null
          ? -1
          : _mediaItems.indexWhere((item) => item.id == previousCurrentItemId);
      _currentIndex = restoredIndex >= 0
          ? restoredIndex
          : previousCurrentIndex.clamp(0, _mediaItems.length - 1).toInt();
    }
    _nextStartIndex = scanStartIndex;
    _totalCount = scanTotalCount;
    _totalDirty = scanDirty;
    _hasMore = scanHasMore;
  }

  void _recordCursorDiagnostics(LibraryRawPageCursorUpdate cursor) {
    if (cursor.totalChanged) {
      DiagnosticLog.instance.warning(
        'photo',
        'Photo viewer total changed; statistics require refresh',
      );
    }
    final total = cursor.totalCount;
    if (!_reportedTotalBelowLoaded &&
        total != null &&
        total < _rawItems.length) {
      _reportedTotalBelowLoaded = true;
      DiagnosticLog.instance.warning(
        'photo',
        'Photo viewer total below loaded count '
            'total=$total loaded=${_rawItems.length}',
      );
    }
    if (cursor.paginationStalled) {
      DiagnosticLog.instance.warning(
        'photo',
        'Photo viewer pagination stalled before reported total',
      );
    }
  }

  void toggleControls() {
    if (_disposed) return;
    if (_controlsVisible) {
      _hideTimer?.cancel();
      _controlsVisible = false;
      _notify();
    } else {
      showControlsTemporarily();
    }
  }

  void showControlsTemporarily() {
    if (_disposed) return;
    _controlsVisible = true;
    _notify();
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(controlsHideDelay, () {
      if (_disposed) return;
      _controlsVisible = false;
      _notify();
    });
  }

  void _schedulePrefetch() {
    if (_disposed || _mediaItems.isEmpty) return;
    final indexes = <int>[
      _currentIndex,
      _currentIndex + 1,
      _currentIndex - 1,
      _currentIndex + 2,
      _currentIndex - 2,
    ];
    final requests = <EmbyImageRequest>[];
    final seen = <String>{};
    for (final index in indexes) {
      if (index < 0 || index >= _mediaItems.length) continue;
      final request = _imageRequestFor(_mediaItems[index]);
      if (request != null && seen.add(request.cacheKey)) requests.add(request);
    }
    _prefetcher.schedule(requests);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hideTimer?.cancel();
    _prefetcher.dispose();
    super.dispose();
  }
}
