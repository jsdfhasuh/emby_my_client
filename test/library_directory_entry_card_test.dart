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
      ('Photo', '查看图片：Photo，未查看'),
      ('Movie', '查看媒体：Movie，未观看'),
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

  for (final entry in const [
    (EmbyUserData(), '未观看', null),
    (EmbyUserData(isPlayed: true), '已观看', null),
    (EmbyUserData(playedPercentage: 30), '观看中 30%', 0.3),
    (EmbyUserData(playbackPositionTicks: 30), '观看中', null),
  ]) {
    testWidgets('directory video shows ${entry.$2}', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 220,
              height: 160,
              child: LibraryDirectoryEntryCard(
                item: _item('Video', userData: entry.$1),
                imageRequest: null,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text(entry.$2), findsOneWidget);
      expect(find.bySemanticsLabel('查看媒体：Video，${entry.$2}'), findsOneWidget);
      if (entry.$3 case final progress?) {
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          progress,
        );
      } else {
        expect(find.byType(LinearProgressIndicator), findsNothing);
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('directory containers have no leaf watch status or progress', (
    tester,
  ) async {
    for (final type in ['Folder', 'PhotoAlbum', 'Series']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 220,
              height: 160,
              child: LibraryDirectoryEntryCard(
                item: _item(
                  type,
                  userData: const EmbyUserData(
                    isPlayed: true,
                    playedPercentage: 30,
                  ),
                ),
                imageRequest: null,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('library-watch-status')), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    }
  });

  testWidgets(
    'compact directory status and caption do not overlap at large text',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Center(
            child: SizedBox(
              width: 170,
              height: 136,
              child: LibraryDirectoryEntryCard(
                item: _item(
                  'Video',
                  name: 'A long family recording title',
                  userData: const EmbyUserData(
                    isFavorite: true,
                    playedPercentage: 35,
                  ),
                ),
                imageRequest: null,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      final badge = tester.getRect(
        find.byKey(const ValueKey('library-watch-status')),
      );
      final title = tester.getRect(find.text('A long family recording title'));
      final favorite = tester.getRect(find.byIcon(Icons.favorite));
      expect(badge.overlaps(title), isFalse);
      expect(badge.overlaps(favorite), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

EmbyItem _item(String type, {String? name, EmbyUserData? userData}) => EmbyItem(
  id: type,
  name: name ?? type,
  type: type,
  productionYear: 2024,
  parentIndexNumber: 2,
  indexNumber: 3,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData:
      userData ?? EmbyUserData(unplayedItemCount: type == 'Series' ? 7 : 0),
);

final _image = EmbyImageRequest(
  uri: Uri.parse('https://example.test/image.jpg'),
  headers: const {},
  cacheKey: 'directory-image',
  decodeWidth: 512,
  decodeHeight: 768,
);
