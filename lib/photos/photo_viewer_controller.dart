import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../images/emby_image_request.dart';
import '../images/photo_prefetcher.dart';
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
       _totalCount = source.initialTotalCount {
    _directoryItems.addAll(
      source.initialItems.where((item) => _seenItemIds.add(item.id)),
    );
    _photos.addAll(_directoryItems.where((item) => item.isPhoto));
    final initialIndex = _photos.indexWhere(
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
  final List<EmbyItem> _directoryItems = [];
  final List<EmbyItem> _photos = [];
  final Set<String> _seenItemIds = {};

  int _currentIndex = 0;
  int _nextStartIndex;
  int? _totalCount;
  bool _hasMore;
  bool _loadingMore = false;
  bool _controlsVisible = true;
  bool _disposed = false;
  Object? _loadMoreError;
  Timer? _hideTimer;

  List<EmbyItem> get photos => List.unmodifiable(_photos);
  int get currentIndex => _currentIndex;
  bool get hasMore => _hasMore;
  bool get isLoadingMore => _loadingMore;
  bool get controlsVisible => _controlsVisible;
  Object? get loadMoreError => _loadMoreError;
  bool get canGoPrevious => _currentIndex > 0;
  bool get canGoNext => _currentIndex + 1 < _photos.length;
  String get queryFingerprint => _source.queryFingerprint;
  int get nextStartIndex => _nextStartIndex;
  int? get totalCount => _totalCount;
  String? get currentItemId =>
      _photos.isEmpty ? null : _photos[_currentIndex].id;

  String get positionLabel {
    if (_photos.isEmpty) return '0 / 0';
    return '${_currentIndex + 1} / ${_photos.length}${_hasMore ? '+' : ''}';
  }

  void setCurrentIndex(int index) {
    if (_disposed || index < 0 || index >= _photos.length) return;
    if (_currentIndex != index) {
      _currentIndex = index;
      _loadMoreError = null;
      _notify();
    }
    showControlsTemporarily();
    _schedulePrefetch();
    if (_photos.length - _currentIndex <= loadAheadThreshold) {
      unawaited(loadMoreIfNeeded());
    }
  }

  void refreshPrefetch() {
    _schedulePrefetch();
  }

  Future<void> loadMoreIfNeeded({bool force = false}) async {
    if (_disposed || _loadingMore || !_hasMore) return;
    if (!force && _photos.length - _currentIndex > loadAheadThreshold) return;
    _loadingMore = true;
    _loadMoreError = null;
    _notify();
    try {
      var addedPhotos = 0;
      do {
        final page = await _source.loadPage(
          startIndex: _nextStartIndex,
          limit: pageSize,
        );
        if (_disposed) return;
        _nextStartIndex += page.rawItemCount;
        if (page.totalRecordCount != null) {
          _totalCount = page.totalRecordCount;
        }
        _hasMore =
            page.rawItemCount > 0 &&
            (_totalCount != null
                ? _nextStartIndex < _totalCount!
                : page.rawItemCount == pageSize);
        final additions = page.items
            .where((item) => _seenItemIds.add(item.id))
            .toList();
        _directoryItems.addAll(additions);
        final photos = additions.where((item) => item.isPhoto).toList();
        _photos.addAll(photos);
        addedPhotos += photos.length;
      } while (_hasMore && addedPhotos == 0);
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
    if (_disposed || _photos.isEmpty) return;
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
      if (index < 0 || index >= _photos.length) continue;
      final request = _imageRequestFor(_photos[index]);
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
