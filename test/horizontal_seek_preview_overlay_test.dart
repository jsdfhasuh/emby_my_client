import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emby_my_client/ui/widgets/horizontal_seek_preview_overlay.dart';

void main() {
  testWidgets(
    'time fallback exposes target, offset, and a read-only timeline',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: HorizontalSeekPreviewOverlay(
                    startPosition: Duration(minutes: 2),
                    targetPosition: Duration(minutes: 2, seconds: 30),
                    duration: Duration(minutes: 10),
                    buffer: Duration(minutes: 5),
                    cacheRuntimeMode: null,
                    cacheSnapshot: null,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('horizontal-seek-preview-overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('horizontal-seek-target-time')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('horizontal-seek-offset-label')),
        findsOneWidget,
      );
      expect(find.text('前进 30 秒'), findsOneWidget);
      expect(find.text('02:30 / 10:00'), findsOneWidget);
      expect(find.text('暂无可用画面'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);

      final timeline = find.byKey(
        const ValueKey('horizontal-seek-preview-timeline'),
      );
      final slider = tester.widget<Slider>(
        find.descendant(of: timeline, matching: find.byType(Slider)),
      );
      expect(slider.onChangeStart, isNull);
      expect(slider.onChanged, isNull);
      expect(slider.onChangeEnd, isNull);
    },
  );

  testWidgets('preview stays above the timeline and the card stays in bounds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: HorizontalSeekPreviewOverlay(
                  startPosition: Duration.zero,
                  targetPosition: const Duration(minutes: 9, seconds: 59),
                  duration: const Duration(minutes: 10),
                  buffer: const Duration(minutes: 10),
                  cacheRuntimeMode: null,
                  cacheSnapshot: null,
                  preview: const ColoredBox(
                    key: ValueKey('fake-preview'),
                    color: Colors.blueGrey,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final card = tester.getRect(
      find.byKey(const ValueKey('horizontal-seek-preview-overlay')),
    );
    final timeline = tester.getRect(
      find.byKey(const ValueKey('horizontal-seek-preview-timeline')),
    );
    final parent = tester.getRect(find.byType(HorizontalSeekPreviewOverlay));
    final preview = tester.getRect(find.byKey(const ValueKey('fake-preview')));

    expect(card.left, greaterThanOrEqualTo(parent.left));
    expect(card.right, lessThanOrEqualTo(parent.right));
    expect(preview.bottom, lessThanOrEqualTo(timeline.top));
    expect(card.bottom, lessThanOrEqualTo(timeline.top));
  });
}
