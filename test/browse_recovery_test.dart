import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/browse_cache.dart';
import 'package:emby_my_client/data/browse_refresh_binding.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/downloads/download_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/ui/offline_playback_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'older same-key success cannot replace the newer cached snapshot',
    () async {
      final cache = _MemoryCache();
      final wire = _QueuedAdapter();
      final api = EmbyApi(
        _session,
        browseCache: cache,
        dio: Dio()..httpClientAdapter = wire,
      );
      addTearDown(api.dispose);
      final old = api.getItem('item');
      await wire.waitFor(1);
      final fresh = api.getItem('item');
      await wire.waitFor(2);
      wire.succeed(1, 'item', 'New value');
      expect((await fresh).name, 'New value');
      wire.succeed(0, 'item', 'Old value');
      await old;
      final offline = api.getItem('item');
      await wire.waitFor(3);
      wire.fail(2);
      expect((await offline).name, 'New value');
    },
  );

  test('older success cannot hide a newer disconnected request', () async {
    final wire = _QueuedAdapter();
    final api = EmbyApi(
      _session,
      browseCache: _MemoryCache(),
      dio: Dio()..httpClientAdapter = wire,
    );
    addTearDown(api.dispose);
    final old = api.getItem('old');
    await wire.waitFor(1);
    final recent = api.getItem('recent');
    final failure = expectLater(recent, throwsA(isA<EmbyApiException>()));
    await wire.waitFor(2);
    wire.fail(1);
    await failure;
    wire.succeed(0, 'old', 'Old value');
    await old;
    expect(api.browseState.offline, isTrue);
    expect(api.browseState.missingPage, isTrue);
  });

  test(
    'older failed request cannot mark a newer same-key response stale',
    () async {
      final wire = _QueuedAdapter();
      final api = EmbyApi(
        _session,
        browseCache: _MemoryCache(),
        dio: Dio()..httpClientAdapter = wire,
      );
      addTearDown(api.dispose);
      final old = api.getItem('item');
      final failure = expectLater(old, throwsA(isA<EmbyApiException>()));
      await wire.waitFor(1);
      final fresh = api.getItem('item');
      await wire.waitFor(2);
      wire.succeed(1, 'item', 'New value');
      await fresh;
      wire.fail(0);
      await failure;
      expect(api.browseState.offline, isFalse);
      expect(api.browseState.hasStalePages, isFalse);
      expect(api.browseState.missingPage, isFalse);
    },
  );

  test('older disconnected result cannot overwrite newer online evidence', () {
    final state = BrowseCacheState();
    addTearDown(state.dispose);
    final old = state.beginRequest();
    final recent = state.beginRequest();
    state.online('new', request: recent);
    state.cached(
      'old',
      BrowseSnapshot({}, DateTime.utc(2026)),
      disconnected: true,
      request: old,
    );
    expect(state.offline, isFalse);
    expect(state.hasStalePages, isTrue);
    state.authFailed();
    state.online('new', request: state.beginRequest());
    expect(state.authenticationRequired, isTrue);
  });

  test(
    'websocket connection requests refresh without claiming cached data is current',
    () async {
      final socket = _Socket();
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {},
                ),
              );
            },
          ),
        );
      final api = EmbyApi(
        _session,
        dio: dio,
        realtimeConnector: (_) async => socket,
      );
      addTearDown(api.dispose);
      api.browseState.cached(
        'item',
        BrowseSnapshot({}, DateTime.utc(2026)),
        disconnected: true,
      );
      await api.realtime.start();
      expect(api.browseState.recoveryRevision, 1);
      expect(api.browseState.offline, isTrue);
      expect(api.browseState.hasStalePages, isTrue);
    },
  );

  testWidgets(
    'offline retry survives failure, pauses in background and refreshes on resume',
    (tester) async {
      final state = BrowseCacheState();
      var calls = 0;
      final binding = BrowseRefreshBinding(
        state: state,
        retryDelay: const Duration(seconds: 1),
        debounce: const Duration(milliseconds: 10),
        refresh: () async {
          calls++;
          if (calls == 1) throw StateError('fixture failure');
        },
      );
      state.cached('page', null, disconnected: true);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      binding.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 3));
      expect(calls, 2);
      binding.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 10));
      expect(calls, 3);
      binding.dispose();
      state.requestRecovery();
      await tester.pump(const Duration(seconds: 3));
      expect(calls, 3);
      state.dispose();
    },
  );

  testWidgets(
    'reconnect signals debounce and auth failure cancels automatic retries',
    (tester) async {
      final state = BrowseCacheState();
      var calls = 0;
      final binding = BrowseRefreshBinding(
        state: state,
        retryDelay: const Duration(seconds: 1),
        debounce: const Duration(milliseconds: 10),
        refresh: () async {
          calls++;
        },
      );
      state.cached('page', null, disconnected: true);
      state.requestRecovery();
      state.requestRecovery();
      await tester.pump(const Duration(milliseconds: 10));
      expect(calls, 1);
      state.authFailed();
      await tester.pump(const Duration(seconds: 3));
      expect(calls, 1);
      binding.dispose();
      state.dispose();
    },
  );

  for (final sameScope in [false, true]) {
    testWidgets(
      'explicit local playback cannot fall back online (matching scope: $sameScope)',
      (tester) async {
        final api = EmbyApi(_session, dio: Dio());
        addTearDown(api.dispose);
        final downloads = _UnavailableDownloads(
          sameScope
              ? api.scope
              : const ServerScope(serverId: 'other', userId: 'user'),
        );
        bool? handled;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    handled = await openCachedPlayback(
                      context,
                      api: api,
                      downloads: downloads,
                      item: _item,
                      requireLocal: true,
                    );
                  },
                  child: const Text('play local'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('play local'));
        await tester.pump();
        expect(handled, isTrue);
        expect(downloads.calls, sameScope ? 1 : 0);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('play local'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'undownloaded offline video is handled without pushing a player',
    (tester) async {
      final api = EmbyApi(_session, dio: Dio());
      addTearDown(api.dispose);
      api.browseState.cached('page', null, disconnected: true);
      bool? handled;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  handled = await openCachedPlayback(
                    context,
                    api: api,
                    downloads: null,
                    item: _item,
                  );
                },
                child: const Text('play'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('play'));
      await tester.pump();
      expect(handled, isTrue);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('play'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
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
    if (isActive()) values[key] = BrowseSnapshot(data, DateTime.utc(2026));
  }
}

class _QueuedAdapter implements HttpClientAdapter {
  final requests =
      <({RequestOptions options, Completer<ResponseBody> response})>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final response = Completer<ResponseBody>();
    requests.add((options: options, response: response));
    return response.future;
  }

  Future<void> waitFor(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void succeed(int index, String id, String name) =>
      requests[index].response.complete(
        ResponseBody.fromString(
          jsonEncode({'Id': id, 'Name': name, 'Type': 'Movie'}),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        ),
      );
  void fail(int index) => requests[index].response.completeError(
    DioException(
      requestOptions: requests[index].options,
      type: DioExceptionType.connectionError,
    ),
  );
  @override
  void close({bool force = false}) {}
}

class _Socket implements EmbySocket {
  final controller = StreamController<dynamic>.broadcast();
  @override
  Stream<dynamic> get messages => controller.stream;
  @override
  void add(String data) {}
  @override
  Future<void> close() => controller.close();
}

const _session = EmbySession(
  serverUrl: 'https://fixture.invalid',
  serverName: 'Fixture',
  serverId: 'server',
  userId: 'user',
  username: 'Fixture',
  accessToken: 'fixture-token',
  deviceId: 'fixture-device',
);
final _item = EmbyItem.fromJson({
  'Id': 'item',
  'Name': 'Fixture video',
  'Type': 'Movie',
});

class _UnavailableDownloads extends Fake implements DownloadService {
  _UnavailableDownloads(this.scope);
  @override
  final ServerScope scope;
  int calls = 0;
  @override
  Future<OfflineMediaItem?> offlineItem(String itemId) async {
    calls++;
    throw StateError('fixture unavailable local file');
  }
}
