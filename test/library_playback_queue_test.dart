import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_local_media_scan_cache.dart';
import 'package:emby_my_client/library/library_playback_queue.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads every later raw page and excludes non-playable items', () async {
    final api = _api();
    final starts = <int>[];
    final queue = await LazyLibraryPlaybackQueue.prepare(
      api: api,
      query: _query,
      initialItems: [_video('video-0'), _photo('photo-1')],
      initialRawCursor: 2,
      totalCount: 5,
      pageSize: 2,
      loadPage: ({required startIndex, required limit}) async {
        starts.add(startIndex);
        return switch (startIndex) {
          2 => EmbyItemPage(
            items: [_photo('photo-2'), _video('video-3')],
            rawItemCount: 2,
            totalRecordCount: 5,
          ),
          4 => EmbyItemPage(
            items: [_video('video-4')],
            rawItemCount: 1,
            totalRecordCount: 5,
          ),
          _ => const EmbyItemPage(items: [], rawItemCount: 0),
        };
      },
    );

    expect(queue, isNotNull);
    final first = queue!.items.single;
    final second = await queue.next(first);
    final third = await queue.next(second!);
    expect(await queue.next(third!), isNull);
    expect(queue.items.map((item) => item.id), [
      'video-0',
      'video-3',
      'video-4',
    ]);
    expect(starts, [2, 4]);
    expect(queue.rawCursor, 5);
    expect(queue.totalCount, 5);
    expect(queue.query.fingerprint, 'test-fingerprint');
    await api.dispose();
  });

  test(
    'shuffle starts outside the initially loaded raw page and stays lazy',
    () async {
      final api = _api();
      final starts = <int>[];
      final queue = await LazyLibraryPlaybackQueue.prepare(
        api: api,
        query: _query,
        initialItems: [_video('video-0'), _video('video-1')],
        initialRawCursor: 2,
        totalCount: 6,
        pageSize: 2,
        shuffle: true,
        random: _ZeroRandom(),
        loadPage: ({required startIndex, required limit}) async {
          starts.add(startIndex);
          return EmbyItemPage(
            items: [
              _video('video-$startIndex'),
              _video('video-${startIndex + 1}'),
            ],
            rawItemCount: 2,
            totalRecordCount: 6,
          );
        },
      );

      expect(queue, isNotNull);
      expect(starts, [2]);
      expect(queue!.items.map((item) => item.id), ['video-3', 'video-2']);
      var current = queue.items.first;
      while (queue.canPotentiallyAdvance(current)) {
        final next = await queue.next(current);
        if (next == null) break;
        current = next;
      }
      expect(queue.items.map((item) => item.id).toSet(), {
        for (var index = 0; index < 6; index++) 'video-$index',
      });
      expect(starts, [2, 4]);
      expect(queue.rawCursor, 6);
      await api.dispose();
    },
  );

  test('deduplicates IDs across raw pages and never queues photos', () async {
    final api = _api();
    final queue = await LazyLibraryPlaybackQueue.prepare(
      api: api,
      query: _query,
      initialItems: [_video('same')],
      initialRawCursor: 1,
      totalCount: 4,
      pageSize: 3,
      loadPage: ({required startIndex, required limit}) async => EmbyItemPage(
        items: [_video('same'), _photo('photo'), _video('next')],
        rawItemCount: 3,
        totalRecordCount: 4,
      ),
    );

    final next = await queue!.next(queue.items.single);
    expect(next?.id, 'next');
    expect(queue.items.map((item) => item.id), ['same', 'next']);
    await api.dispose();
  });

  test('preparation cancellation is observed after an active page', () async {
    final api = _api();
    final response = Completer<EmbyItemPage>();
    final cancellation = LibraryPlaybackCancellation();
    final preparing = LazyLibraryPlaybackQueue.prepare(
      api: api,
      query: _query,
      initialItems: const [],
      initialRawCursor: 0,
      totalCount: null,
      shuffle: true,
      cancellation: cancellation,
      loadPage: ({required startIndex, required limit}) => response.future,
    );
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    response.complete(
      EmbyItemPage(
        items: [_video('late')],
        rawItemCount: 1,
        totalRecordCount: 1,
      ),
    );

    await expectLater(preparing, throwsA(isA<LibraryPlaybackCancelled>()));
    await api.dispose();
  });

  test(
    'preparation page errors propagate without substituting a partial queue',
    () async {
      final api = _api();
      final preparing = LazyLibraryPlaybackQueue.prepare(
        api: api,
        query: _query,
        initialItems: const [],
        initialRawCursor: 0,
        totalCount: 1,
        loadPage: ({required startIndex, required limit}) =>
            Future<EmbyItemPage>.error(StateError('private queue failure')),
      );

      await expectLater(preparing, throwsStateError);
      await api.dispose();
    },
  );

  test('complete-result availability enforces local scan exactness', () {
    const mediaState = LibraryBrowseState();
    expect(
      canPlayCompleteLibraryResult(
        state: mediaState,
        profile: LibraryContentProfile.mixed,
        playableLoadedCount: 0,
        hasMore: true,
      ),
      isTrue,
    );
    expect(
      canPlayCompleteLibraryResult(
        state: mediaState.copyWith(mediaType: LibraryMediaType.photo),
        profile: LibraryContentProfile.mixed,
        playableLoadedCount: 10,
        hasMore: false,
      ),
      isFalse,
    );

    const scanning = LibraryLocalScanSnapshot(
      status: LibraryScanStatus.scanning,
      rawCursor: 60,
      scannedRawCount: 60,
      sourceTotalCount: 120,
      strmCount: 10,
      regularCount: 49,
      unknownCount: 1,
      complete: false,
      dirty: false,
      safeError: null,
    );
    const completeWithUnknown = LibraryLocalScanSnapshot(
      status: LibraryScanStatus.complete,
      rawCursor: 120,
      scannedRawCount: 120,
      sourceTotalCount: 120,
      strmCount: 20,
      regularCount: 99,
      unknownCount: 1,
      complete: true,
      dirty: false,
      safeError: null,
    );
    const dirty = LibraryLocalScanSnapshot(
      status: LibraryScanStatus.complete,
      rawCursor: 120,
      scannedRawCount: 120,
      sourceTotalCount: 120,
      strmCount: 20,
      regularCount: 100,
      unknownCount: 0,
      complete: true,
      dirty: true,
      safeError: null,
    );
    final strm = mediaState.copyWith(localFilter: LibraryLocalMediaFilter.strm);
    final regular = mediaState.copyWith(
      localFilter: LibraryLocalMediaFilter.regular,
    );

    expect(
      canPlayCompleteLibraryResult(
        state: strm,
        profile: LibraryContentProfile.mixed,
        playableLoadedCount: 10,
        hasMore: false,
        localScan: scanning,
      ),
      isFalse,
    );
    expect(
      canPlayCompleteLibraryResult(
        state: strm,
        profile: LibraryContentProfile.mixed,
        playableLoadedCount: 20,
        hasMore: false,
        localScan: completeWithUnknown,
      ),
      isTrue,
    );
    expect(
      canPlayCompleteLibraryResult(
        state: regular,
        profile: LibraryContentProfile.mixed,
        playableLoadedCount: 99,
        hasMore: false,
        localScan: completeWithUnknown,
      ),
      isFalse,
    );
    expect(
      canPlayCompleteLibraryResult(
        state: strm,
        profile: LibraryContentProfile.mixed,
        playableLoadedCount: 20,
        hasMore: false,
        localScan: dirty,
      ),
      isFalse,
    );
  });
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _query = LibraryPlaybackQuerySnapshot(
  libraryId: 'library-1',
  state: LibraryBrowseState(),
  profile: LibraryContentProfile.mixed,
  fingerprint: 'test-fingerprint',
);

EmbyApi _api() => EmbyApi(_session, dio: Dio());

EmbyItem _video(String id) => EmbyItem(
  id: id,
  name: id,
  type: 'Video',
  mediaType: 'Video',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

EmbyItem _photo(String id) => EmbyItem(
  id: id,
  name: id,
  type: 'Photo',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

class _ZeroRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}
