import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final ipad in [false, true]) {
    for (final depth in [70, 100, 180]) {
      testWidgets(
        'background paged refresh preserves movie position at index $depth (iPad=$ipad)',
        (tester) async {
          _setCompactView(tester);
          if (ipad) tester.view.physicalSize = const Size(1080, 810);
          final socket = _FakeEmbySocket();
          final api = _MembershipApi(
            socket: socket,
            items: [
              for (var index = 0; index < 245; index++)
                _item('item-$index', userData: const EmbyUserData()),
            ],
          );
          await _pumpLibrary(
            tester,
            api,
            const LibraryBrowseState(),
            platformCapabilities: ipad ? PlatformCapabilities.ipad : null,
          );
          await tester.scrollUntilVisible(
            _itemFinder('item-$depth'),
            700,
            scrollable: _verticalScrollable(),
            maxScrolls: 200,
          );
          await tester.pumpAndSettle();
          final position = tester
              .state<ScrollableState>(_verticalScrollable())
              .position;
          final previousOffset = position.pixels;
          final navigator = Navigator.of(
            tester.element(find.byType(LibraryBrowseScreen)),
          );
          await _coverLibrary(tester, navigator);
          await tester.pump(const Duration(seconds: 90));

          api.mediaPageDelay = const Duration(milliseconds: 200);
          for (var refresh = 0; refresh < 2; refresh++) {
            socket.emitLibraryChanged(itemsUpdated: ['item-$depth']);
            await _pumpRealtime(tester, settle: false);
            await _finishDelayedPages(tester);
          }

          navigator.pop();
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
          expect(position.pixels, closeTo(previousOffset, 1));
          expect(_itemFinder('item-$depth').hitTestable(), findsOneWidget);
          await _disposeLibrary(tester, api);
        },
      );
    }
  }

  testWidgets('a local rescan preserves position behind detail and playback', (
    tester,
  ) async {
    _setCompactView(tester);
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        for (var index = 0; index < 245; index++)
          _item('item-$index', userData: const EmbyUserData(), isRegular: true),
      ],
    );
    final scanService = LibraryLocalMediaScanService(
      api: api,
      scope: ServerScope.fromSession(api.session),
      delay: (_) => Future<void>.value(),
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(localFilter: LibraryLocalMediaFilter.regular),
      scanService: scanService,
    );
    final position = await _scrollToItem(tester, 'item-180');
    final previousOffset = position.pixels;
    final navigator = Navigator.of(
      tester.element(find.byType(LibraryBrowseScreen)),
    );
    await _coverLibrary(tester, navigator);
    await tester.pump(const Duration(seconds: 90));
    final gate = Completer<void>();
    api.localScanGate = gate;
    socket.emitLibraryChanged(itemsUpdated: ['item-180']);
    await _pumpRealtime(tester, settle: false);
    gate.complete();
    api.localScanGate = null;
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(previousOffset, 1));
    expect(_itemFinder('item-180').hitTestable(), findsOneWidget);
    await _disposeLibrary(tester, api, scanService: scanService);
  });

  testWidgets('returning during a refresh keeps the full visible list', (
    tester,
  ) async {
    _setCompactView(tester);
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        for (var index = 0; index < 185; index++)
          _item('item-$index', userData: const EmbyUserData()),
      ],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState());
    final position = await _scrollToItem(tester, 'item-100');
    final previousOffset = position.pixels;
    final navigator = Navigator.of(
      tester.element(find.byType(LibraryBrowseScreen)),
    );
    await _coverLibrary(tester, navigator);
    final gate = Completer<void>();
    api
      ..mediaPageGate = gate
      ..mediaPageDelay = const Duration(milliseconds: 200);
    socket.emitLibraryChanged(itemsUpdated: ['item-100']);
    await _pumpRealtime(tester, settle: false);

    for (var route = 0; route < 2; route++) {
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(_itemFinder('item-100').hitTestable(), findsOneWidget);
    expect(position.pixels, closeTo(previousOffset, 1));
    gate.complete();
    api.mediaPageGate = null;
    // Check every partial page, as well as the completed replacement result.
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(position.pixels, closeTo(previousOffset, 1));
      expect(_itemFinder('item-100').hitTestable(), findsOneWidget);
    }
    await tester.pumpAndSettle();
    await _disposeLibrary(tester, api);
  });

  testWidgets('a failed later page keeps the original position and result', (
    tester,
  ) async {
    _setCompactView(tester);
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        for (var index = 0; index < 185; index++)
          _item('item-$index', userData: const EmbyUserData()),
      ],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState());
    final position = await _scrollToItem(tester, 'item-100');
    final previousOffset = position.pixels;
    final debugState =
        tester.state(find.byType(LibraryBrowseScreen))
            as LibraryBrowseDebugState;
    final previousIds = debugState.debugLoadedItemIds;
    final navigator = Navigator.of(
      tester.element(find.byType(LibraryBrowseScreen)),
    );
    await _coverLibrary(tester, navigator);
    api
      ..mediaPageDelay = const Duration(milliseconds: 200)
      ..failMediaStartIndex = 60;
    socket.emitLibraryChanged(itemsUpdated: ['item-100']);
    await _pumpRealtime(tester, settle: false);
    await _finishDelayedPages(tester);

    navigator.pop();
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(previousOffset, 1));
    expect(debugState.debugLoadedItemIds, previousIds);
    expect(debugState.debugLoadFailed, isFalse);
    expect(debugState.debugTotalCount, 185);
    await _disposeLibrary(tester, api);
  });

  for (final remainingCount in [70, 0]) {
    testWidgets(
      'a background result shrinking to $remainingCount clamps after layout',
      (tester) async {
        _setCompactView(tester);
        final socket = _FakeEmbySocket();
        final api = _MembershipApi(
          socket: socket,
          items: [
            for (var index = 0; index < 245; index++)
              _item('item-$index', userData: const EmbyUserData()),
          ],
        );
        await _pumpLibrary(tester, api, const LibraryBrowseState());
        final position = await _scrollToItem(tester, 'item-180');
        final navigator = Navigator.of(
          tester.element(find.byType(LibraryBrowseScreen)),
        );
        await _coverLibrary(tester, navigator);
        api
          ..retainItems(remainingCount)
          ..mediaPageDelay = const Duration(milliseconds: 200);
        socket.emitLibraryChanged(itemsUpdated: ['item-180']);
        await _pumpRealtime(tester, settle: false);
        await _finishDelayedPages(tester);

        navigator.pop();
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(position.maxScrollExtent, 1));
        final debugState =
            tester.state(find.byType(LibraryBrowseScreen))
                as LibraryBrowseDebugState;
        expect(debugState.debugLoadedItemIds, hasLength(remainingCount));
        if (remainingCount > 0) {
          expect(
            _itemFinder('item-${remainingCount - 1}').hitTestable(),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await _disposeLibrary(tester, api);
      },
    );
  }

  testWidgets('a filter change cancels a preserving refresh and its position', (
    tester,
  ) async {
    _setCompactView(tester);
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        for (var index = 0; index < 185; index++)
          _item('item-$index', userData: const EmbyUserData(isFavorite: true)),
      ],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState());
    final position = await _scrollToItem(tester, 'item-100');
    final gate = Completer<void>();
    api.mediaPageGate = gate;
    socket.emitLibraryChanged(itemsUpdated: ['item-100']);
    await _pumpRealtime(tester, settle: false);
    position.jumpTo(0);
    await tester.pump();
    api.mediaPageGate = null;
    await tester.tap(find.byKey(const ValueKey('library-section-favorites')));
    await _pumpRealtime(tester, settle: false);
    gate.complete();
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(_itemFinder('item-0').hitTestable(), findsOneWidget);
    final debugState =
        tester.state(find.byType(LibraryBrowseScreen))
            as LibraryBrowseDebugState;
    expect(debugState.debugLoadedItemIds, hasLength(60));
    await _disposeLibrary(tester, api);
  });

  const transitions = [
    _MembershipTransition(
      name: 'unplayed item becomes played',
      state: LibraryBrowseState(playedFilter: LibraryPlayedFilter.unplayed),
      before: EmbyUserData(),
      after: EmbyUserData(isPlayed: true),
    ),
    _MembershipTransition(
      name: 'played item becomes unplayed',
      state: LibraryBrowseState(playedFilter: LibraryPlayedFilter.played),
      before: EmbyUserData(isPlayed: true),
      after: EmbyUserData(),
    ),
    _MembershipTransition(
      name: 'favorite item becomes unfavorite',
      state: LibraryBrowseState.favorites(),
      before: EmbyUserData(isFavorite: true),
      after: EmbyUserData(),
    ),
    _MembershipTransition(
      name: 'favorite unplayed item becomes played',
      state: LibraryBrowseState(
        scope: LibraryBrowseScope.favorites,
        playedFilter: LibraryPlayedFilter.unplayed,
      ),
      before: EmbyUserData(isFavorite: true),
      after: EmbyUserData(isFavorite: true, isPlayed: true),
    ),
    _MembershipTransition(
      name: 'favorite played item becomes unplayed',
      state: LibraryBrowseState(
        scope: LibraryBrowseScope.favorites,
        playedFilter: LibraryPlayedFilter.played,
      ),
      before: EmbyUserData(isFavorite: true, isPlayed: true),
      after: EmbyUserData(isFavorite: true),
    ),
  ];

  for (final transition in transitions) {
    testWidgets('${transition.name} reloads filtered membership', (
      tester,
    ) async {
      final socket = _FakeEmbySocket();
      final api = _MembershipApi(
        socket: socket,
        items: [_item('target', userData: transition.before)],
      );
      await _pumpLibrary(tester, api, transition.state);
      expect(_itemFinder('target'), findsOneWidget);

      api.updateUserData('target', transition.after);
      socket.emitUserData(['target']);
      await _pumpRealtime(tester);

      expect(_itemFinder('target'), findsNothing);
      expect(api.userDataCalls, 1);
      expect(api.mediaCalls, 2);
      await _disposeLibrary(tester, api);
    });
  }

  testWidgets('progress-only changes update a favorite item without reload', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [_item('target', userData: const EmbyUserData(isFavorite: true))],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState.favorites());

    api.updateUserData(
      'target',
      const EmbyUserData(
        isFavorite: true,
        playbackPositionTicks: 900,
        playedPercentage: 25,
      ),
    );
    socket.emitUserData(['target']);
    await _pumpRealtime(tester);

    final card = tester.widget<MediaPosterCard>(_itemFinder('target'));
    expect(card.item.userData.playbackPositionTicks, 900);
    expect(card.item.userData.playedPercentage, 25);
    expect(api.userDataCalls, 1);
    expect(api.mediaCalls, 1);
    await _disposeLibrary(tester, api);
  });

  testWidgets('progress-only changes in play count sort do not reload', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [_item('target', userData: const EmbyUserData(playCount: 4))],
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(sortBy: LibrarySortBy.playCount),
    );

    api.updateUserData(
      'target',
      const EmbyUserData(
        playCount: 4,
        playbackPositionTicks: 900,
        playedPercentage: 25,
      ),
    );
    socket.emitUserData(['target']);
    await _pumpRealtime(tester);

    final card = tester.widget<MediaPosterCard>(_itemFinder('target'));
    expect(card.item.userData.playCount, 4);
    expect(card.item.userData.playbackPositionTicks, 900);
    expect(api.userDataCalls, 1);
    expect(api.mediaCalls, 1);
    await _disposeLibrary(tester, api);
  });

  testWidgets('play count changes trigger one server reorder', (tester) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        _item('first', userData: const EmbyUserData(playCount: 1)),
        _item('second', userData: const EmbyUserData(playCount: 2)),
      ],
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(sortBy: LibrarySortBy.playCount),
    );
    expect(_visibleItemIds(tester), ['first', 'second']);

    api.updateUserData('first', const EmbyUserData(playCount: 3));
    socket.emitUserData(['first']);
    await _pumpRealtime(tester);

    expect(_visibleItemIds(tester), ['second', 'first']);
    expect(api.userDataCalls, 1);
    expect(api.mediaCalls, 2);
    await _disposeLibrary(tester, api);
  });

  testWidgets('unknown play count item triggers a preserving reorder', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [_item('loaded', userData: const EmbyUserData(playCount: 1))],
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(sortBy: LibrarySortBy.playCount),
    );

    socket.emitUserData(['not-loaded']);
    await _pumpRealtime(tester);

    expect(api.userDataCalls, 0);
    expect(api.mediaCalls, 2);
    await _disposeLibrary(tester, api);
  });

  testWidgets('empty UserDataChanged IDs trigger a play count reorder', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [_item('loaded', userData: const EmbyUserData(playCount: 1))],
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(sortBy: LibrarySortBy.playCount),
    );

    socket.emitUserData(const []);
    await _pumpRealtime(tester);

    expect(api.userDataCalls, 0);
    expect(api.mediaCalls, 2);
    await _disposeLibrary(tester, api);
  });

  testWidgets('a play count batch performs one reorder', (tester) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        _item('first', userData: const EmbyUserData(playCount: 1)),
        _item('second', userData: const EmbyUserData(playCount: 2)),
      ],
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(sortBy: LibrarySortBy.playCount),
    );

    api
      ..updateUserData('first', const EmbyUserData(playCount: 4))
      ..updateUserData('second', const EmbyUserData(playCount: 3));
    socket
      ..emitUserData(['first'])
      ..emitUserData(['second']);
    await _pumpRealtime(tester);

    expect(_visibleItemIds(tester), ['second', 'first']);
    expect(api.userDataCalls, 1);
    expect(api.mediaCalls, 2);
    await _disposeLibrary(tester, api);
  });

  testWidgets('play count changes restart the current local scan query', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        _item(
          'first',
          userData: const EmbyUserData(playCount: 1),
          isStrm: true,
        ),
        _item(
          'second',
          userData: const EmbyUserData(playCount: 2),
          isStrm: true,
        ),
      ],
    );
    final scanService = LibraryLocalMediaScanService(
      api: api,
      scope: ServerScope.fromSession(api.session),
      delay: (_) => Future<void>.value(),
    );
    await _pumpLibrary(
      tester,
      api,
      const LibraryBrowseState(
        mediaType: LibraryMediaType.movie,
        localFilter: LibraryLocalMediaFilter.strm,
        sortBy: LibrarySortBy.playCount,
        sortOrder: LibrarySortOrder.descending,
      ),
      scanService: scanService,
    );
    expect(_visibleItemIds(tester), ['second', 'first']);

    api.updateUserData('first', const EmbyUserData(playCount: 3));
    socket.emitUserData(['first']);
    await _pumpRealtime(tester);

    expect(_visibleItemIds(tester), ['first', 'second']);
    expect(api.localScanCalls, 2);
    expect(
      api.localCalls.every(
        (call) =>
            call.sortBy == LibrarySortBy.playCount &&
            call.sortOrder == LibrarySortOrder.descending,
      ),
      isTrue,
    );
    await _disposeLibrary(tester, api, scanService: scanService);
  });

  testWidgets(
    'completed unplayed regular scan removes a played item without restarting and keeps position',
    (tester) async {
      _setCompactView(tester);
      final socket = _FakeEmbySocket();
      final api = _MembershipApi(
        socket: socket,
        items: [
          for (var index = 0; index < 125; index++)
            _item(
              'item-$index',
              userData: const EmbyUserData(),
              isRegular: true,
            ),
        ],
      );
      final scanService = LibraryLocalMediaScanService(
        api: api,
        scope: ServerScope.fromSession(api.session),
        delay: (_) => Future<void>.value(),
      );
      await _pumpLibrary(
        tester,
        api,
        const LibraryBrowseState(
          mediaType: LibraryMediaType.movie,
          localFilter: LibraryLocalMediaFilter.regular,
          playedFilter: LibraryPlayedFilter.unplayed,
        ),
        scanService: scanService,
      );
      final initialScanCalls = api.localScanCalls;
      expect(initialScanCalls, greaterThan(0));
      expect(scanService.debugCompletedCacheCount, 1);

      final scrollable = _verticalScrollable();
      await tester.scrollUntilVisible(
        _itemFinder('item-70'),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      final previousOffset = position.pixels;

      api.updateUserData('item-70', const EmbyUserData(isPlayed: true));
      socket.emitUserData(['item-70']);
      await _pumpRealtime(tester);

      expect(_itemFinder('item-70'), findsNothing);
      expect(api.userDataCalls, 1);
      expect(api.localScanCalls, initialScanCalls);
      expect(position.pixels, closeTo(previousOffset, 1));
      await _disposeLibrary(tester, api, scanService: scanService);
    },
  );

  testWidgets(
    'library change restarts a completed local scan without losing position',
    (tester) async {
      _setCompactView(tester);
      final socket = _FakeEmbySocket();
      final api = _MembershipApi(
        socket: socket,
        items: [
          for (var index = 0; index < 125; index++)
            _item(
              'item-$index',
              userData: const EmbyUserData(),
              isRegular: true,
            ),
        ],
      );
      final scanService = LibraryLocalMediaScanService(
        api: api,
        scope: ServerScope.fromSession(api.session),
        delay: (_) => Future<void>.value(),
      );
      await _pumpLibrary(
        tester,
        api,
        const LibraryBrowseState(
          mediaType: LibraryMediaType.movie,
          localFilter: LibraryLocalMediaFilter.regular,
          playedFilter: LibraryPlayedFilter.unplayed,
        ),
        scanService: scanService,
      );
      final initialScanCalls = api.localScanCalls;
      expect(initialScanCalls, 3);

      final scrollable = _verticalScrollable();
      await tester.scrollUntilVisible(
        _itemFinder('item-70'),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      final previousOffset = position.pixels;
      expect(previousOffset, greaterThan(0));

      final scanGate = Completer<void>();
      api.localScanGate = scanGate;
      api.updateUserData('item-70', const EmbyUserData(isPlayed: true));
      socket.emitLibraryChanged(itemsUpdated: ['item-70']);
      await _pumpRealtime(tester, settle: false);
      // Keep the visible list/offset while the new result is incomplete, but
      // never offer playback using the previous completed scan's stale items.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-play-all-button')),
        -700,
        scrollable: scrollable,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('library-play-all-button')),
            )
            .onPressed,
        isNull,
      );
      scanGate.complete();
      api.localScanGate = null;
      await tester.pumpAndSettle();

      final debugState =
          tester.state(find.byType(LibraryBrowseScreen))
              as LibraryBrowseDebugState;
      expect(debugState.debugLoadedItemIds, hasLength(124));
      expect(debugState.debugLoadedItemIds, isNot(contains('item-70')));
      expect(api.userDataCalls, 0);
      expect(
        api.localCalls
            .skip(initialScanCalls)
            .map((call) => call.startIndex)
            .toList(growable: false),
        [0, 60, 120],
      );
      expect(position.pixels, closeTo(previousOffset, 1));
      await _disposeLibrary(tester, api, scanService: scanService);
    },
  );

  for (final entry in const [
    (
      'an unloaded item entering favorites',
      LibraryBrowseState.favorites(),
      EmbyUserData(),
      EmbyUserData(isFavorite: true),
    ),
    (
      'an unloaded item entering unplayed',
      LibraryBrowseState(playedFilter: LibraryPlayedFilter.unplayed),
      EmbyUserData(isPlayed: true),
      EmbyUserData(),
    ),
  ]) {
    testWidgets('${entry.$1} triggers a preserving refresh', (tester) async {
      final socket = _FakeEmbySocket();
      final api = _MembershipApi(
        socket: socket,
        items: [_item('target', userData: entry.$3)],
      );
      await _pumpLibrary(tester, api, entry.$2);
      expect(_itemFinder('target'), findsNothing);

      api.updateUserData('target', entry.$4);
      socket.emitUserData(['target']);
      await _pumpRealtime(tester);

      expect(_itemFinder('target'), findsOneWidget);
      expect(api.userDataCalls, 0);
      expect(api.mediaCalls, 2);
      await _disposeLibrary(tester, api);
    });
  }

  testWidgets(
    'membership reload refills the raw cursor with a fresh total and keeps position',
    (tester) async {
      _setCompactView(tester);
      final socket = _FakeEmbySocket();
      final api = _MembershipApi(
        socket: socket,
        items: [
          for (var index = 0; index < 125; index++)
            _item(
              'item-$index',
              userData: const EmbyUserData(isFavorite: true),
            ),
        ],
      );
      await _pumpLibrary(tester, api, const LibraryBrowseState.favorites());
      final scrollable = _verticalScrollable();
      await tester.scrollUntilVisible(
        _itemFinder('item-70'),
        700,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(api.starts, [0, 0, 60]);
      final position = tester.state<ScrollableState>(scrollable).position;
      final previousOffset = position.pixels;

      api.updateUserData('item-0', const EmbyUserData());
      socket.emitUserData(['item-0']);
      await _pumpRealtime(tester);

      expect(api.starts, [0, 0, 60, 0, 0, 60]);
      expect(position.pixels, closeTo(previousOffset, 1));
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('收藏共 124 项'), findsOneWidget);
      expect(_itemFinder('item-0'), findsNothing);
      await _disposeLibrary(tester, api);
    },
  );

  testWidgets('stale user data cannot write into a newer query generation', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [_item('target', userData: const EmbyUserData(isFavorite: true))],
    );
    final deferred = Completer<Map<String, EmbyUserData>>();
    api.deferredUserData = deferred;
    await _pumpLibrary(tester, api, const LibraryBrowseState.favorites());

    socket.emitUserData(['target']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.userDataCalls, 1);
    await tester.tap(find.byKey(const ValueKey('library-section-media')));
    await tester.pumpAndSettle();

    deferred.complete({
      'target': const EmbyUserData(
        playbackPositionTicks: 999,
        playedPercentage: 99,
      ),
    });
    await tester.pumpAndSettle();

    final card = tester.widget<MediaPosterCard>(_itemFinder('target'));
    expect(card.item.userData.playbackPositionTicks, 0);
    expect(api.mediaCalls, 2);
    await _disposeLibrary(tester, api);
  });

  testWidgets('a realtime batch causes only one membership reload', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        _item('first', userData: const EmbyUserData(isFavorite: true)),
        _item('second', userData: const EmbyUserData(isFavorite: true)),
      ],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState.favorites());

    api
      ..updateUserData('first', const EmbyUserData())
      ..updateUserData('second', const EmbyUserData());
    socket
      ..emitUserData(['first'])
      ..emitUserData(['second']);
    await _pumpRealtime(tester);

    expect(api.userDataCalls, 1);
    expect(api.mediaCalls, 2);
    expect(_itemFinder('first'), findsNothing);
    expect(_itemFinder('second'), findsNothing);
    await _disposeLibrary(tester, api);
  });

  testWidgets('refresh-all batch preserves explicit unknown membership ids', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [
        _item('A', userData: const EmbyUserData(isFavorite: true)),
        _item('B', userData: const EmbyUserData()),
      ],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState.favorites());
    expect(_visibleItemIds(tester), ['A']);

    api.updateUserData('B', const EmbyUserData(isFavorite: true));
    socket
      ..emitUserData(const [])
      ..emitUserData(['B']);
    await _pumpRealtime(tester);

    expect(_visibleItemIds(tester), ['A', 'B']);
    expect(api.mediaCalls, 2);
    expect(api.userDataCalls, 0);
    await _disposeLibrary(tester, api);
  });

  testWidgets('failed preserving refresh restores the list and fixed message', (
    tester,
  ) async {
    final socket = _FakeEmbySocket();
    final api = _MembershipApi(
      socket: socket,
      items: [_item('target', userData: const EmbyUserData(isFavorite: true))],
    );
    await _pumpLibrary(tester, api, const LibraryBrowseState.favorites());

    api
      ..updateUserData('target', const EmbyUserData())
      ..failNextMediaPage = true;
    socket.emitUserData(['target']);
    await _pumpRealtime(tester, settle: false);

    expect(_itemFinder('target'), findsOneWidget);
    expect(find.text('收藏共 1 项'), findsOneWidget);
    expect(find.text('状态刷新失败，可稍后重试'), findsOneWidget);
    expect(find.textContaining('private membership fixture'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    await _disposeLibrary(tester, api);
  });
}

class _MembershipTransition {
  const _MembershipTransition({
    required this.name,
    required this.state,
    required this.before,
    required this.after,
  });

  final String name;
  final LibraryBrowseState state;
  final EmbyUserData before;
  final EmbyUserData after;
}

class _MediaCall {
  const _MediaCall({
    required this.startIndex,
    required this.sortBy,
    required this.sortOrder,
  });

  final int startIndex;
  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
}

class _MembershipApi extends EmbyApi {
  _MembershipApi({
    required _FakeEmbySocket socket,
    required List<EmbyItem> items,
  }) : _items = List<EmbyItem>.of(items),
       super(_session, dio: _testDio(), realtimeConnector: (_) async => socket);

  final List<EmbyItem> _items;
  final List<_MediaCall> calls = [];
  final List<_MediaCall> localCalls = [];
  int userDataCalls = 0;
  int localScanCalls = 0;
  Duration mediaPageDelay = Duration.zero;
  Completer<void>? mediaPageGate;
  int? failMediaStartIndex;
  Completer<void>? localScanGate;
  bool failNextMediaPage = false;
  Completer<Map<String, EmbyUserData>>? deferredUserData;

  int get mediaCalls => calls.length;
  List<int> get starts =>
      calls.map((call) => call.startIndex).toList(growable: false);

  void retainItems(int count) => _items.removeRange(count, _items.length);

  void updateUserData(String id, EmbyUserData userData) {
    final index = _items.indexWhere((item) => item.id == id);
    _items[index] = _items[index].copyWith(userData: userData);
  }

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
  }) async {
    await mediaPageGate?.future;
    if (mediaPageDelay > Duration.zero) {
      await Future<void>.delayed(mediaPageDelay);
    }
    if (failNextMediaPage || failMediaStartIndex == startIndex) {
      failNextMediaPage = false;
      failMediaStartIndex = null;
      calls.add(
        _MediaCall(
          startIndex: startIndex,
          sortBy: sortBy,
          sortOrder: sortOrder,
        ),
      );
      throw StateError('private membership fixture');
    }
    final filtered = _items.where((item) {
      if (favorites && !item.userData.isFavorite) return false;
      return switch (playedFilter) {
        LibraryPlayedFilter.all => true,
        LibraryPlayedFilter.played => item.userData.isPlayed,
        LibraryPlayedFilter.unplayed => !item.userData.isPlayed,
      };
    }).toList();
    _sortForQuery(filtered, sortBy, sortOrder);
    calls.add(
      _MediaCall(startIndex: startIndex, sortBy: sortBy, sortOrder: sortOrder),
    );
    final pageItems = filtered.skip(startIndex).take(limit).toList();
    return EmbyItemPage(
      items: pageItems,
      totalRecordCount: filtered.length,
      rawItemCount: pageItems.length,
    );
  }

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
    localScanCalls++;
    await localScanGate?.future;
    final candidates = List<EmbyItem>.of(_items);
    _sortForQuery(candidates, sortBy, sortOrder);
    localCalls.add(
      _MediaCall(startIndex: startIndex, sortBy: sortBy, sortOrder: sortOrder),
    );
    final pageItems = candidates.skip(startIndex).take(limit).toList();
    return EmbyItemPage(
      items: pageItems,
      totalRecordCount: candidates.length,
      rawItemCount: pageItems.length,
    );
  }

  void _sortForQuery(
    List<EmbyItem> items,
    LibrarySortBy sortBy,
    LibrarySortOrder sortOrder,
  ) {
    if (sortBy != LibrarySortBy.playCount) return;
    items.sort((left, right) {
      final comparison = left.userData.playCount.compareTo(
        right.userData.playCount,
      );
      return sortOrder == LibrarySortOrder.ascending ? comparison : -comparison;
    });
  }

  @override
  Future<Map<String, EmbyUserData>> getUserDataForItems(
    Iterable<String> itemIds,
  ) {
    userDataCalls++;
    final deferred = deferredUserData;
    if (deferred != null) {
      deferredUserData = null;
      return deferred.future;
    }
    final ids = itemIds.toSet();
    return Future.value({
      for (final item in _items)
        if (ids.contains(item.id)) item.id: item.userData,
    });
  }
}

