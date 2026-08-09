import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_local_media_scan_cache.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('local scan continues after the browse screen is disposed', (
    tester,
  ) async {
    final api = _PageLifetimeApi();
    final scope = ServerScope.fromSession(api.session);
    final service = LibraryLocalMediaScanService(api: api, scope: scope);
    final state = const LibraryBrowseState(
      localFilter: LibraryLocalMediaFilter.strm,
    );
    final key = LibraryScanKey.fromBrowseState(
      scopeNamespace: scope.cacheNamespace,
      libraryId: _library.id,
      state: state,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(
          api: api,
          view: _library,
          initialState: state,
          libraryScanService: service,
        ),
      ),
    );
    await _pumpUntil(tester, () => api.secondPageRequested);

    await tester.pumpWidget(const SizedBox.shrink());
    api.secondPage.complete(
      EmbyItemPage(
        items: [_item('strm-second', path: 'second.strm')],
        rawItemCount: 60,
        totalRecordCount: 120,
      ),
    );
    await _pumpUntil(tester, () => service.snapshotFor(key)?.complete ?? false);

    expect(service.snapshotFor(key)?.rawCursor, 120);
    expect(
      service
          .itemsFor(key, LibraryLocalMediaFilter.strm)
          .map((item) => item.id),
      ['strm-first', 'strm-second'],
    );

    await service.cancelAll();
    service.dispose();
    await api.dispose();
  });
}

class _PageLifetimeApi extends EmbyApi {
  _PageLifetimeApi() : super(_session, dio: Dio());

  final Completer<EmbyItemPage> secondPage = Completer<EmbyItemPage>();
  bool secondPageRequested = false;

  @override
  Future<EmbyItemPage> getLocalMediaScanCandidates({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibraryMediaType mediaType = LibraryMediaType.all,
    LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
    bool favorites = false,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) async {
    if (startIndex == 0) {
      return EmbyItemPage(
        items: [_item('strm-first', path: 'first.strm')],
        rawItemCount: 60,
        totalRecordCount: 120,
      );
    }
    secondPageRequested = true;
    return secondPage.future;
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for local scan state');
}

EmbyItem _item(String id, {required String path}) => EmbyItem(
  id: id,
  name: id,
  type: 'Video',
  path: path,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

const _library = EmbyItem(
  id: 'library-1',
  name: '混合媒体库',
  type: 'CollectionFolder',
  collectionType: 'homevideos',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
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
