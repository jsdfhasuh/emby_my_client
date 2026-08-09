import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/account_data_cleanup.dart';
import 'package:emby_my_client/data/client_registry.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_local_media_scan_cache.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sign out waits for the active scan before disposing the API', () async {
    final fixture = _ControllerFixture();
    addTearDown(fixture.dispose);
    await fixture.signIn();
    final response = Completer<EmbyItemPage>();
    final service = fixture.controller.libraryScanService!;
    final key = _key(fixture.controller.scope!, 'sign-out-library');
    service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) => response.future,
      ),
    );
    await _waitForStatus(service, key, LibraryScanStatus.scanning);

    var signedOut = false;
    final operation = fixture.controller.signOut().then(
      (_) => signedOut = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(signedOut, isFalse);
    expect(fixture.disposedApis, 0);

    response.complete(const EmbyItemPage(items: [], totalRecordCount: 0));
    await operation;
    expect(signedOut, isTrue);
    expect(fixture.disposedApis, 1);
    expect(fixture.controller.libraryScanService, isNull);
    expect(service.debugCacheKeys, isEmpty);
    expect(service.debugLoaderCount, 0);
    expect(service.debugPendingCount, 0);
    expect(service.debugRetryWaitCount, 0);
  });

  test('controller dispose waits for scans before disposing clients', () async {
    final fixture = _ControllerFixture();
    await fixture.signIn();
    final response = Completer<EmbyItemPage>();
    final service = fixture.controller.libraryScanService!;
    final key = _key(fixture.controller.scope!, 'dispose-library');
    service.ensureScan(
      LibraryLocalMediaScanRequest(
        key: key,
        loadPage: ({required startIndex, required limit}) => response.future,
      ),
    );
    await _waitForStatus(service, key, LibraryScanStatus.scanning);

    fixture.controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.disposedApis, 0);

    response.complete(const EmbyItemPage(items: [], totalRecordCount: 0));
    await _waitUntil(() => fixture.disposedApis == 1);
    expect(fixture.controller.libraryScanService, isNull);
  });

  test('failed account cleanup restores a fresh scan service', () async {
    final fixture = _ControllerFixture(
      accountDataCleanup: _FailingAccountDataCleanup(),
    );
    addTearDown(fixture.dispose);
    await fixture.signIn();
    final original = fixture.controller.libraryScanService;

    await expectLater(
      fixture.controller.deleteCurrentAccountData(),
      throwsStateError,
    );

    expect(fixture.controller.isSignedIn, isTrue);
    expect(fixture.controller.libraryScanService, isNotNull);
    expect(fixture.controller.libraryScanService, isNot(same(original)));
  });

  test(
    'app pause and resume continue scanning from the completed raw page',
    () async {
      final fixture = _ControllerFixture();
      addTearDown(fixture.dispose);
      await fixture.signIn();
      final firstPage = Completer<EmbyItemPage>();
      final starts = <int>[];
      final service = fixture.controller.libraryScanService!;
      final key = _key(fixture.controller.scope!, 'foreground-library');
      service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) {
            starts.add(startIndex);
            if (startIndex == 0) return firstPage.future;
            return Future.value(
              EmbyItemPage(
                items: [_scanItem('second')],
                rawItemCount: 1,
                totalRecordCount: 2,
              ),
            );
          },
        ),
      );
      await _waitForStatus(service, key, LibraryScanStatus.scanning);

      fixture.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      firstPage.complete(
        EmbyItemPage(
          items: [_scanItem('first')],
          rawItemCount: 1,
          totalRecordCount: 2,
        ),
      );
      await _waitUntil(
        () =>
            service.snapshotFor(key)?.status == LibraryScanStatus.paused &&
            service.snapshotFor(key)?.rawCursor == 1,
      );
      expect(starts, [0]);

      fixture.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _waitUntil(() => service.snapshotFor(key)?.complete ?? false);

      expect(service.snapshotFor(key)?.rawCursor, 2);
      expect(starts, [0, 1]);
    },
  );

  test(
    'account deletion waits for scanning before cleanup and API disposal',
    () async {
      final cleanup = _SuccessfulAccountDataCleanup();
      final fixture = _ControllerFixture(accountDataCleanup: cleanup);
      addTearDown(fixture.dispose);
      await fixture.signIn();
      final response = Completer<EmbyItemPage>();
      final service = fixture.controller.libraryScanService!;
      final key = _key(fixture.controller.scope!, 'delete-library');
      service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) => response.future,
        ),
      );
      await _waitForStatus(service, key, LibraryScanStatus.scanning);

      var deletionCompleted = false;
      final deletion = fixture.controller.deleteCurrentAccountData().then(
        (_) => deletionCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(deletionCompleted, isFalse);
      expect(cleanup.calls, 0);
      expect(fixture.disposedApis, 0);

      response.complete(const EmbyItemPage(items: [], totalRecordCount: 0));
      await deletion;

      expect(deletionCompleted, isTrue);
      expect(cleanup.calls, 1);
      expect(fixture.disposedApis, 1);
      expect(fixture.controller.libraryScanService, isNull);
      expect(fixture.controller.isSignedIn, isFalse);
    },
  );

  test(
    'a 401 expires the session only after the scan request settles',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      final session = EmbySession(
        serverUrl: 'http://${server.address.address}:${server.port}',
        serverName: _session.serverName,
        serverId: 'expiry-server',
        userId: _session.userId,
        username: _session.username,
        accessToken: _session.accessToken,
        deviceId: _session.deviceId,
      );
      var disposedApis = 0;
      final clients = ClientRegistry<EmbyApi>(
        disposeClient: (api) async {
          disposedApis++;
          await api.dispose();
        },
      );
      final controller = AppController(
        store: SessionStore(sessionStorage: _MemorySessionStorage()),
        clients: clients,
        capabilities: PlatformCapabilities.ipad,
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
        authenticator:
            ({
              required serverUrl,
              required username,
              required password,
              required deviceId,
              required deviceName,
            }) async => session,
      );
      addTearDown(controller.dispose);
      await controller.signIn(
        serverUrl: session.serverUrl,
        username: session.username,
        password: 'fixture-password',
      );
      final service = controller.libraryScanService!;
      final key = _key(controller.scope!, 'expiry-library');
      service.ensureScan(
        LibraryLocalMediaScanRequest(
          key: key,
          loadPage: ({required startIndex, required limit}) =>
              controller.api.getLibraryMediaItems(
                parentId: 'expiry-library',
                startIndex: startIndex,
                limit: limit,
              ),
        ),
      );

      await _waitUntil(() => !controller.isSignedIn);
      expect(controller.libraryScanService, isNull);
      expect(disposedApis, 1);
    },
  );
}

