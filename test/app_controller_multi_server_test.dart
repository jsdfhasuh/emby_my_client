import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/accounts/server_account.dart';
import 'package:emby_my_client/accounts/server_account_repository.dart';
import 'package:emby_my_client/accounts/server_account_store.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/data/account_data_cleanup.dart';
import 'package:emby_my_client/data/client_registry.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/downloads/download_repository.dart';
import 'package:emby_my_client/downloads/download_service.dart';
import 'package:emby_my_client/library/library_local_media_scan_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('initialization restores the last selected server account', () async {
    final harness = await _Harness.create(
      seedSessions: const [_sessionA, _sessionB],
      currentServerId: 'server-b',
    );
    addTearDown(harness.dispose);

    expect(harness.controller.session?.serverId, 'server-b');
    expect(harness.controller.currentAccountId, harness.accountB.accountId);
    expect(harness.tracker.activeApis, 1);
    expect(harness.tracker.maxActiveApis, 1);
    expect(harness.tracker.activeDownloads, 1);
  });

  test(
    'switch waits for A shutdown before creating B and keeps one workspace',
    () async {
      final harness = await _Harness.create(
        seedSessions: const [_sessionA, _sessionB],
      );
      addTearDown(harness.dispose);
      harness.tracker.events.clear();
      final disposeGate = Completer<void>();
      harness.tracker.apiDisposeGates['server-a'] = disposeGate;

      var completed = false;
      final switching = harness.controller
          .switchAccount(harness.accountB.accountId)
          .whenComplete(() => completed = true);
      await _waitFor(
        () => harness.tracker.events.contains('api:dispose:start:server-a'),
      );

      expect(harness.controller.isSwitchingServer, isTrue);
      expect(completed, isFalse);
      expect(harness.tracker.events, isNot(contains('api:create:server-b')));
      expect(harness.tracker.activeApis, 1);

      disposeGate.complete();
      await switching;

      expect(harness.controller.session?.serverId, 'server-b');
      expect(harness.controller.currentAccountId, harness.accountB.accountId);
      expect(harness.controller.isSwitchingServer, isFalse);
      expect(harness.tracker.activeApis, 1);
      expect(harness.tracker.maxActiveApis, 1);
      expect(harness.tracker.activeDownloads, 1);
      expect(
        _eventIndex(harness.tracker.events, 'scan:stop:server-a'),
        lessThan(_eventIndex(harness.tracker.events, 'api:create:server-b')),
      );
      expect(
        _eventIndex(harness.tracker.events, 'download:shutdown:server-a'),
        lessThan(_eventIndex(harness.tracker.events, 'api:create:server-b')),
      );
      expect(
        _eventIndex(harness.tracker.events, 'api:dispose:end:server-a'),
        lessThan(_eventIndex(harness.tracker.events, 'api:create:server-b')),
      );
    },
  );

  test('failed switch recreates A without selecting or leaking B', () async {
    final harness = await _Harness.create(
      seedSessions: const [_sessionA, _sessionB],
    );
    addTearDown(harness.dispose);
    harness.tracker.events.clear();
    harness.tracker.failApiCreationFor.add('server-b');

    await expectLater(
      harness.controller.switchAccount(harness.accountB.accountId),
      throwsA(isA<StateError>()),
    );

    expect(harness.controller.session?.serverId, 'server-a');
    expect(harness.controller.currentAccountId, harness.accountA.accountId);
    expect(harness.controller.serverAccounts, hasLength(2));
    expect(harness.tracker.activeApis, 1);
    expect(harness.tracker.maxActiveApis, 1);
    expect(harness.tracker.events, contains('api:create:server-b'));
    expect(
      harness.tracker.events.where((event) => event == 'api:create:server-a'),
      hasLength(1),
    );
  });

  test('adding B preserves A and activates the new account', () async {
    final harness = await _Harness.create(
      seedSessions: const [_sessionA],
      authenticationSessions: const [_sessionA, _sessionB],
    );
    addTearDown(harness.dispose);

    await harness.controller.addAccount(
      serverUrl: _sessionB.serverUrl,
      username: _sessionB.username,
      password: 'fixture-password',
    );

    expect(harness.controller.serverAccounts, hasLength(2));
    expect(harness.controller.session?.serverId, 'server-b');
    expect(harness.tracker.activeApis, 1);
    expect(harness.tracker.maxActiveApis, 1);
  });

  test('removing a non-current account leaves A workspace untouched', () async {
    final harness = await _Harness.create(
      seedSessions: const [_sessionA, _sessionB],
    );
    addTearDown(harness.dispose);
    harness.tracker.events.clear();

    await harness.controller.removeAccount(harness.accountB.accountId);

    expect(harness.controller.serverAccounts, [hasAccountId(harness.accountA)]);
    expect(harness.controller.session?.serverId, 'server-a');
    expect(harness.tracker.activeApis, 1);
    expect(
      harness.tracker.events.where((event) => event.startsWith('api:dispose')),
      isEmpty,
    );
    expect(
      harness.storage.values,
      isNot(
        contains(
          'emby_server_account_session_v1_${harness.accountB.accountId}',
        ),
      ),
    );
  });

  test(
    'removing non-current B can delete only its scoped local data',
    () async {
      final cleanup = _RecordingAccountDataCleanup();
      final harness = await _Harness.create(
        seedSessions: const [_sessionA, _sessionB],
        accountDataCleanup: cleanup,
      );
      addTearDown(harness.dispose);
      harness.tracker.events.clear();

      await harness.controller.removeAccount(
        harness.accountB.accountId,
        deleteLocalData: true,
      );

      expect(cleanup.calls, [
        (scope: harness.accountB.scope, session: _sessionB),
      ]);
      expect(harness.controller.session?.serverId, 'server-a');
      expect(harness.tracker.activeApis, 1);
      expect(
        harness.tracker.events.where(
          (event) => event.startsWith('api:dispose'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'failed non-current removal does not delete its scoped local data',
    () async {
      final cleanup = _RecordingAccountDataCleanup();
      final harness = await _Harness.create(
        seedSessions: const [_sessionA, _sessionB],
        accountDataCleanup: cleanup,
      );
      addTearDown(harness.dispose);
      harness.storage.failNextIndexWrite = true;

      await expectLater(
        harness.controller.removeAccount(
          harness.accountB.accountId,
          deleteLocalData: true,
        ),
        throwsA(isA<SecureStorageFailure>()),
      );

      expect(cleanup.calls, isEmpty);
      expect(harness.controller.serverAccounts, hasLength(2));
      expect(harness.controller.session?.serverId, 'server-a');
      expect(harness.tracker.activeApis, 1);
    },
  );

  test(
    'removing the current account activates the next saved server',
    () async {
      final harness = await _Harness.create(
        seedSessions: const [_sessionA, _sessionB],
      );
      addTearDown(harness.dispose);

      await harness.controller.removeAccount(harness.accountA.accountId);

      expect(harness.controller.serverAccounts, [
        hasAccountId(harness.accountB),
      ]);
      expect(harness.controller.session?.serverId, 'server-b');
      expect(harness.controller.currentAccountId, harness.accountB.accountId);
      expect(harness.tracker.activeApis, 1);
      expect(harness.tracker.maxActiveApis, 1);
    },
  );

  test(
    'removing current A deletes its local data before activating B',
    () async {
      final cleanup = _RecordingAccountDataCleanup();
      final harness = await _Harness.create(
        seedSessions: const [_sessionA, _sessionB],
        accountDataCleanup: cleanup,
      );
      addTearDown(harness.dispose);
      harness.tracker.events.clear();
      cleanup.onDelete = (scope, session) async {
        expect(harness.tracker.activeDownloads, 0);
        expect(harness.tracker.activeApis, 1);
        harness.tracker.events.add('data:delete:${session.serverId}');
      };

      await harness.controller.removeAccount(
        harness.accountA.accountId,
        deleteLocalData: true,
      );

      expect(cleanup.calls, [
        (scope: harness.accountA.scope, session: _sessionA),
      ]);
      expect(harness.controller.session?.serverId, 'server-b');
      expect(harness.tracker.maxActiveApis, 1);
      expect(
        _eventIndex(harness.tracker.events, 'data:delete:server-a'),
        lessThan(
          _eventIndex(harness.tracker.events, 'api:dispose:start:server-a'),
        ),
      );
      expect(
        _eventIndex(harness.tracker.events, 'api:dispose:end:server-a'),
        lessThan(_eventIndex(harness.tracker.events, 'api:create:server-b')),
      );
    },
  );

  test(
    'failed current removal restores A without deleting its local data',
    () async {
      final cleanup = _RecordingAccountDataCleanup();
      final harness = await _Harness.create(
        seedSessions: const [_sessionA, _sessionB],
        accountDataCleanup: cleanup,
      );
      addTearDown(harness.dispose);
      harness.storage.failNextIndexWrite = true;

      await expectLater(
        harness.controller.removeAccount(
          harness.accountA.accountId,
          deleteLocalData: true,
        ),
        throwsA(isA<SecureStorageFailure>()),
      );

      expect(cleanup.calls, isEmpty);
      expect(harness.controller.serverAccounts, hasLength(2));
      expect(harness.controller.session?.serverId, 'server-a');
      expect(harness.controller.currentAccountId, harness.accountA.accountId);
      expect(harness.tracker.activeApis, 1);
      expect(harness.tracker.activeDownloads, 1);
    },
  );

  test('signing out A removes it and continues with B', () async {
    final harness = await _Harness.create(
      seedSessions: const [_sessionA, _sessionB],
    );
    addTearDown(harness.dispose);

    await harness.controller.signOut();

    expect(harness.controller.serverAccounts, [hasAccountId(harness.accountB)]);
    expect(harness.controller.session?.serverId, 'server-b');
    expect(harness.tracker.activeApis, 1);
    expect(harness.tracker.maxActiveApis, 1);
  });

  test('a 401 activates B even when persisting A expiration fails', () async {
    final realHttp = _RealHttpOverrides();
    await HttpOverrides.runZoned(() async {
      final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverA.close(force: true);
        await serverB.close(force: true);
      });
      serverA.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      serverB.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write('{"Items":[]}');
        }
        await request.response.close();
      });
      final sessionA = _sessionForServer(
        _sessionA,
        'http://${serverA.address.address}:${serverA.port}',
      );
      final sessionB = _sessionForServer(
        _sessionB,
        'http://${serverB.address.address}:${serverB.port}',
      );
      final storage = _MemorySessionStorage()
        ..values['emby_device_id_v1'] = 'device-1';
      final store = SessionStore(sessionStorage: storage);
      final accounts = ServerAccountRepository(
        store: ServerAccountStore(store),
      );
      await accounts.initialize();
      final accountA = await accounts.upsert(sessionA, makeCurrent: true);
      final accountB = await accounts.upsert(sessionB);
      final database = _database();
      final tracker = _ResourceTracker(database);
      final controller = AppController(
        store: store,
        database: database,
        clients: ClientRegistry<EmbyApi>(disposeClient: (api) => api.dispose()),
        serverAccountRepository: accounts,
        capabilities: PlatformCapabilities.ipad,
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
        playbackSettingsRepository: PlaybackSettingsRepository(
          storage: _MemoryPlaybackSettingsStorage(),
        ),
        libraryScanServiceFactory: tracker.createScan,
        downloadServiceFactory: tracker.createDownload,
      );
      addTearDown(() async {
        controller.dispose();
        await _waitFor(() => tracker.activeDownloads == 0);
      });
      await controller.initialize();
      storage.failIndexWrites = true;

      await expectLater(
        controller.api.getLibraryFolders(parentId: 'root'),
        throwsA(
          isA<EmbyApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.unauthorized,
          ),
        ),
      );
      await _waitFor(
        () =>
            controller.currentAccountId == accountB.accountId &&
            controller.session?.serverId == 'server-b' &&
            !controller.isSwitchingServer,
      );

      expect(controller.serverAccounts, hasLength(2));
      expect(
        controller.serverAccounts
            .firstWhere((account) => account.accountId == accountA.accountId)
            .connectionState,
        ServerConnectionState.authenticationRequired,
      );
      expect(
        controller.serverAccounts
            .firstWhere((account) => account.accountId == accountB.accountId)
            .connectionState,
        isNot(ServerConnectionState.authenticationRequired),
      );
    }, createHttpClient: realHttp.createHttpClient);
  });
}

