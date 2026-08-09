import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_local_media_scan_cache.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classification is conservative and excludes non-candidates', () {
    expect(isLibraryLocalMediaCandidate(_item('photo', 'Photo')), isFalse);
    expect(
      classifyLibraryLocalMedia(_item('strm', 'Movie', path: 'item.strm')),
      LibraryLocalMediaKind.strm,
    );
    expect(
      classifyLibraryLocalMedia(_item('regular', 'Video', path: 'item.mp4')),
      LibraryLocalMediaKind.regular,
    );
    expect(
      classifyLibraryLocalMedia(_item('unknown', 'Episode')),
      LibraryLocalMediaKind.unknown,
    );
    expect(
      classifyLibraryLocalMedia(
        _item('invalid', 'Movie', path: 'invalid\npath'),
      ),
      LibraryLocalMediaKind.unknown,
    );
  });

  test('automatically scans 3768 raw rows without scrolling', () async {
    final fixture = [
      for (var index = 0; index < 3768; index++)
        index % 97 == 0
            ? _item('photo-$index', 'Photo')
            : index % 29 == 0
            ? _item('unknown-$index', 'Video')
            : index % 11 == 0
            ? _item('strm-$index', 'Movie', path: 'item-$index.strm')
            : _item('regular-$index', 'Video', path: 'item-$index.mp4'),
    ];
    final starts = <int>[];
    var notifications = 0;
    final harness = _harness();
    harness.service.addListener(() => notifications++);
    final key = _key(harness.scope, 'large-library');

    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) async {
          starts.add(startIndex);
          final end = (startIndex + limit).clamp(0, fixture.length);
          final items = startIndex >= fixture.length
              ? const <EmbyItem>[]
              : fixture.sublist(startIndex, end);
          return EmbyItemPage(
            items: items,
            rawItemCount: items.length,
            totalRecordCount: fixture.length,
          );
        },
      ),
    );

    final snapshot = await _waitFor(
      harness.service,
      key,
      (value) => value.complete,
    );
    expect(snapshot.rawCursor, 3768);
    expect(snapshot.scannedRawCount, 3768);
    expect(snapshot.sourceTotalCount, 3768);
    expect(snapshot.strmCount, greaterThan(0));
    expect(snapshot.regularCount, greaterThan(0));
    expect(snapshot.unknownCount, greaterThan(0));
    expect(
      snapshot.strmCount + snapshot.regularCount + snapshot.unknownCount,
      lessThan(3768),
    );
    expect(starts.length, 63);
    expect(notifications, lessThanOrEqualTo(starts.length + 2));
    expect(
      harness.service
          .itemsFor(key, LibraryLocalMediaFilter.strm)
          .every((item) => item.isStrm),
      isTrue,
    );
    await harness.dispose();
  });

  test(
    'retains matches and retries a failed page from the same cursor',
    () async {
      final starts = <int>[];
      final delays = <Duration>[];
      var fail = true;
      final harness = _harness(delay: (duration) async => delays.add(duration));
      final key = _key(harness.scope, 'retry-library');
      harness.service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) async {
            starts.add(startIndex);
            if (startIndex == 0) {
              return EmbyItemPage(
                items: [
                  _item('strm', 'Movie', path: 'one.strm'),
                  _item('regular', 'Video', path: 'two.mp4'),
                ],
                rawItemCount: 2,
                totalRecordCount: 4,
              );
            }
            if (fail) throw StateError('private fixture failure');
            return EmbyItemPage(
              items: [
                _item('regular-2', 'Video', path: 'three.mp4'),
                _item('regular-3', 'Episode', path: 'four.mp4'),
              ],
              rawItemCount: 2,
              totalRecordCount: 4,
            );
          },
        ),
      );

      final paused = await _waitFor(
        harness.service,
        key,
        (value) => value.safeError == LibraryScanErrorKind.requestFailed,
      );
      expect(paused.rawCursor, 2);
      expect(paused.strmCount, 1);
      expect(paused.regularCount, 1);
      expect(delays, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]);

      fail = false;
      await harness.service.retry(key);
      final completed = await _waitFor(
        harness.service,
        key,
        (value) => value.complete,
      );
      expect(completed.rawCursor, 4);
      expect(starts.where((start) => start == 2).length, 5);
      expect(completed.regularCount, 3);
      await harness.dispose();
    },
  );

  test('authentication failures do not retry', () async {
    var calls = 0;
    final harness = _harness(delay: (_) async {});
    final key = _key(harness.scope, 'auth-library');
    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) async {
          calls++;
          throw const EmbyApiException('unauthorized', statusCode: 401);
        },
      ),
    );

    final snapshot = await _waitFor(
      harness.service,
      key,
      (value) => value.safeError == LibraryScanErrorKind.unauthorized,
    );
    expect(snapshot.status, LibraryScanStatus.paused);
    expect(calls, 1);
    await harness.dispose();
  });

  test('known total plus empty page pauses as pagination stalled', () async {
    final starts = <int>[];
    var recover = false;
    final harness = _harness();
    final key = _key(harness.scope, 'stalled-library');
    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) async {
          starts.add(startIndex);
          if (startIndex == 0) {
            return EmbyItemPage(
              items: [_item('regular', 'Movie', path: 'one.mp4')],
              rawItemCount: 1,
              totalRecordCount: 2,
            );
          }
          return recover
              ? EmbyItemPage(
                  items: [_item('regular-2', 'Movie', path: 'two.mp4')],
                  rawItemCount: 1,
                  totalRecordCount: 2,
                )
              : const EmbyItemPage(
                  items: [],
                  rawItemCount: 0,
                  totalRecordCount: 2,
                );
        },
      ),
    );
    final stalled = await _waitFor(
      harness.service,
      key,
      (value) => value.safeError == LibraryScanErrorKind.paginationStalled,
    );
    expect(stalled.rawCursor, 1);

    recover = true;
    await harness.service.retry(key);
    final completed = await _waitFor(
      harness.service,
      key,
      (value) => value.complete,
    );
    expect(completed.rawCursor, 2);
    expect(starts, [0, 1, 1]);
    await harness.dispose();
  });

  test('changing totals mark a completed scan dirty', () async {
    final harness = _harness();
    final key = _key(harness.scope, 'dirty-library');
    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) async =>
            startIndex == 0
            ? EmbyItemPage(
                items: [_item('one', 'Video', path: 'one.mp4')],
                rawItemCount: 1,
                totalRecordCount: 2,
              )
            : EmbyItemPage(
                items: [_item('two', 'Video', path: 'two.mp4')],
                rawItemCount: 1,
                totalRecordCount: 3,
              ),
      ),
    );
    final snapshot = await _waitFor(
      harness.service,
      key,
      (value) => value.complete,
    );
    expect(snapshot.dirty, isTrue);
    expect(snapshot.sourceTotalCount, 3);
    await harness.dispose();
  });

  test('candidate capacity pauses without advancing the failed page', () async {
    final harness = _harness(maxCandidateItems: 1);
    final key = _key(harness.scope, 'capacity-library');
    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) async => EmbyItemPage(
          items: [
            _item('one', 'Video', path: 'one.mp4'),
            _item('two', 'Video', path: 'two.mp4'),
          ],
          rawItemCount: 2,
          totalRecordCount: 2,
        ),
      ),
    );
    final snapshot = await _waitFor(
      harness.service,
      key,
      (value) => value.safeError == LibraryScanErrorKind.capacityReached,
    );
    expect(snapshot.rawCursor, 0);
    expect(snapshot.complete, isFalse);
    await harness.dispose();
  });

  test('pause and resume continue from the completed page cursor', () async {
    final firstPage = Completer<EmbyItemPage>();
    final starts = <int>[];
    final harness = _harness();
    final key = _key(harness.scope, 'lifecycle-library');
    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) {
          starts.add(startIndex);
          if (startIndex == 0) return firstPage.future;
          return Future.value(
            EmbyItemPage(
              items: [_item('two', 'Video', path: 'two.mp4')],
              rawItemCount: 1,
              totalRecordCount: 2,
            ),
          );
        },
      ),
    );
    await _waitFor(
      harness.service,
      key,
      (value) => value.status == LibraryScanStatus.scanning,
    );
    harness.service.pauseAll();
    firstPage.complete(
      EmbyItemPage(
        items: [_item('one', 'Video', path: 'one.mp4')],
        rawItemCount: 1,
        totalRecordCount: 2,
      ),
    );
    final paused = await _waitFor(
      harness.service,
      key,
      (value) =>
          value.status == LibraryScanStatus.paused && value.safeError == null,
    );
    expect(paused.rawCursor, 1);

    harness.service.resumeAll();
    final completed = await _waitFor(
      harness.service,
      key,
      (value) => value.complete,
    );
    expect(completed.rawCursor, 2);
    expect(starts, [0, 1]);
    await harness.dispose();
  });

  test('cache retains only the three most recent completed sessions', () async {
    final harness = _harness();
    final keys = <LibraryScanKey>[];
    for (var index = 0; index < 4; index++) {
      final key = _key(harness.scope, 'cache-$index');
      keys.add(key);
      harness.service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) async =>
              const EmbyItemPage(items: [], totalRecordCount: 0),
        ),
      );
      await _waitFor(harness.service, key, (value) => value.complete);
    }

    expect(harness.service.snapshotFor(keys.first), isNull);
    for (final key in keys.skip(1)) {
      expect(harness.service.snapshotFor(key)?.complete, isTrue);
    }
    await harness.dispose();
  });

  test('global limiter runs no more than two scope scans', () async {
    final harnesses = [
      _harness(scopeSuffix: 'one'),
      _harness(scopeSuffix: 'two'),
      _harness(scopeSuffix: 'three'),
    ];
    final responses = List.generate(3, (_) => Completer<EmbyItemPage>());
    var active = 0;
    var maximumActive = 0;
    var starts = 0;
    for (var index = 0; index < harnesses.length; index++) {
      final harness = harnesses[index];
      final key = _key(harness.scope, 'global-$index');
      harness.service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) async {
            starts++;
            active++;
            if (active > maximumActive) maximumActive = active;
            try {
              return await responses[index].future;
            } finally {
              active--;
            }
          },
        ),
      );
    }
    await _waitUntil(() => starts == 2);
    expect(maximumActive, 2);

    responses.first.complete(
      const EmbyItemPage(items: [], totalRecordCount: 0),
    );
    await _waitUntil(() => starts == 3);
    expect(maximumActive, 2);
    responses[1].complete(const EmbyItemPage(items: [], totalRecordCount: 0));
    responses[2].complete(const EmbyItemPage(items: [], totalRecordCount: 0));
    for (final harness in harnesses) {
      await harness.dispose();
    }
  });

  test('cancelAll waits for the active page request', () async {
    final response = Completer<EmbyItemPage>();
    final harness = _harness();
    final key = _key(harness.scope, 'cancel-library');
    harness.service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) => response.future,
      ),
    );
    await _waitFor(
      harness.service,
      key,
      (value) => value.status == LibraryScanStatus.scanning,
    );

    var cancelled = false;
    final cancellation = harness.service.cancelAll().then((_) {
      cancelled = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isFalse);
    response.complete(const EmbyItemPage(items: [], totalRecordCount: 0));
    await cancellation;
    expect(cancelled, isTrue);
    harness.service.dispose();
    await harness.api.dispose();
  });

  test(
    'restart ignores the old response and starts a fresh raw cursor',
    () async {
      final oldResponse = Completer<EmbyItemPage>();
      final starts = <int>[];
      final harness = _harness();
      final key = _key(harness.scope, 'restart-library');
      harness.service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) {
            starts.add(startIndex);
            return oldResponse.future;
          },
        ),
      );
      await _waitFor(
        harness.service,
        key,
        (value) => value.status == LibraryScanStatus.scanning,
      );

      harness.service.restartScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) async {
            starts.add(startIndex);
            return EmbyItemPage(
              items: [_item('fresh', 'Video', path: 'fresh.mp4')],
              rawItemCount: 1,
              totalRecordCount: 1,
            );
          },
        ),
      );
      oldResponse.complete(
        EmbyItemPage(
          items: [_item('stale', 'Video', path: 'stale.mp4')],
          rawItemCount: 1,
          totalRecordCount: 1,
        ),
      );

      await _waitFor(harness.service, key, (value) => value.complete);
      expect(starts, [0, 0]);
      expect(
        harness.service
            .itemsFor(key, LibraryLocalMediaFilter.regular)
            .map((item) => item.id),
        ['fresh'],
      );
      await harness.dispose();
    },
  );
}

