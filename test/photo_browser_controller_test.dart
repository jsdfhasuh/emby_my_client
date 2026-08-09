import 'dart:async';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/library/library_raw_page_cursor.dart';
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

  test('known-total empty page stays retryable at the same cursor', () async {
    final starts = <int>[];
    var cursorOneAttempts = 0;
    final controller = PhotoBrowserController(
      pageSize: 2,
      loadPage: ({required startIndex, required limit}) async {
        starts.add(startIndex);
        if (startIndex == 0) {
          return EmbyItemPage(
            items: [_item('photo-1', 'Photo')],
            rawItemCount: 1,
            totalRecordCount: 2,
          );
        }
        cursorOneAttempts++;
        return cursorOneAttempts == 1
            ? const EmbyItemPage(
                items: [],
                rawItemCount: 0,
                totalRecordCount: 2,
              )
            : EmbyItemPage(
                items: [_item('photo-2', 'Photo')],
                rawItemCount: 1,
                totalRecordCount: 2,
              );
      },
    );

    await controller.loadMore();
    await controller.loadMore();
    expect(controller.error, isA<LibraryPaginationStalled>());
    expect(controller.nextStartIndex, 1);
    expect(controller.hasMore, isTrue);

    await controller.loadMore();
    expect(starts, [0, 1, 1]);
    expect(controller.error, isNull);
    expect(controller.items.map((item) => item.id), ['photo-1', 'photo-2']);
    expect(controller.hasMore, isFalse);
    controller.dispose();
  });

  test('reported total changes mark photo browser statistics dirty', () async {
    final controller = PhotoBrowserController(
      pageSize: 1,
      loadPage: ({required startIndex, required limit}) async => EmbyItemPage(
        items: [_item('photo-$startIndex', 'Photo')],
        rawItemCount: 1,
        totalRecordCount: startIndex == 0 ? 2 : 3,
      ),
    );

    await controller.loadMore();
    await controller.loadMore();

    expect(controller.totalCount, 3);
    expect(controller.totalDirty, isTrue);
    expect(controller.hasMore, isTrue);
    controller.dispose();
  });

  test('total below loaded count emits counts without item data', () async {
    final lines = <String>[];
    DiagnosticLog.instance.setTestSink(lines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final controller = PhotoBrowserController(
      loadPage: ({required startIndex, required limit}) async => EmbyItemPage(
        items: [
          _item('private-photo-a', 'Photo'),
          _item('private-photo-b', 'Photo'),
        ],
        rawItemCount: 2,
        totalRecordCount: 1,
      ),
    );

    await controller.loadMore();

    final warning = lines.singleWhere(
      (line) => line.contains('Photo directory total below loaded count'),
    );
    expect(warning, contains('total=1 loaded=2'));
    expect(warning, isNot(contains('private-photo')));
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
