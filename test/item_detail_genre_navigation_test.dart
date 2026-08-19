import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_navigation_context.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/ui/home_shell_navigation.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'genre action chips pass origin context and block duplicate taps',
    (tester) async {
      final item = _detailItem;
      final api = _DetailApi(item);
      addTearDown(api.dispose);
      final pending = Completer<void>();
      var callCount = 0;
      EmbyItem? calledItem;
      String? calledGenre;
      LibraryBrowseOrigin? calledOrigin;
      PlatformCapabilities? calledCapabilities;

      Future<void> openGenre(
        BuildContext context,
        EmbyItem item,
        String genre,
        LibraryBrowseOrigin? origin,
        PlatformCapabilities? capabilities,
      ) async {
        callCount++;
        calledItem = item;
        calledGenre = genre;
        calledOrigin = origin;
        calledCapabilities = capabilities;
        await pending.future;
      }

      final origin = const LibraryBrowseOrigin(
        rootView: _library,
        profile: LibraryContentProfile.movies,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: ItemDetailScreen(
            api: api,
            initialItem: item,
            libraryOrigin: origin,
            platformCapabilities: PlatformCapabilities.ipad,
            navigationActions: HomeShellNavigationActions(
              showHome: () {},
              showSearch: () {},
              openSettings: () async {},
              openAccount: () async {},
              openGenre: openGenre,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final chip = find.byKey(const ValueKey('item-detail-genre-0'));
      await tester.ensureVisible(chip);
      expect(find.bySemanticsLabel('查看“Drama”分类'), findsOneWidget);

      await tester.tap(chip);
      await tester.pump();
      await tester.tap(chip);
      await tester.pump();

      expect(callCount, 1);
      expect(calledItem, same(item));
      expect(calledGenre, 'Drama');
      expect(calledOrigin, same(origin));
      expect(calledCapabilities, PlatformCapabilities.ipad);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      pending.complete();
      await tester.pumpAndSettle();
      expect(callCount, 1);
      expect(find.byKey(const ValueKey('item-detail-genre-0')), findsOneWidget);
    },
  );

  testWidgets('genres remain ordinary chips without navigation actions', (
    tester,
  ) async {
    final api = _DetailApi(_detailItem);
    addTearDown(api.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ItemDetailScreen(api: api, initialItem: _detailItem),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('item-detail-genre-0'));
    expect(tester.widget(chip), isA<Chip>());
    expect(
      find.descendant(of: chip, matching: find.byType(ActionChip)),
      findsNothing,
    );
  });

  testWidgets('accepts only one genre request per detail route', (
    tester,
  ) async {
    final api = _DetailApi(_detailItem);
    addTearDown(api.dispose);
    final pending = Completer<void>();
    var callCount = 0;

    Future<void> openGenreRequest(GenreNavigationRequest request) async {
      callCount++;
      await pending.future;
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeShellRouteObserver],
        home: ItemDetailScreen(
          api: api,
          initialItem: _detailItem,
          navigationActions: HomeShellNavigationActions(
            showHome: () {},
            showSearch: () {},
            openSettings: () async {},
            openAccount: () async {},
            openGenreRequest: openGenreRequest,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('item-detail-genre-1')));
    await tester.pump();

    expect(callCount, 1);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('route coverage permanently invalidates a pending request', (
    tester,
  ) async {
    final api = _DetailApi(_detailItem);
    addTearDown(api.dispose);
    final pending = Completer<void>();
    bool? validAfterRouteChange;

    Future<void> openGenreRequest(GenreNavigationRequest request) async {
      await pending.future;
      validAfterRouteChange = request.isStillValid();
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeShellRouteObserver],
        home: ItemDetailScreen(
          api: api,
          initialItem: _detailItem,
          navigationActions: HomeShellNavigationActions(
            showHome: () {},
            showSearch: () {},
            openSettings: () async {},
            openAccount: () async {},
            openGenreRequest: openGenreRequest,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
    await tester.pump();

    unawaited(
      Navigator.of(tester.element(find.byType(ItemDetailScreen))).push<void>(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
      ),
    );
    await tester.pump();
    pending.complete();
    await tester.pumpAndSettle();

    expect(validAfterRouteChange, isFalse);
  });

  testWidgets('disposing detail does not surface a stale genre result', (
    tester,
  ) async {
    final api = _DetailApi(_detailItem);
    addTearDown(api.dispose);
    final pending = Completer<void>();

    Future<void> openGenreRequest(GenreNavigationRequest request) async {
      await pending.future;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ItemDetailScreen(
          api: api,
          initialItem: _detailItem,
          navigationActions: HomeShellNavigationActions(
            showHome: () {},
            showSearch: () {},
            openSettings: () async {},
            openAccount: () async {},
            openGenreRequest: openGenreRequest,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-detail-genre-0')));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _DetailApi extends EmbyApi {
  _DetailApi(this.item) : super(_session, dio: Dio());

  final EmbyItem item;

  @override
  Future<EmbyItem> getItem(String itemId) async => item;
}

const _detailItem = EmbyItem(
  id: 'movie-1',
  name: 'Test Movie',
  type: 'Movie',
  parentId: 'library-1',
  imageTags: {},
  backdropImageTags: [],
  genres: ['Drama', 'Sci-Fi & Fantasy'],
  userData: EmbyUserData(),
);

const _library = EmbyItem(
  id: 'library-1',
  name: 'Movies',
  type: 'CollectionFolder',
  collectionType: 'movies',
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
