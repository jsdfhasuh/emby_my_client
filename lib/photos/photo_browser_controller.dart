import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';

typedef PhotoPageLoader =
    Future<List<EmbyItem>> Function({
      required String parentId,
      int startIndex,
      int limit,
    });

class PhotoBrowserController extends ChangeNotifier {
  PhotoBrowserController({
    required this.parentId,
    required PhotoPageLoader loadPage,
    this.pageSize = 60,
  }) : _loadPage = loadPage;

  final String parentId;
  final int pageSize;
  final PhotoPageLoader _loadPage;
  final List<EmbyItem> _items = [];

  bool _loading = false;
  bool _hasMore = true;
  bool _disposed = false;
  Object? _error;
  int _generation = 0;
  int _nextStartIndex = 0;

  List<EmbyItem> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;
  bool get hasMore => _hasMore;
  Object? get error => _error;

  Future<void> loadMore() async {
    if (_loading || !_hasMore || _disposed) return;
    await _requestPage(generation: _generation, reset: false);
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    _items.clear();
    _nextStartIndex = 0;
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
      final page = await _loadPage(
        parentId: parentId,
        startIndex: startIndex,
        limit: pageSize,
      );
      if (_disposed || generation != _generation) return;
      final seen = _items.map((item) => item.id).toSet();
      _items.addAll(
        page.where(
          (item) =>
              (item.isPhoto || item.isPhotoContainer) && seen.add(item.id),
        ),
      );
      _nextStartIndex = startIndex + page.length;
      _hasMore = page.length == pageSize;
    } catch (error) {
      if (_disposed || generation != _generation) return;
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