class _ScanHarness {
  _ScanHarness(this.api, this.scope, this.service);

  final EmbyApi api;
  final ServerScope scope;
  final LibraryLocalMediaScanService service;

  Future<void> dispose() async {
    await service.cancelAll();
    service.dispose();
    await api.dispose();
  }
}

_ScanHarness _harness({
  LibraryScanDelay? delay,
  int maxCandidateItems = 20000,
  String scopeSuffix = 'default',
}) {
  final session = EmbySession(
    serverUrl: _session.serverUrl,
    serverName: _session.serverName,
    serverId: '${_session.serverId}-$scopeSuffix',
    userId: _session.userId,
    username: _session.username,
    accessToken: _session.accessToken,
    deviceId: _session.deviceId,
  );
  final api = EmbyApi(session, dio: Dio());
  final scope = ServerScope.fromSession(session);
  return _ScanHarness(
    api,
    scope,
    LibraryLocalMediaScanService(
      api: api,
      scope: scope,
      delay: delay,
      maxCandidateItems: maxCandidateItems,
    ),
  );
}

LibraryScanKey _key(ServerScope scope, String libraryId) => LibraryScanKey(
  scopeNamespace: scope.cacheNamespace,
  libraryId: libraryId,
  scope: LibraryBrowseScope.media,
  mediaType: LibraryMediaType.all,
  playedFilter: LibraryPlayedFilter.all,
  facet: null,
  sortBy: LibrarySortBy.name,
  sortOrder: LibrarySortOrder.ascending,
  alphabetFilter: const AllItems(),
);

Future<LibraryLocalScanSnapshot> _waitFor(
  LibraryLocalMediaScanService service,
  LibraryScanKey key,
  bool Function(LibraryLocalScanSnapshot snapshot) predicate,
) async {
  final current = service.snapshotFor(key);
  if (current != null && predicate(current)) return current;
  final completer = Completer<LibraryLocalScanSnapshot>();
  void listener() {
    final snapshot = service.snapshotFor(key);
    if (snapshot != null && predicate(snapshot) && !completer.isCompleted) {
      completer.complete(snapshot);
    }
  }

  service.addListener(listener);
  try {
    return await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    service.removeListener(listener);
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for scan concurrency state');
}

EmbyItem _item(String id, String type, {String? path, String? container}) =>
    EmbyItem(
      id: id,
      name: id,
      type: type,
      path: path,
      container: container,
      imageTags: const {},
      backdropImageTags: const [],
      genres: const [],
      userData: const EmbyUserData(),
    );

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
