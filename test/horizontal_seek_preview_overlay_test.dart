import 'package:emby_my_client/ui/widgets/horizontal_seek_preview_overlay.dart';
import 'package:emby_my_client/ui/widgets/trickplay_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'time fallback exposes target, offset, and a read-only timeline',
    (tester) async {
      _setView(tester, const Size(393, 852));

      await tester.pumpWidget(
        _overlayApp(
          startPosition: const Duration(minutes: 2),
          targetPosition: const Duration(minutes: 2, seconds: 30),
          duration: const Duration(minutes: 10),
          previewUnavailable: true,
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
      expect(
        find.byKey(const ValueKey('horizontal-seek-preview-unavailable')),
        findsOneWidget,
      );
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

  testWidgets('off mode collapses the image area', (tester) async {
    _setView(tester, const Size(568, 320));

    await tester.pumpWidget(
      _overlayApp(
        targetPosition: const Duration(minutes: 2),
        duration: const Duration(minutes: 10),
        previewDisabled: true,
        preview: const ColoredBox(
          key: ValueKey('fake-preview'),
          color: Colors.blueGrey,
        ),
      ),
    );

    expect(find.text('暂无可用画面'), findsNothing);
    expect(
      find.byKey(const ValueKey('horizontal-seek-preview-image')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('horizontal-seek-preview-unavailable')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);

    final card = tester.getRect(
      find.byKey(const ValueKey('horizontal-seek-preview-overlay')),
    );
    final timeline = tester.getRect(
      find.byKey(const ValueKey('horizontal-seek-preview-timeline')),
    );
    expect(card.height, lessThan(124));
    expect(card.bottom, lessThanOrEqualTo(timeline.top));
  });

  testWidgets(
    'preview card stays above the timeline and inside SafeArea across landscape sizes and text scales',
    (tester) async {
      _setView(tester, const Size(568, 320));
      const viewports = [
        ('iPhone small landscape', Size(568, 320)),
        ('iPhone landscape', Size(844, 390)),
        ('iPad landscape', Size(1194, 834)),
      ];
      const textScales = [1.0, 1.3, 2.0];
      const positions = [
        Duration.zero,
        Duration(minutes: 5),
        Duration(minutes: 9, seconds: 59),
      ];

      for (final viewport in viewports) {
        tester.view.physicalSize = viewport.$2;
        for (final textScale in textScales) {
          for (final targetPosition in positions) {
            await tester.pumpWidget(
              _overlayApp(
                startPosition: const Duration(minutes: 2),
                targetPosition: targetPosition,
                duration: const Duration(minutes: 10),
                textScale: textScale,
                preview: const ColoredBox(
                  key: ValueKey('fake-preview'),
                  color: Colors.blueGrey,
                ),
                previewUnavailable: false,
              ),
            );
            await tester.pump();

            final card = tester.getRect(
              find.byKey(const ValueKey('horizontal-seek-preview-overlay')),
            );
            final timeline = tester.getRect(
              find.byKey(const ValueKey('horizontal-seek-preview-timeline')),
            );
            expect(
              card.left,
              greaterThanOrEqualTo(12),
              reason: '$viewport textScale=$textScale target=$targetPosition',
            );
            expect(
              card.right,
              lessThanOrEqualTo(viewport.$2.width - 12),
              reason: '$viewport textScale=$textScale target=$targetPosition',
            );
            expect(
              card.bottom,
              lessThanOrEqualTo(timeline.top),
              reason: '$viewport textScale=$textScale target=$targetPosition',
            );
            expect(
              tester.getRect(find.byKey(const ValueKey('fake-preview'))).bottom,
              lessThanOrEqualTo(timeline.top),
              reason: '$viewport textScale=$textScale target=$targetPosition',
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '$viewport textScale=$textScale target=$targetPosition',
            );
          }
        }
      }
    },
  );

  testWidgets('Trickplay image changes use gapless presentation', (
    tester,
  ) async {
    _setView(tester, const Size(568, 320));

    Widget buildPreview(ImageProvider image) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            child: TrickplayPreview(
              image: image,
              thumbnailWidth: 320,
              thumbnailHeight: 180,
              columns: 5,
              rows: 5,
              column: 0,
              row: 0,
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildPreview(const AssetImage('first-sheet.jpg')));
    final firstState = tester.state<State>(find.byType(Image));
    expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);

    await tester.pumpWidget(buildPreview(const AssetImage('second-sheet.jpg')));
    expect(tester.state<State>(find.byType(Image)), same(firstState));
    expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
    expect(tester.takeException(), isNull);
  });
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _overlayApp({
  Duration startPosition = Duration.zero,
  required Duration targetPosition,
  required Duration duration,
  Widget? preview,
  bool previewDisabled = false,
  bool previewUnavailable = false,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
      viewPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: HorizontalSeekPreviewOverlay(
            startPosition: startPosition,
            targetPosition: targetPosition,
            duration: duration,
            buffer: const Duration(minutes: 5),
            cacheRuntimeMode: null,
            cacheSnapshot: null,
            previewDisabled: previewDisabled,
            previewUnavailable: previewUnavailable,
            preview: preview,
          ),
        ),
      ],
    ),
  ),
);
