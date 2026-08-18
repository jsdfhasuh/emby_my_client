import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/library/library_navigation_context.dart';
import 'package:emby_my_client/library/library_root_resolver.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('known origins bypass root and ancestor requests', () async {
    final root = _item(
      'library-1',
      type: 'CollectionFolder',
      collectionType: 'movies',
    );
    final item = _item('movie-1', parentId: 'folder-1');
    final api = _RootApi(views: const [], items: const {});
    addTearDown(api.dispose);
    final origin = LibraryBrowseOrigin(
      rootView: root,
      profile: LibraryContentProfile.movies,
    );

    final resolved = await LibraryRootResolver(
      api: api,
    ).resolve(item: item, knownOrigin: origin);

    expect(identical(resolved, origin), isTrue);
    expect(api.viewRequests, 0);
    expect(api.itemRequests, isEmpty);
  });

  test(
    'resolves a parent chain to a library root and caches the chain',
    () async {
      final root = _item(
        'library-1',
        type: 'CollectionFolder',
        collectionType: 'movies',
      );
      final folder = _item('folder-1', type: 'Folder', parentId: root.id);
      final item = _item('movie-1', parentId: folder.id);
      final api = _RootApi(views: [root], items: {folder.id: folder});
      addTearDown(api.dispose);
      final resolver = LibraryRootResolver(api: api);

      final first = await resolver.resolve(item: item);
      final second = await resolver.resolve(
        item: _item(item.id, parentId: 'other'),
      );

      expect(first.rootView.id, root.id);
      expect(first.profile, LibraryContentProfile.movies);
      expect(identical(second, first), isTrue);
      expect(api.viewRequests, 1);
      expect(api.itemRequests, [folder.id]);
    },
  );

  test('refreshes an item once when its parent ID is missing', () async {
    final root = _item(
      'library-1',
      type: 'CollectionFolder',
      collectionType: 'tvshows',
    );
    final item = _item('episode-1');
    final refreshed = _item(item.id, parentId: root.id);
    final api = _RootApi(views: [root], items: {item.id: refreshed});
    addTearDown(api.dispose);

    final resolved = await LibraryRootResolver(api: api).resolve(item: item);

    expect(resolved.rootView.id, root.id);
    expect(resolved.profile, LibraryContentProfile.tvShows);
    expect(api.viewRequests, 1);
    expect(api.itemRequests, [item.id]);
  });

  test('fails closed when the parent chain loops', () async {
    final item = _item('movie-1', parentId: 'ancestor-a');
    final api = _RootApi(
      views: const [],
      items: {
        'ancestor-a': _item('ancestor-a', parentId: 'ancestor-b'),
        'ancestor-b': _item('ancestor-b', parentId: 'ancestor-a'),
      },
    );
    addTearDown(api.dispose);

    await expectLater(
      LibraryRootResolver(api: api).resolve(item: item),
      throwsA(
        isA<LibraryRootResolutionException>().having(
          (error) => error.failure,
          'failure',
          LibraryRootResolutionFailure.ancestorLoop,
        ),
      ),
    );
  });

  test('fails closed after the maximum ancestor depth', () async {
    final ancestors = <String, EmbyItem>{};
    for (var index = 0; index <= 32; index++) {
      ancestors['ancestor-$index'] = _item(
        'ancestor-$index',
        parentId: index == 32 ? 'ancestor-33' : 'ancestor-${index + 1}',
      );
    }
    final item = _item('movie-1', parentId: 'ancestor-0');
    final api = _RootApi(views: const [], items: ancestors);
    addTearDown(api.dispose);

    await expectLater(
      LibraryRootResolver(api: api).resolve(item: item),
      throwsA(
        isA<LibraryRootResolutionException>().having(
          (error) => error.failure,
          'failure',
          LibraryRootResolutionFailure.ancestorDepthExceeded,
        ),
      ),
    );
  });
}

class _RootApi extends EmbyApi {
  _RootApi({required this.views, required this.items})
    : super(_session, dio: Dio());

  final List<EmbyItem> views;
  final Map<String, EmbyItem> items;
  var viewRequests = 0;
  final itemRequests = <String>[];

  @override
  Future<List<EmbyItem>> getViews() async {
    viewRequests++;
    return views;
  }

  @override
  Future<EmbyItem> getItem(String itemId) async {
    itemRequests.add(itemId);
    final item = items[itemId];
    if (item == null) throw StateError('Missing test item $itemId');
    return item;
  }
}

EmbyItem _item(
  String id, {
  String type = 'Movie',
  String? collectionType,
  String? parentId,
}) => EmbyItem(
  id: id,
  name: id,
  type: type,
  collectionType: collectionType,
  parentId: parentId,
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
