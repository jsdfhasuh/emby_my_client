import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_browser_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paginates, filters unsupported types and deduplicates IDs', () async {
    final calls = <int>[];
    final controller = PhotoBrowserController(
      parentId: 'root',
      pageSize: 3,
      loadPage: ({required parentId, startIndex = 0, limit = 60}) async {
        calls.add(startIndex);
        if (startIndex == 0) {
          return [
            _item('folder-1', 'Folder'),
            _item('photo-1', 'Photo'),
            _item('movie-1', 'Movie'),
          ];
        }
        return [_item('photo-1', 'Photo'), _item('album-1', 'PhotoAlbum')];
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
    final first = Completer<List<EmbyItem>>();
    final second = Completer<List<EmbyItem>>();
    var call = 0;
    final controller = PhotoBrowserController(
      parentId: 'root',
      loadPage: ({required parentId, startIndex = 0, limit = 60}) {
        call++;
        return call == 1 ? first.future : second.future;
      },
    );

    final oldLoad = controller.loadMore();
    final refresh = controller.refresh();
    second.complete([_item('fresh', 'Photo')]);
    await refresh;
    first.complete([_item('stale', 'Photo')]);
    await oldLoad;

    expect(controller.items.map((item) => item.id), ['fresh']);
    expect(controller.isLoading, isFalse);
    controller.dispose();
  });

  test('retains retryable error and recovers', () async {
    var fail = true;
    final controller = PhotoBrowserController(
      parentId: 'root',
      loadPage: ({required parentId, startIndex = 0, limit = 60}) async {
        if (fail) throw StateError('offline');
        return [_item('photo-1', 'Photo')];
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
