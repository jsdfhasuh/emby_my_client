import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'library_grid_geometry.dart';

@immutable
class LibraryPositionSnapshot {
  const LibraryPositionSnapshot({
    required this.firstVisible,
    required this.lastVisible,
    required this.loadedCount,
    this.totalCount,
  }) : assert(firstVisible > 0),
       assert(lastVisible >= firstVisible),
       assert(loadedCount >= lastVisible),
       assert(totalCount == null || totalCount >= 0);

  final int firstVisible;
  final int lastVisible;
  final int loadedCount;
  final int? totalCount;

  int? get remainingCount {
    final total = totalCount;
    if (total == null) return null;
    return math.max(0, total - lastVisible);
  }

  int? get percentage {
    final total = totalCount;
    if (total == null || total <= 0) return null;
    final midpoint = (firstVisible + lastVisible) / 2;
    return (midpoint / total * 100).round().clamp(0, 100);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryPositionSnapshot &&
          firstVisible == other.firstVisible &&
          lastVisible == other.lastVisible &&
          loadedCount == other.loadedCount &&
          totalCount == other.totalCount;

  @override
  int get hashCode =>
      Object.hash(firstVisible, lastVisible, loadedCount, totalCount);
}

class LibraryScrollPositionController extends ChangeNotifier {
  LibraryScrollPositionController({
    this.hideDelay = const Duration(milliseconds: 700),
  });

  final Duration hideDelay;

  LibraryPositionSnapshot? _snapshot;
  Timer? _hideTimer;
  bool _canShow = false;
  bool _requestedVisible = false;
  bool _disposed = false;

  LibraryPositionSnapshot? get snapshot => _snapshot;
  bool get isVisible => _requestedVisible && _canShow && _snapshot != null;

  void updateLayout({
    required SliverConstraints constraints,
    required int loadedCount,
    required int? totalCount,
    LibraryGridGeometry geometry = libraryMediaGridGeometry,
  }) {
    if (_disposed) return;
    if (loadedCount <= 0 ||
        constraints.crossAxisExtent <= 0 ||
        constraints.remainingPaintExtent <= 0) {
      _setLayout(snapshot: null, canShow: false);
      return;
    }

    final layout = geometry.getLayout(constraints);
    if (layout is! SliverGridRegularTileLayout) {
      throw StateError('Library media grids must use a regular tile layout.');
    }

    final scrollOffset = math.max(0.0, constraints.scrollOffset);
    final visibleEnd = scrollOffset + constraints.remainingPaintExtent;
    var firstIndex = layout.getMinChildIndexForScrollOffset(scrollOffset);
    final firstGeometry = layout.getGeometryForChildIndex(firstIndex);
    if (firstGeometry.scrollOffset + firstGeometry.mainAxisExtent <=
        scrollOffset + precisionErrorTolerance) {
      firstIndex += layout.crossAxisCount;
    }
    firstIndex = firstIndex.clamp(0, loadedCount - 1);

    var lastIndex = layout.getMaxChildIndexForScrollOffset(visibleEnd);
    lastIndex = lastIndex.clamp(firstIndex, loadedCount - 1);

    final normalizedTotal = totalCount != null && totalCount >= 0
        ? math.max(totalCount, loadedCount)
        : null;
    final viewportItemCount = math.max(
      loadedCount,
      normalizedTotal ?? loadedCount,
    );
    final contentExtent =
        layout.computeMaxScrollOffset(viewportItemCount) +
        geometry.padding.vertical;
    final canShow =
        contentExtent >
        constraints.viewportMainAxisExtent + precisionErrorTolerance;

    _setLayout(
      snapshot: LibraryPositionSnapshot(
        firstVisible: firstIndex + 1,
        lastVisible: lastIndex + 1,
        loadedCount: loadedCount,
        totalCount: normalizedTotal,
      ),
      canShow: canShow,
    );
  }

  void onScrollStart() => _showForScroll();

  void onScrollUpdate() => _showForScroll();

  void onScrollEnd() {
    if (_disposed) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(hideDelay, () {
      if (_disposed || !_requestedVisible) return;
      _requestedVisible = false;
      notifyListeners();
    });
  }

  void clear() {
    if (_disposed) return;
    _hideTimer?.cancel();
    _hideTimer = null;
    final changed = _snapshot != null || _canShow || _requestedVisible;
    _snapshot = null;
    _canShow = false;
    _requestedVisible = false;
    if (changed) notifyListeners();
  }

  void _showForScroll() {
    if (_disposed) return;
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_requestedVisible) return;
    _requestedVisible = true;
    notifyListeners();
  }

  void _setLayout({
    required LibraryPositionSnapshot? snapshot,
    required bool canShow,
  }) {
    if (_snapshot == snapshot && _canShow == canShow) return;
    _snapshot = snapshot;
    _canShow = canShow;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hideTimer?.cancel();
    _hideTimer = null;
    super.dispose();
  }
}