class _ControllerFixture {
  _ControllerFixture({AccountDataCleanup? accountDataCleanup})
    : storage = _MemorySessionStorage() {
    clients = ClientRegistry<EmbyApi>(
      disposeClient: (api) async {
        disposedApis++;
        await api.dispose();
      },
    );
    controller = AppController(
      store: SessionStore(sessionStorage: storage),
      clients: clients,
      capabilities: PlatformCapabilities.ipad,
      libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
      accountDataCleanup: accountDataCleanup,
      authenticator:
          ({
            required serverUrl,
            required username,
            required password,
            required deviceId,
            required deviceName,
          }) async => _session,
      apiFactory: (session, scope) {
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{},
                ),
              ),
            ),
          );
        return EmbyApi(
          session,
          dio: dio,
          realtimeConnector: (_) async => throw StateError('realtime disabled'),
        );
      },
      libraryScanServiceFactory: (api, scope) =>
          LibraryLocalMediaScanService(api: api, scope: scope),
    );
  }

  final _MemorySessionStorage storage;
  late final ClientRegistry<EmbyApi> clients;
  late final AppController controller;
  int disposedApis = 0;

  Future<void> signIn() => controller.signIn(
    serverUrl: _session.serverUrl,
    username: _session.username,
    password: 'fixture-password',
  );

  Future<void> dispose() async {
    if (controller.isSignedIn) await controller.signOut();
    controller.dispose();
  }
}

class _FailingAccountDataCleanup implements AccountDataCleanup {
  @override
  Future<void> delete({
    required ServerScope scope,
    required EmbySession session,
  }) async {
    throw StateError('private cleanup fixture');
  }
}

class _SuccessfulAccountDataCleanup implements AccountDataCleanup {
  int calls = 0;

  @override
  Future<void> delete({
    required ServerScope scope,
    required EmbySession session,
  }) async {
    calls++;
  }
}

class _MemorySessionStorage implements SessionStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
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

Future<void> _waitForStatus(
  LibraryLocalMediaScanService service,
  LibraryScanKey key,
  LibraryScanStatus status,
) async {
  await _waitUntil(() => service.snapshotFor(key)?.status == status);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for controller lifecycle state');
}

EmbyItem _scanItem(String id) => EmbyItem(
  id: id,
  name: id,
  type: 'Video',
  path: '$id.mp4',
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
