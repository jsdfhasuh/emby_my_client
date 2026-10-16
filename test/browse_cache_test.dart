import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/browse_cache.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/widgets/offline_browse_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets(
    'late automatic detail refresh cannot overwrite a newer manual refresh',
    (tester) async {
      final api = _DeferredDetailApi();
      addTearDown(api.dispose);
      final initial = EmbyItem.fromJson({
        'Id': 'item',
        'Name': 'Initial title',
        'Type': 'Movie',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ItemDetailScreen(api: api, initialItem: initial),
        ),
      );
      api.responses[0].complete(initial);
      await tester.pumpAndSettle();
      api.browseState.cached(
        'item',
        BrowseSnapshot({}, DateTime.utc(2026)),
        disconnected: true,
      );
      api.browseState.requestRecovery();
      await tester.pump(const Duration(milliseconds: 350));
      expect(api.responses, hasLength(2));
      await tester.tap(
        find.descendant(
          of: find.byType(OfflineBrowseBanner),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pump();
      expect(api.responses, hasLength(3));
      api.responses[2].complete(
        EmbyItem.fromJson({'Id': 'item', 'Name': 'New title', 'Type': 'Movie'}),
      );
      await tester.pumpAndSettle();
      api.responses[1].complete(
        EmbyItem.fromJson({'Id': 'item', 'Name': 'Old title', 'Type': 'Movie'}),
      );
      await tester.pumpAndSettle();
      expect(find.text('New title'), findsWidgets);
      expect(find.text('Old title'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'offline series detail keeps visited episodes and labels an uncached season',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final memory = _MemoryCache();
      final online = EmbyApi(
        _session(),
        browseCache: memory,
        dio: Dio()..httpClientAdapter = (_Adapter()..extraSeason = true),
      );
      late final EmbyItem series;
      await tester.runAsync(() async {
        series = await online.getItem('series');
        await online.getSeasons('series');
        await online.getEpisodes('series', seasonId: 'season');
        await online.dispose();
      });
      final offlineWire = _Adapter()..mode = 'offline';
      final offline = EmbyApi(
        _session(),
        browseCache: memory,
        dio: Dio()..httpClientAdapter = offlineWire,
      );
      addTearDown(offline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ItemDetailScreen(api: offline, initialItem: series),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Episode 1'), findsOneWidget);
      expect(find.textContaining('服务器离线，信息未更新'), findsOneWidget);
      final seasons = find.byType(DropdownButton<String>);
      await tester.ensureVisible(seasons);
      await tester.tap(seasons);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 2').last);
      await tester.pumpAndSettle();
      expect(find.text('此季剧集暂不可用；未缓存的内容需联网后查看'), findsOneWidget);
      expect(find.text('Episode 1'), findsNothing);
      expect(find.text('这一季没有剧集'), findsNothing);
      offlineWire
        ..mode = 'online'
        ..extraSeason = true;
      offline.browseState.requestRecovery();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Episode 1'), findsOneWidget);
      expect(offline.browseState.offline, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'disk database reopen restores home, lists, detail, seasons and episodes offline',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.close);
      final online = harness.api();
      await online.getHomeBase();
      await online.getLatestItems(parentId: 'library');
      await online.getLibraryMediaItems(parentId: 'library');
      await online.getItem('item');
      await online.getSeasons('series');
      await online.getEpisodes('series', seasonId: 'season');
      await online.dispose();
      await harness.database.close();
      // A new database handle, repository and API: no shared in-memory snapshots.
      harness.reopen();
      final offline = harness.api(mode: 'offline');
      expect((await offline.getHomeBase()).views.single.name, 'Visited Movies');
      expect(
        (await offline.getLatestItems(parentId: 'library')).single.id,
        'item',
      );
      expect(
        (await offline.getLibraryMediaItems(
          parentId: 'library',
        )).items.single.id,
        'item',
      );
      expect((await offline.getItem('item')).overview, 'Saved overview');
      expect((await offline.getSeasons('series')).single.id, 'season');
      expect(
        (await offline.getEpisodes('series', seasonId: 'season')).single.id,
        'episode',
      );
      expect(offline.browseState.offline, isTrue);
      expect(offline.browseState.cachedAt, isNotNull);
    },
  );

  test(
    'page, sort, filter and account scope are part of cache identity',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.close);
      final a = harness.api();
      await a.getLibraryMediaItems(parentId: 'library');
      final offline = harness.api(mode: 'offline');
      expect(
        (await offline.getLibraryMediaItems(
          parentId: 'library',
        )).items.single.id,
        'item',
      );
      for (final request in <Future<dynamic> Function()>[
        () => offline.getLibraryMediaItems(parentId: 'library', startIndex: 60),
        () =>
            offline.getLibraryMediaItems(parentId: 'library', favorites: true),
        () => offline.getLibraryMediaItems(
          parentId: 'library',
          sortOrder: LibrarySortOrder.descending,
        ),
        () => offline.getLibraryMediaItems(parentId: 'other'),
        () => harness
            .api(mode: 'offline', server: 'other')
            .getLibraryMediaItems(parentId: 'library'),
        () => harness
            .api(mode: 'offline', user: 'other')
            .getLibraryMediaItems(parentId: 'library'),
      ]) {
        await expectLater(
          request(),
          throwsA(
            isA<EmbyApiException>().having(
              (e) => e.message,
              'message',
              contains('尚未缓存'),
            ),
          ),
        );
      }
    },
  );

  for (final failure in ['offline', '503', 'malformed', 'wrong-item']) {
    test(
      '$failure keeps old successful snapshot; recovery updates it',
      () async {
        final harness = await _Harness.create();
        addTearDown(harness.close);
        final api = harness.api();
        await api.getItem('item');
        harness.adapters.last.mode = failure;
        expect((await api.getItem('item')).name, 'Saved item');
        harness.adapters.last.mode = 'updated';
        expect((await api.getItem('item')).name, 'Updated item');
        expect(api.browseState.offline, isFalse);
        expect(api.browseState.hasStalePages, isFalse);
        harness.adapters.last.mode = 'offline';
        expect((await api.getItem('item')).name, 'Updated item');
      },
    );
  }

  for (final status in ['401', '403']) {
    test(
      '$status is never replaced with cached success, even after network loss',
      () async {
        final harness = await _Harness.create();
        addTearDown(harness.close);
        var expired = 0;
        final api = harness.api(onExpired: () => expired++);
        await api.getItem('item');
        harness.adapters.last.mode = status;
        await expectLater(
          api.getItem('item'),
          throwsA(
            isA<EmbyApiException>().having(
              (e) => e.statusCode,
              'status',
              int.parse(status),
            ),
          ),
        );
        expect(api.browseState.authenticationRequired, isTrue);
        expect(expired, 1);
        harness.adapters.last.mode = 'offline';
        await expectLater(
          api.getItem('item'),
          throwsA(isA<EmbyApiException>()),
        );
      },
    );
  }

  for (final deleteAccount in [false, true]) {
    test(
      'late response cannot recreate cleared cache or write after session close (deleteAccount=$deleteAccount)',
      () async {
        final harness = await _Harness.create();
        addTearDown(harness.close);
        final api = harness.api();
        final gate = Completer<void>();
        final started = Completer<void>();
        harness.adapters.last
          ..gate = gate
          ..started = started;
        final pending = api.getItem('item');
        await started.future;
        if (deleteAccount) {
          await harness.database.deleteScopeData(api.scope);
        } else {
          await harness.cache.clear(api.scope);
        }
        gate.complete();
        await pending;
        expect((await harness.cache.usage(api.scope)).entries, 0);

        final secondGate = Completer<void>();
        final secondStarted = Completer<void>();
        harness.adapters.last
          ..gate = secondGate
          ..started = secondStarted;
        final late = api.getItem('item');
        final failure = expectLater(late, throwsA(anything));
        await secondStarted.future;
        await api.dispose();
        final b = harness.api(server: 'B');
        await b.getItem('item');
        secondGate.complete();
        await failure;
        expect((await harness.cache.usage(api.scope)).entries, 0);
        expect((await harness.cache.usage(b.scope)).entries, 1);
      },
    );
  }

  test('corrupt snapshot is an explicit cache miss', () async {
    final harness = await _Harness.create();
    addTearDown(harness.close);
    await harness.api().getItem('item');
    await harness.database.transaction(
      (db) => db.update('browse_snapshots', {'payload': '{broken'}),
    );
    await expectLater(
      harness.api(mode: 'offline').getItem('item'),
      throwsA(
        isA<EmbyApiException>().having(
          (e) => e.message,
          'message',
          contains('尚未缓存'),
        ),
      ),
    );
  });

  test(
    'storage failure keeps old snapshot and online response remains usable',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.close);
      final cache = _FailingCache(harness.database);
      harness.cache = cache;
      final api = harness.api();
      await api.getItem('item');
      cache.failWrites = true;
      harness.adapters.last.mode = 'updated';
      expect((await api.getItem('item')).name, 'Updated item');
      expect(api.browseState.storageUnavailable, isTrue);
      harness.adapters.last.mode = 'offline';
      expect((await api.getItem('item')).name, 'Saved item');
      cache.failWrites = false;
      harness.adapters.last.mode = 'updated';
      expect((await api.getItem('item')).name, 'Updated item');
      expect(api.browseState.storageUnavailable, isFalse);
    },
  );

  test('cache strips credentials and clear removes only one scope', () async {
    final harness = await _Harness.create();
    addTearDown(harness.close);
    final first = harness.api();
    final second = harness.api(user: 'other');
    await first.getItem('item');
    await second.getItem('item');
    final rows = await harness.database.read(
      (db) => db.query('browse_snapshots'),
    );
    final saved = rows.map((row) => row['payload']).join();
    expect(saved, isNot(contains('fixture-secret')));
    expect(saved, isNot(contains('AccessToken')));
    await harness.cache.clear(first.scope);
    expect((await harness.cache.usage(first.scope)).entries, 0);
    expect((await harness.cache.usage(second.scope)).entries, 1);
  });

  test(
    'bounded cache prunes old pages without touching downloaded records',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.close);
      final limited = BrowseCacheRepository(harness.database, maxEntries: 2);
      const scope = ServerScope(serverId: 'server', userId: 'user');
      final video = File('${harness.directory.path}/downloaded-video.mkv');
      await video.writeAsString('downloaded-media-fixture');
      await harness.database.transaction(
        (db) => db.insert('offline_items', {
          'server_id': scope.serverId,
          'user_id': scope.userId,
          'item_id': 'downloaded',
          'media_source_id': 'original',
          'metadata_json': '{}',
          'local_media_path': video.path,
          'completed_at_ms': 1,
        }),
      );
      for (var i = 0; i < 4; i++) {
        await limited.save(
          scope,
          'page-$i',
          {'Items': []},
          expectedGeneration: 0,
          isActive: () => true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect((await limited.usage(scope)).entries, 2);
      expect(await limited.load(scope, 'page-0'), isNull);
      expect(await limited.load(scope, 'page-3'), isNotNull);
      // Browsing eviction is confined to its own table.
      await limited.clear(scope);
      expect(
        await harness.database.read((db) => db.query('offline_items')),
        hasLength(1),
      );
      expect(await video.readAsString(), 'downloaded-media-fixture');
    },
  );

  testWidgets(
    'visited library remains in the original UI after offline recreation',
    (tester) async {
      final memory = _MemoryCache();
      final wire = _Adapter();
      final dio = Dio()..httpClientAdapter = wire;
      final api = EmbyApi(_session(), dio: dio, browseCache: memory);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LibraryScreen(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visited Movies'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await api.dispose();
      final offlineDio = Dio()
        ..httpClientAdapter = (_Adapter()..mode = 'offline');
      final offline = EmbyApi(_session(), dio: offlineDio, browseCache: memory);
      addTearDown(offline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                OfflineBrowseBanner(api: offline),
                Expanded(child: LibraryScreen(api: offline)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visited Movies'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-load-error')), findsNothing);
      expect(find.textContaining('服务器离线，信息未更新'), findsOneWidget);
      expect(find.textContaining('缓存时间：'), findsOneWidget);
    },
  );
}

