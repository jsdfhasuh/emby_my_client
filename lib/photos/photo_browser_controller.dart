import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../library/library_raw_page_cursor.dart';
import '../models/emby_models.dart';
import 'photo_sequence_source.dart';

class PhotoBrowserController extends ChangeNotifier {
  PhotoBrowserController({
    required PhotoPageLoader loadPage,
    this.pageSize = 60,
  }) : _loadPage = loadPage;

  final int pageSize;
  final PhotoPageLoader _loadPage;
  final List<EmbyItem> _items = [];
  final Set<String> _seenItemIds = {};

  bool _loading = false;
  bool _hasMore = true;
  bool _disposed = false;
  Object? _error;
  int _generation = 0;
  int _nextStartIndex = 0;
  int? _totalCount;
  bool _totalDirty = false;
  bool _reportedTotalBelowLoaded = false;

  List<EmbyItem> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;
  bool get hasMore => _hasMore;
  Object? get error => _error;
  int get nextStartIndex => _nextStartIndex;
  int? get totalCount => _totalCount;
  bool get totalDirty => _totalDirty;

  Future<void> loadMore() async {
    if (_loading || !_hasMore || _disposed) return;
    await _requestPage(generation: _generation, reset: false);
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    _items.clear();
    _seenItemIds.clear();
    _nextStartIndex = 0;
    _totalCount = null;
    _totalDirty = false;
    _reportedTotalBelowLoaded = false;
    _hasMore = true;
    _error = null;
    _notify();
    await _requestPage(generation: generation, reset: true);
  }

  Future<void> _requestPage({
    required int generation,
    required bool reset,
  }) async {
    if (_disposed || generation != _generation) return;
    _loading = true;
    _error = null;
    _notify();
    final startIndex = reset ? 0 : _nextStartIndex;
    try {
      final page = await _loadPage(startIndex: startIndex, limit: pageSize);
      if (_disposed || generation != _generation) return;
      final cursor = advanceLibraryRawPageCursor(
        currentStartIndex: startIndex,
        currentTotalCount: _totalCount,
        reportedTotalCount: page.totalRecordCount,
        rawItemCount: page.rawItemCount,
        pageSize: pageSize,
        dirty: _totalDirty,
      );
      _items.addAll(
        page.items.where(
          (item) =>
              (item.isPhoto || item.isPhotoContainer) &&
              _seenItemIds.add(item.id),
        ),
      );
      _nextStartIndex = cursor.nextStartIndex;
      _totalCount = cursor.totalCount;
      _totalDirty = cursor.dirty;
      _hasMore = cursor.hasMore || cursor.paginationStalled;
      _recordCursorDiagnostics(cursor);
      if (cursor.paginationStalled) {
        throw const LibraryPaginationStalled();
      }
    } catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;
      DiagnosticLog.instance.error(
        'photo',
        'Photo directory page load failed',
        error: error,
        stackTrace: stackTrace,
      );
      _error = error;
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  void _recordCursorDiagnostics(LibraryRawPageCursorUpdate cursor) {
    if (cursor.totalChanged) {
      DiagnosticLog.instance.warning(
        'photo',
        'Photo directory total changed; statistics require refresh',
      );
    }
    final total = cursor.totalCount;
    if (!_reportedTotalBelowLoaded && total != null && total < _items.length) {
      _reportedTotalBelowLoaded = true;
      DiagnosticLog.instance.warning(
        'photo',
        'Photo directory total below loaded count '
            'total=$total loaded=${_items.length}',
      );
    }
    if (cursor.paginationStalled) {
      DiagnosticLog.instance.warning(
        'photo',
        'Photo directory pagination stalled before reported total',
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