Matcher hasAccountId(ServerAccount expected) => isA<ServerAccount>().having(
  (account) => account.accountId,
  'accountId',
  expected.accountId,
);

int _eventIndex(List<String> events, String event) {
  final index = events.indexOf(event);
  expect(index, isNonNegative, reason: 'Missing event $event in $events');
  return index;
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for test condition');
}

LocalDatabase _database() => LocalDatabase(
  factory: databaseFactoryFfi,
  pathResolver: () async => inMemoryDatabasePath,
  singleInstance: false,
);

class _Harness {
  _Harness({
    required this.controller,
    required this.storage,
    required this.accounts,
    required this.tracker,
    required this.accountA,
    required this.accountB,
  });

  final AppController controller;
  final _MemorySessionStorage storage;
  final ServerAccountRepository accounts;
  final _ResourceTracker tracker;
  final ServerAccount accountA;
  final ServerAccount accountB;

  static Future<_Harness> create({
    required List<EmbySession> seedSessions,
    List<EmbySession>? authenticationSessions,
    String currentServerId = 'server-a',
    AccountDataCleanup? accountDataCleanup,
  }) async {
    final storage = _MemorySessionStorage()
      ..values['emby_device_id_v1'] = 'device-1';
    final store = SessionStore(sessionStorage: storage);
    final accounts = ServerAccountRepository(store: ServerAccountStore(store));
    await accounts.initialize();
    final seeded = <String, ServerAccount>{};
    for (final session in seedSessions) {
      seeded[session.serverId] = await accounts.upsert(
        session,
        makeCurrent: session.serverId == currentServerId,
      );
    }
    final current = seeded[currentServerId];
    if (current != null && accounts.currentAccountId != current.accountId) {
      await accounts.setCurrent(current.accountId);
    }
    final database = _database();
    final tracker = _ResourceTracker(database);
    final knownSessions = authenticationSessions ?? seedSessions;
    final clients = ClientRegistry<EmbyApi>(disposeClient: tracker.disposeApi);
    final controller = AppController(
      store: store,
      database: database,
      clients: clients,
      serverAccountRepository: accounts,
      capabilities: PlatformCapabilities.ipad,
      libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
      playbackSettingsRepository: PlaybackSettingsRepository(
        storage: _MemoryPlaybackSettingsStorage(),
      ),
      accountDataCleanup: accountDataCleanup,
      authenticator:
          ({
            required serverUrl,
            required username,
            required password,
            required deviceId,
            required deviceName,
          }) async => knownSessions.firstWhere(
            (session) => session.serverUrl == serverUrl,
          ),
      apiFactory: tracker.createApi,
      libraryScanServiceFactory: tracker.createScan,
      downloadServiceFactory: tracker.createDownload,
    );
    await controller.initialize();
    final accountA =
        accounts.accountForScope(ServerScope.fromSession(_sessionA)) ??
        ServerAccount(
          accountId: ServerAccountStore.accountIdForSession(_sessionA),
          session: _sessionA,
        );
    final accountB =
        accounts.accountForScope(ServerScope.fromSession(_sessionB)) ??
        ServerAccount(
          accountId: ServerAccountStore.accountIdForSession(_sessionB),
          session: _sessionB,
        );
    return _Harness(
      controller: controller,
      storage: storage,
      accounts: accounts,
      tracker: tracker,
      accountA: accountA,
      accountB: accountB,
    );
  }

