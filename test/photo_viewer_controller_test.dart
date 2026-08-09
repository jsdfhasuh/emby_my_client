import 'dart:async';

import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/images/photo_prefetcher.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_sequence_source.dart';
import 'package:emby_my_client/photos/photo_viewer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'starts at requested item and prefetches a bounded neighbor window',
    () async {
      final loaded = <String>[];
      final controller = PhotoViewerController(
        source: _source(
          initialItems: [
            _item('folder', 'Folder'),
            _item('photo-1', 'Photo'),
            _item('photo-2', 'Photo'),
            _item('photo-3', 'Photo'),
            _item('photo-4', 'Photo'),
            _item('photo-5', 'Photo'),
            _item('photo-6', 'Photo'),
          ],
          initialItemId: 'photo-3',
          initialRawCursor: 7,
          initialTotalCount: 7,
          initialHasMore: false,
          loadPage: _emptyLoader,
        ),
        imageRequestFor: _request,
        prefetcher: PhotoPrefetcher(
          load: (request) async => loaded.add(request.cacheKey),
        ),
      );

      expect(controller.currentIndex, 2);
      expect(controller.positionLabel, '3 / 6');
      expect(controller.photos.every((item) => item.isPhoto), isTrue);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        loaded,
        containsAll(<String>[
          'photo-1',
          'photo-2',
          'photo-3',
          'photo-4',
          'photo-5',
        ]),
      );
      controller.dispose();
    },
  );

  test(
    'loads the next page immediately when the initial photo is near the end',
    () async {
      final starts = <int>[];
      final requestStarted = Completer<void>();
      final response = Completer<EmbyItemPage>();
      final controller = PhotoViewerController(
        source: _source(
          initialItems: [_item('folder', 'Folder'), _item('photo-1', 'Photo')],
          initialItemId: 'photo-1',
          initialRawCursor: 2,
          initialTotalCount: null,
          initialHasMore: true,
          loadPage: ({required startIndex, required limit}) {
            starts.add(startIndex);
            if (!requestStarted.isCompleted) requestStarted.complete();
            return response.future;
          },
        ),
        pageSize: 2,
        loadAheadThreshold: 8,
        imageRequestFor: _request,
        prefetcher: PhotoPrefetcher(load: (_) async {}),
      );

      await requestStarted.future;
      response.complete(
        EmbyItemPage(
          items: [_item('album', 'PhotoAlbum'), _item('photo-2', 'Photo')],
          rawItemCount: 2,
        ),
      );
      while (controller.isLoadingMore) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(starts, [2]);
      expect(controller.photos.map((item) => item.id), ['photo-1', 'photo-2']);
      expect(controller.positionLabel, '1 / 2+');
      controller.dispose();
    },
  );

  test(
    'continues from the source raw cursor and honors the source total',
    () async {
      final starts = <int>[];
      final controller = PhotoViewerController(
        source: _source(
          initialItems: [_item('photo-1', 'Photo')],
          initialItemId: 'photo-1',
          initialRawCursor: 60,
          initialTotalCount: 62,
          initialHasMore: true,
          loadPage: ({required startIndex, required limit}) async {
            starts.add(startIndex);
            return EmbyItemPage(
              items: [_item('photo-2', 'Photo')],
              rawItemCount: 2,
              totalRecordCount: 62,
            );
          },
        ),
        imageRequestFor: _request,
        prefetcher: PhotoPrefetcher(load: (_) async {}),
      );

      while (controller.isLoadingMore) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(starts, [60]);
      expect(controller.nextStartIndex, 62);
      expect(controller.totalCount, 62);
      expect(controller.queryFingerprint, 'test-query');
      expect(controller.photos.map((item) => item.id), ['photo-1', 'photo-2']);
      expect(controller.hasMore, isFalse);
      controller.dispose();
    },
  );

  test('prefetcher enforces concurrency and drops stale queued work', () async {
    final started = <String>[];
    final completers = <String, Completer<void>>{};
    final prefetcher = PhotoPrefetcher(
      maxConcurrent: 2,
      load: (request) {
        started.add(request.cacheKey);
        return (completers[request.cacheKey] ??= Completer<void>()).future;
      },
    );

    prefetcher.schedule([
      _request(_item('1', 'Photo'))!,
      _request(_item('2', 'Photo'))!,
      _request(_item('3', 'Photo'))!,
    ]);
    expect(started, ['1', '2']);
    expect(prefetcher.activeCount, 2);

    prefetcher.schedule([
      _request(_item('4', 'Photo'))!,
      _request(_item('5', 'Photo'))!,
    ]);
    completers['1']!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, ['1', '2', '4']);
    expect(started, isNot(contains('3')));

    completers['2']!.complete();
    completers['4']!.complete();
    await Future<void>.delayed(Duration.zero);
    if (completers['5'] != null && !completers['5']!.isCompleted) {
      completers['5']!.complete();
    }
    prefetcher.dispose();
  });

  test('failed prefetches remain eligible for a later retry', () async {
    var attempts = 0;
    final prefetcher = PhotoPrefetcher(
      load: (_) async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
      },
    );
    final request = _request(_item('retry', 'Photo'))!;

    prefetcher.schedule([request]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);
    expect(prefetcher.completedCount, 0);

    prefetcher.schedule([request]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 2);
    expect(prefetcher.completedCount, 1);
    prefetcher.dispose();
  });
}

Future<EmbyItemPage> _emptyLoader({
  required int startIndex,
  required int limit,
}) async => const EmbyItemPage(items: [], totalRecordCount: 0);

DirectoryPhotoSource _source({
  required List<EmbyItem> initialItems,
  required String initialItemId,
  required int initialRawCursor,
  required int? initialTotalCount,
  required bool initialHasMore,
  required PhotoPageLoader loadPage,
}) => DirectoryPhotoSource(
  queryFingerprint: 'test-query',
  initialItems: initialItems,
  initialItemId: initialItemId,
  initialRawCursor: initialRawCursor,
  initialTotalCount: initialTotalCount,
  initialHasMore: initialHasMore,
  loadPage: loadPage,
);

EmbyImageRequest? _request(EmbyItem item) => EmbyImageRequest(
  uri: Uri.parse('https://example.test/${item.id}.jpg'),
  headers: const {},
  cacheKey: item.id,
  decodeWidth: 512,
  decodeHeight: 512,
);

EmbyItem _item(String id, String type) => EmbyItem(
  id: id,
  name: id,
  type: type,
  imageTags: const {'Primary': 'tag'},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);
