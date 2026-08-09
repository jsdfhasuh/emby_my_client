import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_browser_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paginates, filters unsupported types and deduplicates IDs', () async {
    final calls = <int>[];
    final controller = PhotoBrowserController(
      pageSize: 3,
      loadPage: ({required startIndex, required limit}) async {
        calls.add(startIndex);
        if (startIndex == 0) {
          return EmbyItemPage(
            items: [
              _item('folder-1', 'Folder'),
              _item('photo-1', 'Photo'),
              _item('movie-1', 'Movie'),
            ],
            rawItemCount: 3,
            totalRecordCount: 5,
          );
        }
        return EmbyItemPage(
          items: [_item('photo-1', 'Photo'), _item('album-1', 'PhotoAlbum')],
          rawItemCount: 2,
          totalRecordCount: 5,
        );
      },
    );

    await controller.loadMore();
    expect(controller.items.map((item) => item.id), ['folder-1', 'photo-1']);
    expect(controller.hasMore, isTrue);

    await controller.loadMore();
    expect(controller.items.map((item) => item.id), [
      'folder-1',
      'photo-1',
      'album-1',
    ]);
    expect(controller.hasMore, isFalse);
    expect(calls, [0, 3]);
    controller.dispose();
  });

  test('refresh discards a stale earlier response', () async {
    final first = Completer<EmbyItemPage>();
    final second = Completer<EmbyItemPage>();
    var call = 0;
    final controller = PhotoBrowserController(
      loadPage: ({required startIndex, required limit}) {
        call++;
        return call == 1 ? first.future : second.future;
      },
    );

    final oldLoad = controller.loadMore();
    final refresh = controller.refresh();
    second.complete(EmbyItemPage(items: [_item('fresh', 'Photo')]));
    await refresh;
    first.complete(EmbyItemPage(items: [_item('stale', 'Photo')]));
    await oldLoad;

    expect(controller.items.map((item) => item.id), ['fresh']);
    expect(controller.isLoading, isFalse);
    controller.dispose();
  });

  test('retains retryable error and recovers', () async {
    var fail = true;
    final controller = PhotoBrowserController(
      loadPage: ({required startIndex, required limit}) async {
        if (fail) throw StateError('offline');
        return EmbyItemPage(items: [_item('photo-1', 'Photo')]);
      },
    );

    await controller.loadMore();
    expect(controller.error, isA<StateError>());
    expect(controller.items, isEmpty);

    fail = false;
    await controller.loadMore();
    expect(controller.error, isNull);
    expect(controller.items.single.id, 'photo-1');
    controller.dispose();
  });

  test(
    'advances by raw count after invalid response rows are removed',
    () async {
      final starts = <int>[];
      final controller = PhotoBrowserController(
        pageSize: 3,
        loadPage: ({required startIndex, required limit}) async {
          starts.add(startIndex);
          return startIndex == 0
              ? EmbyItemPage(
                  items: [_item('photo-1', 'Photo')],
                  rawItemCount: 3,
                  totalRecordCount: 4,
                )
              : EmbyItemPage(
                  items: [_item('photo-2', 'Photo')],
                  rawItemCount: 1,
                  totalRecordCount: 4,
                );
        },
      );

      await controller.loadMore();
      await controller.loadMore();

      expect(starts, [0, 3]);
      expect(controller.nextStartIndex, 4);
      expect(controller.items.map((item) => item.id), ['photo-1', 'photo-2']);
      expect(controller.hasMore, isFalse);
      controller.dispose();
    },
  );
}

EmbyItem _item(String id, String type) => EmbyItem(
  id: id,
  name: id,
  type: type,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);
