import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';

void main() {
  test('hero height responds to iPad and narrow viewports', () {
    expect(
      detailHeroHeightForViewport(const Size(1024, 768)),
      closeTo(368.64, 0.001),
    );
    expect(detailHeroHeightForViewport(const Size(768, 1024)), 480);
    expect(detailHeroHeightForViewport(const Size(1366, 1024)), 480);
    expect(detailHeroHeightForViewport(const Size(390, 844)), 300);
  });

  testWidgets('backdrop hero keeps a complete foreground image', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 369,
            child: DetailHeroArtwork(
              backdrop: _request('backdrop'),
              primary: _request('primary'),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('item-detail-hero')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('item-detail-backdrop-underlay')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('item-detail-backdrop-foreground')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('item-detail-primary-fallback')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary fallback uses a complete foreground image', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(768, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 480,
            child: DetailHeroArtwork(
              backdrop: null,
              primary: _request('primary'),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('item-detail-primary-fallback')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('item-detail-backdrop-foreground')),
      findsNothing,
    );
    expect(
      tester.getSize(find.byType(DetailHeroArtwork)),
      const Size(768, 480),
    );
    expect(tester.takeException(), isNull);
  });
}

EmbyImageRequest _request(String tag) => EmbyImageRequest(
  uri: Uri.parse('https://example.invalid/images/$tag.jpg'),
  headers: const {},
  cacheKey: tag,
  decodeWidth: 1200,
  decodeHeight: 800,
);