  Future<void> dispose() async {
    controller.dispose();
    await _waitFor(
      () => tracker.activeApis == 0 && tracker.activeDownloads == 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _ResourceTracker {
  _ResourceTracker(this.database);

  final LocalDatabase database;
  final List<String> events = [];
  final Map<String, Completer<void>> apiDisposeGates = {};
  final Set<String> failApiCreationFor = {};
  int activeApis = 0;
  int maxActiveApis = 0;
  int activeDownloads = 0;

  EmbyApi createApi(EmbySession session, ServerScope scope) {
    final id = session.serverId;
    events.add('api:create:$id');
    if (failApiCreationFor.contains(id)) {
      throw StateError('fixture API creation failure for $id');
    }
    activeApis++;
    if (activeApis > maxActiveApis) maxActiveApis = activeApis;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: HttpStatus.ok,
              data: const <String, dynamic>{'Items': <dynamic>[]},
            ),
          ),
        ),
      );
    return EmbyApi(
      session,
      dio: dio,
      realtimeConnector: (_) async => _SilentSocket(),
    );
  }

  Future<void> disposeApi(EmbyApi api) async {
    final id = api.session.serverId;
    events.add('api:dispose:start:$id');
    final gate = apiDisposeGates[id];
    if (gate != null) await gate.future;
    await api.dispose();
    activeApis--;
    events.add('api:dispose:end:$id');
  }

  LibraryLocalMediaScanService createScan(EmbyApi api, ServerScope scope) {
    events.add('scan:start:${api.session.serverId}');
    return _TrackingScanService(api: api, scope: scope, tracker: this);
  }

  DownloadService createDownload(EmbyApi api, ServerScope scope) =>
      _TrackingDownloadService(
        api: api,
        scope: scope,
        tracker: this,
        database: database,
      );
}

