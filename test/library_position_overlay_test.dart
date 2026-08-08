import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_result_statistics.dart';
import 'package:emby_my_client/library/library_scroll_position_controller.dart';
import 'package:emby_my_client/ui/widgets/library_position_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows position and fades 700ms after scrolling ends', (
    tester,
  ) async {
    final controller = LibraryScrollPositionController();
    var backgroundTaps = 0;
    controller.updateLayout(
      constraints: _constraints(),
      loadedCount: 60,
      totalCount: 1286,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('background-target'),
                behavior: HitTestBehavior.opaque,
                onTap: () => backgroundTaps++,
              ),
              LibraryPositionOverlay(
                controller: controller,
                fadeDuration: const Duration(milliseconds: 100),
              ),
            ],
          ),
        ),
      ),
    );

    controller.onScrollStart();
    await tester.pump();
    expect(_opacity(tester), 1);
    expect(find.text('1\u20136'), findsOneWidget);
    expect(find.text('共 1,286 项'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('library-position-panel'))),
    );
    expect(backgroundTaps, 1);

    controller.onScrollEnd();
    await tester.pump(const Duration(milliseconds: 699));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('new scrolling cancels the pending hide timer', (tester) async {
    final controller = LibraryScrollPositionController();
    controller.updateLayout(
      constraints: _constraints(),
      loadedCount: 60,
      totalCount: 120,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [LibraryPositionOverlay(controller: controller)],
          ),
        ),
      ),
    );

    controller.onScrollStart();
    controller.onScrollEnd();
    await tester.pump(const Duration(milliseconds: 500));
    controller.onScrollUpdate();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_opacity(tester), 1);

    controller.onScrollEnd();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 180));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('unknown totals render only the visible range', (tester) async {
    final controller = LibraryScrollPositionController();
    controller.updateLayout(
      constraints: _constraints(),
      loadedCount: 60,
      totalCount: null,
    );
    controller.onScrollStart();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [LibraryPositionOverlay(controller: controller)],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('library-position-range')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library-position-total')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-position-percentage')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('shows remaining count for filtered totals', (tester) async {
    final controller = LibraryScrollPositionController();
    controller.updateLayout(
      constraints: _constraints(),
      loadedCount: 60,
      totalCount: 137,
    );
    controller.onScrollStart();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              LibraryPositionOverlay(
                controller: controller,
                statistics: const LibraryResultStatistics(
                  state: LibraryBrowseState(mediaType: LibraryMediaType.movie),
                  loadedCount: 60,
                  totalCount: 137,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('筛选结果还剩 131 项'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.byKey(const ValueKey('library-position-overlay')),
    )
    .opacity;

SliverConstraints _constraints() => const SliverConstraints(
  axisDirection: AxisDirection.down,
  growthDirection: GrowthDirection.forward,
  userScrollDirection: ScrollDirection.idle,
  scrollOffset: 0,
  precedingScrollExtent: 0,
  overlap: 0,
  remainingPaintExtent: 500,
  crossAxisExtent: 520,
  crossAxisDirection: AxisDirection.right,
  viewportMainAxisExtent: 500,
  remainingCacheExtent: 500,
  cacheOrigin: 0,
);