class _Harness {
  _Harness(this.directory) {
    reopen();
  }
  final Directory directory;
  late LocalDatabase database;
  late BrowseCacheRepository cache;
  final apis = <EmbyApi>[];
  final adapters = <_Adapter>[];
  static Future<_Harness> create() async =>
      _Harness(await Directory.systemTemp.createTemp('browse-cache-test-'));
  void reopen() {
    database = LocalDatabase(
      factory: databaseFactoryFfi,
      pathResolver: () async => '${directory.path}/cache.db',
      singleInstance: false,
    );
    cache = BrowseCacheRepository(database);
  }

  EmbyApi api({
    String mode = 'online',
    String server = 'server',
    String user = 'user',
    FutureOr<void> Function()? onExpired,
  }) {
    final adapter = _Adapter()..mode = mode;
    adapters.add(adapter);
    final api = EmbyApi(
      _session(server: server, user: user),
      dio: Dio()..httpClientAdapter = adapter,
      browseCache: cache,
      onSessionExpired: onExpired,
    );
    apis.add(api);
    return api;
  }

  Future<void> close() async {
    for (final api in apis) {
      await api.dispose();
    }
    await database.close();
    await directory.delete(recursive: true);
  }
}

class _Adapter implements HttpClientAdapter {
  String mode = 'online';
  bool extraSeason = false;
  Completer<void>? gate;
  Completer<void>? started;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (started?.isCompleted == false) started!.complete();
    await gate?.future;
    if (mode == 'offline') {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketException('fixture offline'),
      );
    }
    final status = int.tryParse(mode) ?? 200;
    dynamic body;
    if (mode == 'malformed') {
      body = {};
    } else if (options.path.endsWith('/Views')) {
      body = {
        'Items': [
          {
            'Id': 'library',
            'Name': 'Visited Movies',
            'Type': 'CollectionFolder',
          },
        ],
      };
    } else if (options.path.endsWith('/Items/item')) {
      body = {
        'Id': mode == 'wrong-item' ? 'unrelated' : 'item',
        'Name': mode == 'updated' ? 'Updated item' : 'Saved item',
        'Type': 'Movie',
        'Overview': 'Saved overview',
        'AccessToken': 'fixture-secret',
        'MediaSources': [
          {
            'Id': 'source',
            'MediaStreams': [
              {
                'Type': 'Subtitle',
                'DeliveryUrl':
                    '/Videos/item/source/Subtitles/1/Stream.srt?api_key=fixture-secret',
              },
            ],
          },
        ],
      };
    } else if (options.path.endsWith('/Items/series')) {
      body = {'Id': 'series', 'Name': 'Saved series', 'Type': 'Series'};
    } else if (options.path.endsWith('/Seasons')) {
      body = {
        'Items': [
          {'Id': 'season', 'Name': 'Season 1', 'Type': 'Season'},
          if (extraSeason)
            {'Id': 'season-2', 'Name': 'Season 2', 'Type': 'Season'},
        ],
      };
    } else if (options.path.endsWith('/Episodes')) {
      body = {
        'Items': [
          {'Id': 'episode', 'Name': 'Episode 1', 'Type': 'Episode'},
        ],
      };
    } else {
      final items = [
        {'Id': 'item', 'Name': 'Saved item', 'Type': 'Movie'},
      ];
      body = options.path.endsWith('/Latest')
          ? items
          : {'Items': items, 'TotalRecordCount': 100};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryCache extends BrowseCacheRepository {
  _MemoryCache() : super(LocalDatabase());
  final values = <String, BrowseSnapshot>{};
  @override
  Future<BrowseSnapshot?> load(ServerScope scope, String key) async =>
      values[key];
  @override
  Future<void> save(
    ServerScope scope,
    String key,
    dynamic data, {
    required int expectedGeneration,
    required bool Function() isActive,
  }) async {
    values[key] = BrowseSnapshot(data, DateTime.utc(2026, 10, 14));
  }
}

class _FailingCache extends BrowseCacheRepository {
  _FailingCache(super.database);
  bool failWrites = false;
  @override
  Future<void> save(
    ServerScope scope,
    String key,
    dynamic data, {
    required int expectedGeneration,
    required bool Function() isActive,
  }) {
    if (failWrites) {
      throw const FileSystemException('fixture storage unavailable');
    }
    return super.save(
      scope,
      key,
      data,
      expectedGeneration: expectedGeneration,
      isActive: isActive,
    );
  }
}

EmbySession _session({String server = 'server', String user = 'user'}) =>
    EmbySession(
      serverUrl: 'https://fixture.invalid',
      serverName: 'Fixture',
      serverId: server,
      userId: user,
      username: 'Fixture',
      accessToken: 'fixture-token',
      deviceId: 'fixture-device',
    );

class _DeferredDetailApi extends EmbyApi {
  _DeferredDetailApi() : super(_session(), dio: Dio());
  final responses = <Completer<EmbyItem>>[];
  @override
  Future<EmbyItem> getItem(String id) {
    final result = Completer<EmbyItem>();
    responses.add(result);
    return result.future;
  }
}
