import 'package:emby_my_client/library/library_grid_geometry.dart';
import 'package:emby_my_client/library/library_scroll_position_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LibraryScrollPositionController', () {
    for (final entry in const [
      (160.0, 1),
      (340.0, 2),
      (520.0, 3),
      (700.0, 4),
    ]) {
      test('calculates the first two visible rows for ${entry.$2} columns', () {
        final controller = LibraryScrollPositionController();
        addTearDown(controller.dispose);
        final base = _constraints(crossAxisExtent: entry.$1);
        final layout = _layout(base);

        expect(layout.crossAxisCount, entry.$2);
        controller.updateLayout(
          constraints: base.copyWith(
            remainingPaintExtent: layout.mainAxisStride * 2,
          ),
          loadedCount: 100,
          totalCount: 100,
        );

        expect(
          controller.snapshot,
          LibraryPositionSnapshot(
            firstVisible: 1,
            lastVisible: entry.$2 * 2,
            loadedCount: 100,
            totalCount: 100,
          ),
        );
      });
    }

    test('uses grid-local offsets instead of preceding toolbar extent', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      final base = _constraints(crossAxisExtent: 520);
      final layout = _layout(base);
      final localOffset = layout.mainAxisStride * 3;
      final visibleExtent = layout.mainAxisStride * 2;

      controller.updateLayout(
        constraints: base.copyWith(
          scrollOffset: localOffset,
          remainingPaintExtent: visibleExtent,
          precedingScrollExtent: 0,
        ),
        loadedCount: 100,
        totalCount: 100,
      );
      final withoutToolbar = controller.snapshot;
      controller.updateLayout(
        constraints: base.copyWith(
          scrollOffset: localOffset,
          remainingPaintExtent: visibleExtent,
          precedingScrollExtent: 480,
        ),
        loadedCount: 100,
        totalCount: 100,
      );

      expect(controller.snapshot, withoutToolbar);
      expect(controller.snapshot?.firstVisible, 10);
      expect(controller.snapshot?.lastVisible, 15);
    });

    test('skips a row that is fully above the viewport', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      final base = _constraints(crossAxisExtent: 520);
      final layout = _layout(base);

      controller.updateLayout(
        constraints: base.copyWith(
          scrollOffset: layout.childMainAxisExtent + 1,
          remainingPaintExtent: layout.childMainAxisExtent,
        ),
        loadedCount: 30,
        totalCount: 30,
      );

      expect(controller.snapshot?.firstVisible, 4);
    });

    test('caps an incomplete final row at the real loaded count', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      final base = _constraints(crossAxisExtent: 700);
      final layout = _layout(base);

      controller.updateLayout(
        constraints: base.copyWith(
          scrollOffset: layout.mainAxisStride * 2,
          remainingPaintExtent: layout.childMainAxisExtent,
        ),
        loadedCount: 10,
        totalCount: 10,
      );

      expect(controller.snapshot?.firstVisible, 9);
      expect(controller.snapshot?.lastVisible, 10);
    });

    test('keeps server percentage when only the first page is loaded', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      final base = _constraints(crossAxisExtent: 520);
      final layout = _layout(base);
      final constraints = base.copyWith(
        scrollOffset: layout.mainAxisStride * 18,
        remainingPaintExtent: layout.mainAxisStride * 2,
      );

      controller.updateLayout(
        constraints: constraints,
        loadedCount: 60,
        totalCount: 1286,
      );
      final firstPage = controller.snapshot;
      expect(firstPage?.firstVisible, 55);
      expect(firstPage?.lastVisible, 60);
      expect(firstPage?.percentage, lessThan(10));
      expect(firstPage?.percentage, isNot(100));
      expect(firstPage?.remainingCount, 1226);

      controller.updateLayout(
        constraints: constraints,
        loadedCount: 120,
        totalCount: 1286,
      );
      expect(controller.snapshot?.firstVisible, firstPage?.firstVisible);
      expect(controller.snapshot?.lastVisible, firstPage?.lastVisible);
      expect(controller.snapshot?.loadedCount, 120);
    });

    test('recalculates after the cross-axis column count changes', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      final portrait = _constraints(crossAxisExtent: 340);
      final portraitLayout = _layout(portrait);
      controller.updateLayout(
        constraints: portrait.copyWith(
          scrollOffset: portraitLayout.mainAxisStride * 2,
          remainingPaintExtent: portraitLayout.mainAxisStride * 2,
        ),
        loadedCount: 60,
        totalCount: 120,
      );
      expect(controller.snapshot?.firstVisible, 5);

      final landscape = _constraints(crossAxisExtent: 700);
      final landscapeLayout = _layout(landscape);
      controller.updateLayout(
        constraints: landscape.copyWith(
          scrollOffset: landscapeLayout.mainAxisStride * 2,
          remainingPaintExtent: landscapeLayout.mainAxisStride * 2,
        ),
        loadedCount: 60,
        totalCount: 120,
      );
      expect(controller.snapshot?.firstVisible, 9);
      expect(controller.snapshot?.lastVisible, 16);
    });

    test('omits percentage when the server total is unknown', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);

      controller.updateLayout(
        constraints: _constraints(
          crossAxisExtent: 340,
          remainingPaintExtent: 400,
        ),
        loadedCount: 60,
        totalCount: null,
      );

      expect(controller.snapshot?.totalCount, isNull);
      expect(controller.snapshot?.percentage, isNull);
      expect(controller.snapshot?.remainingCount, isNull);
    });

    test('does not show when the full result fits in one viewport', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      controller.updateLayout(
        constraints: _constraints(
          crossAxisExtent: 700,
          remainingPaintExtent: 800,
        ),
        loadedCount: 4,
        totalCount: 4,
      );

      controller.onScrollStart();

      expect(controller.snapshot, isNotNull);
      expect(controller.isVisible, isFalse);
    });

    test('notifies layout listeners only when the snapshot changes', () {
      final controller = LibraryScrollPositionController();
      addTearDown(controller.dispose);
      final base = _constraints(crossAxisExtent: 520);
      final layout = _layout(base);
      final visibleExtent = layout.childMainAxisExtent - 2;
      controller.updateLayout(
        constraints: base.copyWith(remainingPaintExtent: visibleExtent),
        loadedCount: 60,
        totalCount: 120,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.updateLayout(
        constraints: base.copyWith(
          scrollOffset: 1,
          remainingPaintExtent: visibleExtent,
        ),
        loadedCount: 60,
        totalCount: 120,
      );
      expect(notifications, 0);

      controller.updateLayout(
        constraints: base.copyWith(
          scrollOffset: layout.mainAxisStride,
          remainingPaintExtent: visibleExtent,
        ),
        loadedCount: 60,
        totalCount: 120,
      );
      expect(notifications, 1);
    });
  });
}

SliverGridRegularTileLayout _layout(SliverConstraints constraints) =>
    libraryMediaGridGeometry.getLayout(constraints)
        as SliverGridRegularTileLayout;

SliverConstraints _constraints({
  required double crossAxisExtent,
  double scrollOffset = 0,
  double remainingPaintExtent = 800,
  double precedingScrollExtent = 0,
  double viewportMainAxisExtent = 800,
}) => SliverConstraints(
  axisDirection: AxisDirection.down,
  growthDirection: GrowthDirection.forward,
  userScrollDirection: ScrollDirection.idle,
  scrollOffset: scrollOffset,
  precedingScrollExtent: precedingScrollExtent,
  overlap: 0,
  remainingPaintExtent: remainingPaintExtent,
  crossAxisExtent: crossAxisExtent,
  crossAxisDirection: AxisDirection.right,
  viewportMainAxisExtent: viewportMainAxisExtent,
  remainingCacheExtent: remainingPaintExtent,
  cacheOrigin: 0,
);
