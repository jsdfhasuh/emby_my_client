import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
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

  List<EmbyItem> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;
  bool get hasMore => _hasMore;
  Object? get error => _error;
  int get nextStartIndex => _nextStartIndex;
  int? get totalCount => _totalCount;

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
      _items.addAll(
        page.items.where(
          (item) =>
              (item.isPhoto || item.isPhotoContainer) &&
              _seenItemIds.add(item.id),
        ),
      );
      _nextStartIndex = startIndex + page.rawItemCount;
      if (page.totalRecordCount != null) {
        _totalCount = page.totalRecordCount;
      }
      _hasMore =
          page.rawItemCount > 0 &&
          (_totalCount != null
              ? _nextStartIndex < _totalCount!
              : page.rawItemCount == pageSize);
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
