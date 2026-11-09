import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/images/emby_image_request.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_sequence_source.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/photos/photo_viewer_screen.dart';
import 'package:emby_my_client/ui/widgets/library_directory_entry_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'returning a viewed photo refreshes filtered directory membership',
    (tester) async {
      final api = _ViewerRefreshApi([
        _item('folder', 'Folder'),
        _item('photo', 'Photo'),
        _item('video', 'Video'),
        _item(
          'watched-video',
          'Video',
          data: const EmbyUserData(isPlayed: true),
        ),
      ]);
      addTearDown(api.dispose);
      await _pumpDirectory(
        tester,
        api,
        const LibraryBrowseState.directory(
          playedFilter: LibraryPlayedFilter.unplayed,
        ),
      );
      expect(_debugState(tester).debugLoadedItemIds, [
        'folder',
        'photo',
        'video',
      ]);
      expect(api.directoryStarts, [0]);

      final viewer = await _openPhoto(tester);
      api.setUserData('photo', const EmbyUserData(isPlayed: true));
      _returnViewer(
        tester,
        viewer,
        changedIds: {'photo'},
        currentItemId: 'photo',
        items: [
          for (final item in viewer.source.initialItems)
            if (item.id == 'photo')
              item.copyWith(userData: const EmbyUserData(isPlayed: true))
            else
              item,
        ],
      );
      await tester.pumpAndSettle();

      expect(find.byType(PhotoViewerScreen), findsNothing);
      expect(api.directoryStarts, [0, 0]);
      expect(_debugState(tester).debugLoadedItemIds, ['folder', 'video']);
      expect(_debugState(tester).debugNextStartIndex, 4);
      expect(_debugState(tester).debugHasMore, isFalse);
      expect(find.byKey(const ValueKey('library-group-photo')), findsNothing);
      expect(
        find.byKey(const ValueKey('library-group-folder')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('library-group-video')), findsOneWidget);
      expect(find.text('目录筛选共 2 项（含目录）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'returning mixed playback refreshes touched video status without a websocket',
    (tester) async {
      final api = _ViewerRefreshApi([
        _item('folder', 'Folder'),
        _item('photo', 'Photo'),
        _item('video', 'Video'),
      ]);
      addTearDown(api.dispose);
      await _pumpDirectory(tester, api, const LibraryBrowseState.directory());
      final before = tester.widget<LibraryDirectoryEntryCard>(
        find.byKey(const ValueKey('library-group-video')),
      );
      expect(before.item.userData.isPlayed, isFalse);

      final viewer = await _openPhoto(tester);
      api.setUserData(
        'video',
        const EmbyUserData(isPlayed: true, playCount: 1),
      );
      // The returned browsing snapshot deliberately still contains old data.
      // Playback completion must trigger a fresh user-data request.
      _returnViewer(
        tester,
        viewer,
        changedIds: {'video'},
        currentItemId: 'video',
      );
      await tester.pumpAndSettle();

      expect(find.byType(PhotoViewerScreen), findsNothing);
      expect(api.userDataRequests, [
        <String>{'video'},
      ]);
      expect(api.directoryStarts, [0]);
      final after = tester.widget<LibraryDirectoryEntryCard>(
        find.byKey(const ValueKey('library-group-video')),
      );
      expect(after.item.userData.isPlayed, isTrue);
      expect(after.item.userData.playCount, 1);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-group-video')),
          matching: find.text('已观看'),
        ),
        findsOneWidget,
      );
      expect(_debugState(tester).debugLoadedItemIds, [
        'folder',
        'photo',
        'video',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

Future<void> _pumpDirectory(
  WidgetTester tester,
  _ViewerRefreshApi api,
  LibraryBrowseState initialState,
) async {
  tester.view.physicalSize = const Size(1024, 768);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: LibraryBrowseScreen.root(
        api: api,
        view: _library,
        initialState: initialState,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<PhotoViewerScreen> _openPhoto(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-group-photo')));
  await tester.pumpAndSettle();
  expect(find.byType(PhotoViewerScreen), findsOneWidget);
  final viewer = tester.widget<PhotoViewerScreen>(
    find.byType(PhotoViewerScreen),
  );
  expect(viewer.source, isA<DirectoryPhotoSource>());
  expect(viewer.source.mode, MediaViewerMode.homeMedia);
  return viewer;
}

void _returnViewer(
  WidgetTester tester,
  PhotoViewerScreen viewer, {
  required Set<String> changedIds,
  required String currentItemId,
  List<EmbyItem>? items,
}) {
  final source = viewer.source;
  Navigator.of(tester.element(find.byType(PhotoViewerScreen))).pop(
    MediaViewerResult(
      queryFingerprint: source.queryFingerprint,
      rawItems: items ?? source.initialItems,
      currentItemId: currentItemId,
      nextStartIndex: source.initialRawCursor,
      totalCount: source.initialTotalCount,
      totalDirty: source.initialTotalDirty,
      hasMore: source.initialHasMore,
      paginationStrategy: source.paginationStrategy,
      userDataChangedItemIds: changedIds,
    ),
  );
}

LibraryBrowseDebugState _debugState(WidgetTester tester) =>
    tester.state(find.byType(LibraryBrowseScreen)) as LibraryBrowseDebugState;

class _ViewerRefreshApi extends EmbyApi {
  _ViewerRefreshApi(List<EmbyItem> items)
    : _items = List.of(items),
      super(_session, dio: Dio());

  final List<EmbyItem> _items;
  final List<int> directoryStarts = [];
  final List<Set<String>> userDataRequests = [];

  void setUserData(String id, EmbyUserData data) {
    final index = _items.indexWhere((item) => item.id == id);
    _items[index] = _items[index].copyWith(userData: data);
  }

  @override
  Future<EmbyItemPage> getDirectoryChildren({
    required String parentId,
    int startIndex = 0,
    int limit = 60,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
  }) async {
    expect(parentId, _library.id);
    directoryStarts.add(startIndex);
    final page = _items.skip(startIndex).take(limit).toList();
    return EmbyItemPage(
      items: page,
      rawItemCount: page.length,
      totalRecordCount: _items.length,
    );
  }

  @override
  Future<Map<String, EmbyUserData>> getUserDataForItems(
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds.toSet();
    userDataRequests.add(ids);
    return {
      for (final item in _items)
        if (ids.contains(item.id)) item.id: item.userData,
    };
  }

  @override
  EmbyImageRequest? imageRequest(
    EmbyItem item, {
    String type = 'Primary',
    int maxWidth = 600,
    int? maxHeight,
    int quality = 90,
  }) => null;
}

EmbyItem _item(
  String id,
  String type, {
  EmbyUserData data = const EmbyUserData(),
}) => EmbyItem(
  id: id,
  name: id,
  type: type,
  mediaType: type == 'Video' ? 'Video' : null,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: data,
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

const _library = EmbyItem(
  id: 'home-media',
  name: '家庭视频和图片',
  type: 'CollectionFolder',
  collectionType: 'homevideos',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