class _FakeEmbySocket implements EmbySocket {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();
  bool _closed = false;

  @override
  Stream<dynamic> get messages => _messages.stream;

  void emitUserData(List<String> itemIds) {
    _messages.add(
      jsonEncode({
        'MessageType': 'UserDataChanged',
        'Data': {
          'UserId': _session.userId,
          'UserDataList': [
            for (final itemId in itemIds) {'ItemId': itemId},
          ],
        },
      }),
    );
  }

  void emitLibraryChanged({List<String> itemsUpdated = const []}) {
    _messages.add(
      jsonEncode({
        'MessageType': 'LibraryChanged',
        'Data': {'ItemsUpdated': itemsUpdated},
      }),
    );
  }

  @override
  void add(String data) {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _messages.close();
  }
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  _MembershipApi api,
  LibraryBrowseState initialState, {
  LibraryLocalMediaScanService? scanService,
  PlatformCapabilities? platformCapabilities,
}) async {
  await api.realtime.start();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: LibraryBrowseScreen.root(
        api: api,
        view: _library,
        categorySettings: _allCategorySettings,
        initialState: initialState,
        libraryScanService: scanService,
        platformCapabilities: platformCapabilities,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpRealtime(WidgetTester tester, {bool settle = true}) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _coverLibrary(
  WidgetTester tester,
  NavigatorState navigator,
) async {
  for (final label in ['Detail', 'Player']) {
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(label))),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<ScrollPosition> _scrollToItem(WidgetTester tester, String id) async {
  await tester.scrollUntilVisible(
    _itemFinder(id),
    700,
    scrollable: _verticalScrollable(),
    maxScrolls: 200,
  );
  await tester.pumpAndSettle();
  return tester.state<ScrollableState>(_verticalScrollable()).position;
}

Future<void> _finishDelayedPages(WidgetTester tester) async {
  for (var frame = 0; frame < 24; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<void> _disposeLibrary(
  WidgetTester tester,
  _MembershipApi api, {
  LibraryLocalMediaScanService? scanService,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(api.dispose);
  if (scanService != null) {
    await scanService.cancelAll();
    scanService.dispose();
  }
}

void _setCompactView(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

Finder _itemFinder(String id) =>
    find.byKey(ValueKey<String>('library-item-$id'));

Dio _testDio() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<dynamic>(requestOptions: options, statusCode: 204),
      ),
    ),
  );

EmbyItem _item(
  String id, {
  required EmbyUserData userData,
  bool isStrm = false,
  bool isRegular = false,
}) => EmbyItem(
  id: id,
  name: id,
  type: 'Movie',
  mediaType: 'Video',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: userData,
  path: isStrm
      ? '/media/$id.strm'
      : isRegular
      ? '/media/$id.mkv'
      : null,
  container: isStrm
      ? 'strm'
      : isRegular
      ? 'mkv'
      : null,
);

List<String> _visibleItemIds(WidgetTester tester) => tester
    .widgetList<MediaPosterCard>(find.byType(MediaPosterCard))
    .map((card) => card.item.id)
    .toList(growable: false);

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
  name: 'Media',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _allCategorySettings = LibraryCategorySettings(
  showMovies: true,
  showSeries: true,
  showVideos: true,
  showFavorites: true,
  showFolders: true,
);
