import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('queue preparation errors show only fixed library UI text', (
    tester,
  ) async {
    final api = _PreparationApi(
      secondPage: () => Future<EmbyItemPage>.error(
        StateError('private-server-title private-token'),
      ),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-play-all-button')));
    await tester.pumpAndSettle();

    expect(find.text('播放队列准备失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('private-server-title'), findsNothing);
    expect(find.textContaining('private-token'), findsNothing);
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('cancelling queue preparation never opens the player', (
    tester,
  ) async {
    final secondPage = Completer<EmbyItemPage>();
    final api = _PreparationApi(secondPage: () => secondPage.future);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-play-all-button')));
    await tester.pump();
    expect(find.text('正在准备播放队列'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('library-playback-prepare-cancel')),
    );
    secondPage.complete(
      EmbyItemPage(
        items: [_video('late-video')],
        rawItemCount: 1,
        totalRecordCount: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('正在准备播放队列'), findsNothing);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('local playback stays disabled until scanning is complete', (
    tester,
  ) async {
    final api = _LocalScanApi();
    final service = LibraryLocalMediaScanService(
      api: api,
      scope: ServerScope.fromSession(api.session),
      delay: (_) => Future<void>.value(),
    );
    await tester.pumpWidget(
      _app(
        api,
        initialState: const LibraryBrowseState(
          localFilter: LibraryLocalMediaFilter.strm,
        ),
        scanService: service,
      ),
    );
    await _pumpUntil(tester, () => api.requested);

    expect(_playButton(tester).onPressed, isNull);
    api.page.complete(
      EmbyItemPage(
        items: [_video('complete-strm', path: 'complete.strm')],
        rawItemCount: 1,
        totalRecordCount: 1,
      ),
    );
    await _pumpUntil(tester, () => _playButton(tester).onPressed != null);

    expect(_playButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await service.cancelAll();
    service.dispose();
    await api.dispose();
  });
}

IconButton _playButton(WidgetTester tester) => tester.widget<IconButton>(
  find.byKey(const ValueKey('library-play-all-button')),
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for library playback state');
}

Widget _app(
  EmbyApi api, {
  LibraryBrowseState initialState = const LibraryBrowseState(),
  LibraryLocalMediaScanService? scanService,
}) => MaterialApp(
  home: LibraryBrowseScreen.root(
    api: api,
    view: _library,
    profile: LibraryContentProfile.mixed,
    initialState: initialState,
    libraryScanService: scanService,
  ),
);

class _PreparationApi extends EmbyApi {
  _PreparationApi({required this.secondPage}) : super(_session, dio: Dio());

  final Future<EmbyItemPage> Function() secondPage;

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
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
  }) {
    if (startIndex == 0) {
      return Future.value(
        EmbyItemPage(
          items: [_photo('initial-photo')],
          rawItemCount: 1,
          totalRecordCount: 2,
        ),
      );
    }
    return secondPage();
  }
}

class _LocalScanApi extends EmbyApi {
  _LocalScanApi() : super(_session, dio: Dio());

  final page = Completer<EmbyItemPage>();
  bool requested = false;

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
  }) {
    requested = true;
    return page.future;
  }
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

const _library = EmbyItem(
  id: 'library-1',
  name: '混合媒体库',
  type: 'CollectionFolder',
  collectionType: 'mixed',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

EmbyItem _video(String id, {String? path}) => EmbyItem(
  id: id,
  name: id,
  type: 'Video',
  mediaType: 'Video',
  path: path,
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
