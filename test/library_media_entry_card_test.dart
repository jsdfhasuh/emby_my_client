import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/widgets/library_mixed_entry_card.dart';
import 'package:emby_my_client/ui/widgets/library_photo_card.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('photo card has photo semantics and no playback state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 220,
          child: LibraryPhotoCard(
            item: _item('Photo', userData: const EmbyUserData(isPlayed: true)),
            imageRequest: null,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('查看图片：Photo'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsWidgets);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('photo artwork preserves the complete foreground', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 220,
          child: LibraryPhotoCard(
            item: _item('Photo'),
            imageRequest: _image,
            onTap: () {},
          ),
        ),
      ),
    );

    final images = tester.widgetList<EmbyImage>(find.byType(EmbyImage));
    expect(images.map((image) => image.fit), [BoxFit.cover, BoxFit.contain]);
  });

  for (final entry in const [
    ('Folder', '目录', Icons.folder_outlined),
    ('CollectionFolder', '目录', Icons.folder_outlined),
    ('PhotoAlbum', '相册', Icons.photo_album_outlined),
    ('Photo', '图片', Icons.image_outlined),
    ('Movie', '2024', Icons.movie_outlined),
    ('Series', '4 集未播放', Icons.tv_outlined),
    ('Episode', 'S02E03', Icons.play_circle_outline),
    ('Video', '2024', Icons.videocam_outlined),
  ]) {
    testWidgets('mixed card distinguishes ${entry.$1}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 180,
            child: LibraryMixedEntryCard(
              item: _item(entry.$1),
              imageRequest: null,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text(entry.$2), findsOneWidget);
      expect(find.byIcon(entry.$3), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mixed artwork uses a dark cover and contained foreground', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 180,
          child: LibraryMixedEntryCard(
            item: _item('Video'),
            imageRequest: _image,
            onTap: () {},
          ),
        ),
      ),
    );

    final images = tester.widgetList<EmbyImage>(find.byType(EmbyImage));
    expect(images.map((image) => image.fit), [BoxFit.cover, BoxFit.contain]);
  });

  testWidgets('mixed card survives large text without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SizedBox(
          width: 280,
          height: 210,
          child: LibraryMixedEntryCard(
            item: _item(
              'Video',
              name: 'A deliberately long mixed-library video title',
            ),
            imageRequest: null,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}

EmbyItem _item(String type, {String? name, EmbyUserData? userData}) => EmbyItem(
  id: type,
  name: name ?? type,
  type: type,
  mediaType: switch (type) {
    'Movie' || 'Episode' || 'Video' => 'Video',
    'Photo' => 'Photo',
    _ => null,
  },
  productionYear: 2024,
  parentIndexNumber: 2,
  indexNumber: 3,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData:
      userData ?? EmbyUserData(unplayedItemCount: type == 'Series' ? 4 : 0),
);

final _image = EmbyImageRequest(
  uri: Uri.parse('https://example.test/library-image.jpg'),
  headers: const {},
  cacheKey: 'library-image',
  decodeWidth: 512,
  decodeHeight: 512,
);