class _TrackingScanService extends LibraryLocalMediaScanService {
  _TrackingScanService({
    required super.api,
    required super.scope,
    required this.tracker,
  });

  final _ResourceTracker tracker;

  @override
  Future<void> cancelAll() async {
    tracker.events.add('scan:stop:${api.session.serverId}');
    await super.cancelAll();
  }
}

class _TrackingDownloadService extends DownloadService {
  _TrackingDownloadService({
    required super.api,
    required super.scope,
    required this.tracker,
    required LocalDatabase database,
  }) : super(repository: DownloadRepository(database));

  final _ResourceTracker tracker;
  bool _active = false;

  @override
  Future<void> initialize() async {
    if (_active) return;
    _active = true;
    tracker.activeDownloads++;
    tracker.events.add('download:start:${api.session.serverId}');
  }

  @override
  Future<bool> stopExecutor() async {
    tracker.events.add('download:stop-executor:${api.session.serverId}');
    return true;
  }

  @override
  Future<void> shutdown() async {
    if (_active) {
      _active = false;
      tracker.activeDownloads--;
      tracker.events.add('download:shutdown:${api.session.serverId}');
    }
    await super.shutdown();
  }
}

class _MemorySessionStorage implements SessionStorage {
  final Map<String, String> values = {};
  bool failIndexWrites = false;
  bool failNextIndexWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == 'emby_server_accounts_v1' &&
        (failIndexWrites || failNextIndexWrite)) {
      failNextIndexWrite = false;
      throw StateError('account index write failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _MemoryPlaybackSettingsStorage implements PlaybackSettingsStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _RecordingAccountDataCleanup implements AccountDataCleanup {
  final List<({ServerScope scope, EmbySession session})> calls = [];
  Future<void> Function(ServerScope scope, EmbySession session)? onDelete;

  @override
  Future<void> delete({
    required ServerScope scope,
    required EmbySession session,
  }) async {
    calls.add((scope: scope, session: session));
    await onDelete?.call(scope, session);
  }
}

class _SilentSocket implements EmbySocket {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  void add(String data) {}

  @override
  Future<void> close() async {
    if (!_messages.isClosed) await _messages.close();
  }
}

class _RealHttpOverrides extends HttpOverrides {}

EmbySession _sessionForServer(EmbySession source, String serverUrl) =>
    EmbySession(
      serverUrl: serverUrl,
      serverName: source.serverName,
      serverId: source.serverId,
      userId: source.userId,
      username: source.username,
      accessToken: source.accessToken,
      deviceId: source.deviceId,
    );

const _sessionA = EmbySession(
  serverUrl: 'https://a.example.test',
  serverName: 'Server A',
  serverId: 'server-a',
  userId: 'user-a',
  username: 'alice',
  accessToken: 'token-a',
  deviceId: 'device-1',
);

const _sessionB = EmbySession(
  serverUrl: 'https://b.example.test',
  serverName: 'Server B',
  serverId: 'server-b',
  userId: 'user-b',
  username: 'bob',
  accessToken: 'token-b',
  deviceId: 'device-1',
);
