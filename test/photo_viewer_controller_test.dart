import 'dart:async';

import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/images/photo_prefetcher.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_viewer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'starts at requested item and prefetches a bounded neighbor window',
    () async {
      final loaded = <String>[];
      final controller = PhotoViewerController(
        parentId: 'root',
        initialDirectoryItems: [
          _item('folder', 'Folder'),
          _item('photo-1', 'Photo'),
          _item('photo-2', 'Photo'),
          _item('photo-3', 'Photo'),
          _item('photo-4', 'Photo'),
          _item('photo-5', 'Photo'),
          _item('photo-6', 'Photo'),
        ],
        initialItemId: 'photo-3',
        initialHasMore: false,
        loadPage: _emptyLoader,
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
      final response = Completer<List<EmbyItem>>();
      final controller = PhotoViewerController(
        parentId: 'root',
        initialDirectoryItems: [
          _item('folder', 'Folder'),
          _item('photo-1', 'Photo'),
        ],
        initialItemId: 'photo-1',
        initialHasMore: true,
        pageSize: 2,
        loadAheadThreshold: 8,
        loadPage: ({required parentId, startIndex = 0, limit = 60}) {
          starts.add(startIndex);
          if (!requestStarted.isCompleted) requestStarted.complete();
          return response.future;
        },
        imageRequestFor: _request,
        prefetcher: PhotoPrefetcher(load: (_) async {}),
      );

      await requestStarted.future;
      response.complete([
        _item('album', 'PhotoAlbum'),
        _item('photo-2', 'Photo'),
      ]);
      while (controller.isLoadingMore) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(starts, [2]);
      expect(controller.photos.map((item) => item.id), ['photo-1', 'photo-2']);
      expect(controller.positionLabel, '1 / 2+');
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

Future<List<EmbyItem>> _emptyLoader({
  required String parentId,
  int startIndex = 0,
  int limit = 60,
}) async => const [];

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
