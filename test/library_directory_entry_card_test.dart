import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/widgets/library_directory_entry_card.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in const [
    ('Folder', '目录', Icons.folder_outlined),
    ('CollectionFolder', '目录', Icons.folder_outlined),
    ('PhotoAlbum', '相册', Icons.photo_album_outlined),
    ('Photo', '图片', Icons.image_outlined),
    ('Movie', '2024', Icons.movie_outlined),
    ('Series', '7 集未播放', Icons.tv_outlined),
    ('Episode', 'S02E03', Icons.play_circle_outline),
    ('Video', '2024', Icons.videocam_outlined),
  ]) {
    testWidgets('${entry.$1} card has typed icon and subtitle', (tester) async {
      final item = _item(entry.$1);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 280,
            height: 190,
            child: LibraryDirectoryEntryCard(
              item: item,
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

  testWidgets('directory artwork uses dark cover and contain foreground', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 280,
          height: 190,
          child: LibraryDirectoryEntryCard(
            item: _item('Movie'),
            imageRequest: _image,
            onTap: () {},
          ),
        ),
      ),
    );

    final images = tester
        .widgetList<EmbyImage>(find.byType(EmbyImage))
        .toList();
    expect(images, hasLength(2));
    expect(images.map((image) => image.fit), [BoxFit.cover, BoxFit.contain]);
  });

  testWidgets('card semantics distinguish directory and media actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final entry in const [
      ('Folder', '打开目录：Folder'),
      ('PhotoAlbum', '打开目录：PhotoAlbum'),
      ('Photo', '查看图片：Photo'),
      ('Movie', '查看媒体：Movie'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 280,
            height: 190,
            child: LibraryDirectoryEntryCard(
              item: _item(entry.$1),
              imageRequest: null,
              onTap: () {},
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel(entry.$2), findsOneWidget);
    }
    semantics.dispose();
  });
}

EmbyItem _item(String type) => EmbyItem(
  id: type,
  name: type,
  type: type,
  productionYear: 2024,
  parentIndexNumber: 2,
  indexNumber: 3,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: EmbyUserData(unplayedItemCount: type == 'Series' ? 7 : 0),
);

final _image = EmbyImageRequest(
  uri: Uri.parse('https://example.test/image.jpg'),
  headers: const {},
  cacheKey: 'directory-image',
  decodeWidth: 512,
  decodeHeight: 768,
);
