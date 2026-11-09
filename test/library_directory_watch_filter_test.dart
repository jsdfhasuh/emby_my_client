import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_filter_test_helpers.dart';

void main() {
  testWidgets(
    'directory filter choices apply to leaves and follow child routes',
    (tester) async {
      final folder = _item('child-folder', 'Folder');
      final api = _DirectoryApi({
        _library.id: [
          folder,
          _item('root-new', 'Video'),
          _item('root-watched', 'Video', played: true),
          _item('root-viewed-photo', 'Photo', played: true),
        ],
        folder.id: [
          _item('grandchild-folder', 'Folder'),
          _item('child-new', 'Video'),
          _item('child-watched', 'Video', played: true),
          _item('child-viewed-photo', 'Photo', played: true),
        ],
      });
      await _pumpDirectory(tester, api);

      expect(
        find.byKey(const ValueKey('library-filter-button')),
        findsOneWidget,
      );
      await openLibraryFilter(tester);
      expect(find.text('观看状态'), findsOneWidget);
      expect(find.text('来源'), findsNothing);
      expect(
        find.byKey(const ValueKey('library-played-inProgress')),
        findsOneWidget,
      );
      await selectLibraryMediaType(tester, 'video');
      await selectLibraryPlayedFilter(tester, 'played');
      await applyLibraryFilter(tester);
      await tester.pumpAndSettle();

      expect(_debug(tester).debugLoadedItemIds, [
        'child-folder',
        'root-watched',
      ]);
      expect(_card('root-new'), findsNothing);
      expect(_card('root-viewed-photo'), findsNothing);
      expect(_count(tester), '目录筛选共 2 项（含目录）');

      await tester.tap(_card(folder.id));
      await tester.pumpAndSettle();
      expect(api.calls.last.parentId, folder.id);
      expect(_debug(tester).debugLoadedItemIds, [
        'grandchild-folder',
        'child-watched',
      ]);
      expect(_card('grandchild-folder'), findsOneWidget);
      expect(_card('child-watched'), findsOneWidget);
      expect(_card('child-new'), findsNothing);
      expect(_count(tester), '目录筛选共 2 项（含目录）');

      await openLibraryFilter(tester);
      expect(_selected(tester, 'library-media-type-video'), isTrue);
      expect(_selected(tester, 'library-played-played'), isTrue);
      await tester.tap(find.byKey(const ValueKey('library-filter-cancel')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_debug(tester).debugLoadedItemIds, [
        'child-folder',
        'root-watched',
      ]);
      await _dispose(tester, api);
    },
  );

  testWidgets(
    'a zero-match first raw page does not hide a later watched video',
    (tester) async {
      final api = _DirectoryApi({
        _library.id: [
          for (var index = 0; index < 60; index++) _item('new-$index', 'Video'),
          _item('watched-after-first-page', 'Video', played: true),
        ],
      });
      await _pumpDirectory(
        tester,
        api,
        state: const LibraryBrowseState.directory(
          playedFilter: LibraryPlayedFilter.played,
        ),
      );

      expect(api.startsFor(_library.id), [0, 60]);
      expect(_card('watched-after-first-page'), findsOneWidget);
      expect(_debug(tester).debugLoadedItemIds, ['watched-after-first-page']);
      expect(_debug(tester).debugNextStartIndex, 61);
      expect(_debug(tester).debugHasMore, isFalse);
      expect(_count(tester), '目录筛选共 1 项（含目录）');
      await _dispose(tester, api);
    },
  );

  testWidgets('one retained folder does not strand later matching videos', (
    tester,
  ) async {
    final api = _DirectoryApi({
      _library.id: [
        _item('first-folder', 'Folder'),
        for (var index = 0; index < 59; index++) _item('new-$index', 'Video'),
        _item('later-watched', 'Video', played: true),
      ],
    });
    await _pumpDirectory(
      tester,
      api,
      state: const LibraryBrowseState.directory(
        playedFilter: LibraryPlayedFilter.played,
      ),
    );

    // No scrolling occurs: a single folder cannot provide enough scroll extent
    // to request the next page through a scroll listener.
    expect(api.startsFor(_library.id), [0, 60]);
    expect(_card('first-folder'), findsOneWidget);
    expect(_card('later-watched'), findsOneWidget);
    expect(_debug(tester).debugLoadedItemIds, [
      'first-folder',
      'later-watched',
    ]);
    expect(_debug(tester).debugHasMore, isFalse);
    expect(_count(tester), '目录筛选共 2 项（含目录）');
    await _dispose(tester, api);
  });

  testWidgets('photo-only refresh reads past a newly empty first raw page', (
    tester,
  ) async {
    final api = _DirectoryApi({
      _library.id: [_item('original-photo', 'Photo')],
    });
    await _pumpDirectory(
      tester,
      api,
      state: const LibraryBrowseState.directory(
        mediaType: LibraryMediaType.photo,
      ),
    );
    expect(_card('original-photo'), findsOneWidget);
    expect(_debug(tester).debugNextStartIndex, 1);

    api.children[_library.id] = [
      for (var index = 0; index < 60; index++)
        _item('new-video-$index', 'Video'),
      _item('later-photo', 'Photo'),
    ];
    final refresh = _debug(tester).debugRefresh();
    await tester.pumpAndSettle();
    await refresh;
    await tester.pumpAndSettle();

    expect(api.startsFor(_library.id), [0, 0, 60]);
    expect(_card('original-photo'), findsNothing);
    expect(_card('later-photo'), findsOneWidget);
    expect(_debug(tester).debugLoadedItemIds, ['later-photo']);
    expect(_debug(tester).debugNextStartIndex, 61);
    expect(_debug(tester).debugHasMore, isFalse);
    expect(_count(tester), '目录筛选共 1 项（含目录）');
    await _dispose(tester, api);
  });

  testWidgets(
    'an entirely unmatched directory exhausts pages and shows empty state',
    (tester) async {
      final api = _DirectoryApi({
        _library.id: [
          for (var index = 0; index < 121; index++)
            _item('new-$index', 'Video'),
        ],
      });
      await _pumpDirectory(
        tester,
        api,
        state: const LibraryBrowseState.directory(
          playedFilter: LibraryPlayedFilter.played,
        ),
      );

      expect(api.startsFor(_library.id), [0, 60, 120]);
      expect(_debug(tester).debugLoadedItemIds, isEmpty);
      expect(_debug(tester).debugNextStartIndex, 121);
      expect(_debug(tester).debugHasMore, isFalse);
      expect(_debug(tester).debugLoadFailed, isFalse);
      expect(find.text('没有符合筛选条件的项目'), findsOneWidget);
      expect(_count(tester), '目录筛选共 0 项（含目录）');
      await _dispose(tester, api);
    },
  );

  testWidgets('one photo-directory scroll skips an unmatched middle page', (
    tester,
  ) async {
    final api = _DirectoryApi({
      _library.id: [
        for (var index = 0; index < 60; index++)
          _item('first-photo-$index', 'Photo'),
        for (var index = 0; index < 60; index++)
          _item('middle-video-$index', 'Video'),
        _item('last-photo', 'Photo'),
      ],
    });
    await _pumpDirectory(
      tester,
      api,
      state: const LibraryBrowseState.directory(
        mediaType: LibraryMediaType.photo,
      ),
    );
    expect(api.startsFor(_library.id), [0]);
    expect(_debug(tester).debugLoadedItemIds, hasLength(60));
    expect(_debug(tester).debugHasMore, isTrue);
    expect(_count(tester), '目录筛选已加载 60 项（含目录）');

    final scrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    // Only one scroll happened. The empty projected page at raw offset 60
    // must not require a second scroll that cannot move the old viewport.
    expect(api.startsFor(_library.id), [0, 60, 120]);
    expect(_debug(tester).debugLoadedItemIds, hasLength(61));
    expect(_debug(tester).debugLoadedItemIds.last, 'last-photo');
    expect(_debug(tester).debugNextStartIndex, 121);
    expect(_debug(tester).debugHasMore, isFalse);
    // Bring the scrollable toolbar back into the tree only after proving
    // that the single downward scroll already completed both raw requests.
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(api.startsFor(_library.id), [0, 60, 120]);
    expect(_count(tester), '目录筛选共 61 项（含目录）');
    await _dispose(tester, api);
  });

  for (final (filter, expectedIds) in [
    (
      LibraryPlayedFilter.unplayed,
      ['folder', 'album', 'new-video', 'partial-video', 'new-photo'],
    ),
    (
      LibraryPlayedFilter.played,
      ['folder', 'album', 'watched-video', 'viewed-photo'],
    ),
    (LibraryPlayedFilter.inProgress, ['folder', 'album', 'partial-video']),
  ]) {
    testWidgets(
      'directory ${filter.name} count includes preserved navigation only once',
      (tester) async {
        final api = _DirectoryApi({
          _library.id: [
            _item('folder', 'Folder'),
            _item('album', 'PhotoAlbum', played: true),
            _item('new-video', 'Video'),
            _item('partial-video', 'Video', percentage: 25),
            _item('watched-video', 'Video', played: true),
            _item('new-photo', 'Photo'),
            _item('viewed-photo', 'Photo', played: true),
            _item('unknown', 'Unknown'),
          ],
        });
        await _pumpDirectory(
          tester,
          api,
          state: LibraryBrowseState.directory(playedFilter: filter),
        );

        expect(_debug(tester).debugLoadedItemIds, expectedIds);
        expect(_debug(tester).debugNextStartIndex, 8);
        expect(_debug(tester).debugHasMore, isFalse);
        expect(_count(tester), '目录筛选共 ${expectedIds.length} 项（含目录）');
        expect(_card('folder'), findsOneWidget);
        expect(_card('album'), findsOneWidget);
        expect(_card('unknown'), findsNothing);
        await _dispose(tester, api);
      },
    );
  }

  testWidgets('photo viewing filters stay available and omit video progress', (
    tester,
  ) async {
    final api = _DirectoryApi({
      _library.id: [
        _item('folder', 'Folder'),
        _item('new-photo', 'Photo'),
        _item('viewed-photo', 'Photo', played: true),
        _item('watched-video', 'Video', played: true),
      ],
    });
    await _pumpDirectory(tester, api);
    await openLibraryFilter(tester);
    await selectLibraryMediaType(tester, 'photo');
    expect(find.text('查看状态'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-played-inProgress')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('library-played-unplayed')),
      findsOneWidget,
    );
    await selectLibraryPlayedFilter(tester, 'unplayed');
    await applyLibraryFilter(tester);
    await tester.pumpAndSettle();

    expect(_debug(tester).debugLoadedItemIds, ['folder', 'new-photo']);
    expect(_card('viewed-photo'), findsNothing);
    expect(_card('watched-video'), findsNothing);
    expect(_count(tester), '目录筛选共 2 项（含目录）');
    await _dispose(tester, api);
  });
}

Future<void> _pumpDirectory(
  WidgetTester tester,
  _DirectoryApi api, {
  LibraryBrowseState state = const LibraryBrowseState.directory(),
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: LibraryBrowseScreen.root(
        api: api,
        view: _library,
        initialState: state,
        categorySettings: const LibraryCategorySettings(
          showMovies: true,
          showVideos: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

LibraryBrowseDebugState _debug(WidgetTester tester) =>
    tester.state(find.byType(LibraryBrowseScreen)) as LibraryBrowseDebugState;

Finder _card(String id) => find.byKey(ValueKey('library-group-$id'));

String? _count(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('library-result-summary')))
    .data;

bool _selected(WidgetTester tester, String key) =>
    tester.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

Future<void> _dispose(WidgetTester tester, EmbyApi api) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await api.dispose();
}

class _DirectoryApi extends EmbyApi {
  _DirectoryApi(this.children) : super(_session, dio: Dio());

  final Map<String, List<EmbyItem>> children;
  final List<({String parentId, int startIndex})> calls = [];

  List<int> startsFor(String parentId) => calls
      .where((call) => call.parentId == parentId)
      .map((call) => call.startIndex)
      .toList();

  @override
  Future<EmbyItemPage> getDirectoryChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
  }) async {
    calls.add((parentId: parentId, startIndex: startIndex));
    final source = children[parentId] ?? const <EmbyItem>[];
    final items = source.skip(startIndex).take(limit).toList(growable: false);
    // This fixture deliberately does no filtering: the screen must project the
    // raw directory pages and keep their server offsets intact.
    return EmbyItemPage(
      items: items,
      rawItemCount: items.length,
      totalRecordCount: source.length,
    );
  }
}

EmbyItem _item(
  String id,
  String type, {
  bool played = false,
  double percentage = 0,
}) => EmbyItem(
  id: id,
  name: id,
  type: type,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: EmbyUserData(isPlayed: played, playedPercentage: percentage),
);

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'directory-filter-server',
  userId: 'directory-filter-user',
  username: 'tester',
  accessToken: 'fixture-token',
  deviceId: 'fixture-device',
);

const _library = EmbyItem(
  id: 'home-library',
  name: '家庭视频和图片',
  type: 'CollectionFolder',
  collectionType: 'homevideos',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
