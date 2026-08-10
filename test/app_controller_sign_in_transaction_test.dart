import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/data/client_registry.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/local_database.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/playback/playback_diagnostics_test_overrides.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'authentication failure leaves session, client, downloads, and realtime untouched',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final tracker = _ClientTracker();
      var apiFactoryCalls = 0;
      final controller = _controller(
        storage,
        clients: tracker.registry,
        authenticator:
            ({
              required serverUrl,
              required username,
              required password,
              required deviceId,
              required deviceName,
            }) async => throw const EmbyApiException(
              'fixture authentication failure',
              statusCode: 401,
            ),
        apiFactory: (session, scope) {
          apiFactoryCalls++;
          return _idleApiFactory(session, scope);
        },
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.signIn(
          serverUrl: _session.serverUrl,
          username: 'user',
          password: 'fixture-password',
        ),
        throwsA(isA<EmbyApiException>()),
      );

      expect(storage.writeCalls, 0);
      expect(storage.deleteCalls, 0);
      expect(tracker.registry.scopes, isEmpty);
      expect(tracker.disposed, 0);
      expect(apiFactoryCalls, 0);
      expect(controller.isSignedIn, isFalse);
    },
  );

  test(
    'session preparation failure does not save or register a client',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final tracker = _ClientTracker();
      final controller = _controller(
        storage,
        clients: tracker.registry,
        apiFactory: (_, _) => throw StateError('raw preparation failure'),
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.signIn(
          serverUrl: _session.serverUrl,
          username: 'user',
          password: 'password',
        ),
        throwsA(
          isA<SignInFailure>()
              .having(
                (error) => error.stage,
                'stage',
                SignInStage.sessionPrepare,
              )
              .having(
                (error) => error.reason,
                'reason',
                SignInFailureReason.sessionPrepareFailed,
              ),
        ),
      );

      expect(storage.values, isNot(contains('emby_session_v1')));
      expect(storage.values, {'emby_device_id_v1': 'existing-device'});
      expect(storage.deleteCalls, 0);
      expect(tracker.registry.scopes, isEmpty);
      expect(controller.isSignedIn, isFalse);
    },
  );

  test(
    'attempt-local client registration failure disposes only the new client',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final clients = _ThrowingRegisterRegistry();
      var apiFactoryCalls = 0;
      final controller = _controller(
        storage,
        clients: clients,
        apiFactory: (session, scope) {
          apiFactoryCalls++;
          return _idleApiFactory(session, scope);
        },
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.signIn(
          serverUrl: _session.serverUrl,
          username: 'user',
          password: 'fixture-password',
        ),
        throwsA(
          isA<SignInFailure>()
              .having(
                (error) => error.stage,
                'stage',
                SignInStage.sessionPrepare,
              )
              .having(
                (error) => error.reason,
                'reason',
                SignInFailureReason.sessionPrepareFailed,
              ),
        ),
      );

      expect(apiFactoryCalls, 1);
      expect(storage.writeCalls, 0);
      expect(storage.deleteCalls, 0);
      expect(clients.scopes, isEmpty);
      expect(controller.isSignedIn, isFalse);
    },
  );

  test('session save failure rolls back the attempt-local client', () async {
    final storage = _FakeSessionStorage()
      ..values['emby_device_id_v1'] = 'existing-device'
      ..failSessionSave = true;
    final tracker = _ClientTracker();
    final controller = _controller(storage, clients: tracker.registry);
    addTearDown(controller.dispose);

    await expectLater(
      controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'password',
      ),
      throwsA(
        isA<SignInFailure>()
            .having((error) => error.stage, 'stage', SignInStage.sessionSave)
            .having(
              (error) => error.reason,
              'reason',
              SignInFailureReason.secureStorageUnexpected,
            ),
      ),
    );

    expect(storage.values, isNot(contains('emby_session_v1')));
    expect(storage.deleteCalls, 0);
    expect(tracker.registry.scopes, isEmpty);
    expect(tracker.disposed, 1);
    expect(controller.session, isNull);
    expect(controller.scope, isNull);
    expect(controller.isSignedIn, isFalse);
  });

  test(
    'rollback failure preserves the original sign-in failure and is safe',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device'
        ..failSessionSave = true;
      final clients = ClientRegistry<EmbyApi>(
        disposeClient: (_) async =>
            throw StateError('fixture rollback failure'),
      );
      final records = <SafeDiagnosticRecord>[];
      final diagnostic = DiagnosticLog.instance;
      diagnostic.setSafeEventTestSink(records.add);
      addTearDown(() => diagnostic.setSafeEventTestSink(null));
      final controller = _controller(storage, clients: clients);
      addTearDown(controller.dispose);

      await expectLater(
        controller.signIn(
          serverUrl: _session.serverUrl,
          username: 'user',
          password: 'fixture-password',
        ),
        throwsA(
          isA<SignInFailure>()
              .having((error) => error.stage, 'stage', SignInStage.sessionSave)
              .having(
                (error) => error.reason,
                'reason',
                SignInFailureReason.secureStorageUnexpected,
              ),
        ),
      );
      await diagnostic.readSafeEvents();

      expect(
        records,
        contains(
          predicate<SafeDiagnosticRecord>(
            (record) =>
                record.stage == SignInStage.rollback &&
                record.reason == SafeDiagnosticReason.unknown &&
                record.errorType == SafeDiagnosticErrorType.signInFailure,
          ),
        ),
      );
      expect(controller.isSignedIn, isFalse);
    },
  );

  test('a failed save can be retried without leaving a half session', () async {
    final storage = _FakeSessionStorage()
      ..values['emby_device_id_v1'] = 'existing-device'
      ..failSessionSave = true;
    final tracker = _ClientTracker();
    final controller = _controller(storage, clients: tracker.registry);
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    await expectLater(
      controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'password',
      ),
      throwsA(isA<SignInFailure>()),
    );
    expect(controller.isSignedIn, isFalse);
    expect(tracker.registry.scopes, isEmpty);

    storage.failSessionSave = false;
    await controller.signIn(
      serverUrl: _session.serverUrl,
      username: 'user',
      password: 'password',
    );

    expect(controller.isSignedIn, isTrue);
    expect(controller.scope, ServerScope.fromSession(_session));
    expect(tracker.registry.scopes.toList(), [
      ServerScope.fromSession(_session),
    ]);
    expect(storage.values, contains('emby_session_v1'));
    expect(notifications, 1);
  });

  test(
    'successful sign-in commits one consistent session notification',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final tracker = _ClientTracker();
      final controller = _controller(storage, clients: tracker.registry);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'password',
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.session, same(_session));
      expect(controller.scope, ServerScope.fromSession(_session));
      expect(controller.api.session, same(_session));
      expect(notifications, 1);
      expect(storage.writeCalls, 1);
    },
  );

  test(
    'iPad sign-in does not wait for the disabled Android download executor',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final controller = _controller(
        storage,
        clients: _ClientTracker().registry,
      );
      addTearDown(controller.dispose);

      await controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'fixture-password',
      );

      expect(controller.isSignedIn, isTrue);
    },
  );

  test(
    'realtime startup failure does not reverse the committed login',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      var realtimeCalls = 0;
      final controller = _controller(
        storage,
        clients: _ClientTracker().registry,
        apiFactory: (session, _) => EmbyApi(
          session,
          realtimeConnector: (_) async {
            realtimeCalls++;
            throw StateError('fixture realtime failure');
          },
        ),
      );
      addTearDown(controller.dispose);

      await controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'fixture-password',
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.isSignedIn, isTrue);
      expect(realtimeCalls, 1);
    },
  );

  test(
    'download startup failure does not reverse the committed login',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final database = LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => inMemoryDatabasePath,
        singleInstance: false,
      );
      final records = <SafeDiagnosticRecord>[];
      final diagnostic = DiagnosticLog.instance;
      diagnostic.setSafeEventTestSink(records.add);
      addTearDown(() => diagnostic.setSafeEventTestSink(null));
      final controller = _controller(
        storage,
        clients: _ClientTracker().registry,
        database: database,
        downloadServiceFactory: (_, _) {
          throw StateError('fixture download startup failure');
        },
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'fixture-password',
      );
      await diagnostic.readSafeEvents();

      expect(controller.isSignedIn, isTrue);
      expect(
        records,
        contains(
          predicate<SafeDiagnosticRecord>(
            (record) =>
                record.stage == SignInStage.activate &&
                record.reason == SafeDiagnosticReason.activationFailed &&
                record.errorType == SafeDiagnosticErrorType.signInFailure,
          ),
        ),
      );
    },
  );

  test('a new controller restores the same saved session', () async {
    final storage = _FakeSessionStorage()
      ..values['emby_device_id_v1'] = 'existing-device';
    final firstDirectory = await Directory.systemTemp.createTemp(
      'emby-controller-restore-first-',
    );
    final secondDirectory = await Directory.systemTemp.createTemp(
      'emby-controller-restore-second-',
    );
    addTearDown(() async {
      await _deleteEventually(firstDirectory);
      await _deleteEventually(secondDirectory);
    });
    final first = _controller(
      storage,
      clients: _ClientTracker().registry,
      database: LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => '${firstDirectory.path}/client.db',
        singleInstance: false,
      ),
    );
    await first.signIn(
      serverUrl: _session.serverUrl,
      username: 'user',
      password: 'fixture-password',
    );
    first.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(storage.values, contains('emby_session_v1'));

    final second = _controller(
      storage,
      clients: _ClientTracker().registry,
      apiFactory: _idleApiFactory,
      database: LocalDatabase(
        factory: databaseFactoryFfi,
        pathResolver: () async => '${secondDirectory.path}/client.db',
        singleInstance: false,
      ),
    );
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.isSignedIn, isTrue);
    expect(second.session?.serverUrl, _session.serverUrl);
    expect(second.session?.userId, _session.userId);
    expect(second.session?.accessToken, _session.accessToken);
  });

  test('sign out removes the saved session', () async {
    final storage = _FakeSessionStorage()
      ..values['emby_device_id_v1'] = 'existing-device';
    final overrides = PlaybackDiagnosticsTestOverridesController()
      ..enable(
        const PlaybackDiagnosticsTestOverrides(streamBufferBytes: 512 << 10),
      );
    final controller = _controller(
      storage,
      clients: _ClientTracker().registry,
      apiFactory: (session, _) => _apiWithSuccessfulRequests(session),
      playbackDiagnosticsTestOverrides: overrides,
    );
    addTearDown(controller.dispose);
    await controller.signIn(
      serverUrl: _session.serverUrl,
      username: 'user',
      password: 'fixture-password',
    );

    await controller.signOut();

    expect(storage.values, isNot(contains('emby_session_v1')));
    expect(controller.isSignedIn, isFalse);
    expect(overrides.isActive, isFalse);
  });

  test(
    'Android keeps the existing device ID and device name behavior',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      var capturedDeviceId = '';
      var capturedDeviceName = '';
      final controller = _controller(
        storage,
        clients: _ClientTracker().registry,
        capabilities: PlatformCapabilities.android,
        authenticator:
            ({
              required serverUrl,
              required username,
              required password,
              required deviceId,
              required deviceName,
            }) async {
              capturedDeviceId = deviceId;
              capturedDeviceName = deviceName;
              return _session;
            },
      );
      addTearDown(controller.dispose);

      await controller.signIn(
        serverUrl: _session.serverUrl,
        username: 'user',
        password: 'fixture-password',
      );

      expect(capturedDeviceId, 'existing-device');
      expect(capturedDeviceName, 'Android');
      expect(controller.isSignedIn, isTrue);
    },
  );
}

AppController _controller(
  _FakeSessionStorage storage, {
  required ClientRegistry<EmbyApi> clients,
  PlatformCapabilities capabilities = PlatformCapabilities.ipad,
  SignInAuthenticator? authenticator,
  SignInApiFactory? apiFactory,
  DownloadServiceFactory? downloadServiceFactory,
  PlaybackDiagnosticsTestOverridesController? playbackDiagnosticsTestOverrides,
  LocalDatabase? database,
}) => AppController(
  store: SessionStore(sessionStorage: storage),
  database: database,
  clients: clients,
  capabilities: capabilities,
  libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
  authenticator:
      authenticator ??
      ({
        required serverUrl,
        required username,
        required password,
        required deviceId,
        required deviceName,
      }) async => _session,
  apiFactory: apiFactory ?? _idleApiFactory,
  downloadServiceFactory: downloadServiceFactory,
  playbackDiagnosticsTestOverrides: playbackDiagnosticsTestOverrides,
);

EmbyApi _idleApiFactory(EmbySession session, ServerScope scope) =>
    EmbyApi(session, realtimeConnector: (_) async => _IdleSocket());

EmbyApi _apiWithSuccessfulRequests(EmbySession session) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<dynamic>(requestOptions: options, statusCode: 200),
        ),
      ),
    );
  return EmbyApi(
    session,
    dio: dio,
    realtimeConnector: (_) async => _IdleSocket(),
  );
}

Future<void> _deleteEventually(Directory directory) async {
  Object? lastError;
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } catch (error) {
      lastError = error;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
  throw lastError!;
}

class _ClientTracker {
  late final ClientRegistry<EmbyApi> registry = ClientRegistry<EmbyApi>(
    disposeClient: (api) async {
      disposed++;
      await api.dispose();
    },
  );

  int disposed = 0;
}

class _ThrowingRegisterRegistry extends ClientRegistry<EmbyApi> {
  _ThrowingRegisterRegistry() : super(disposeClient: (_) {});

  @override
  void register(ServerScope scope, EmbyApi client) {
    throw StateError('fixture client registration failure');
  }
}

final _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'user',
  accessToken: 'token',
  deviceId: 'existing-device',
);

class _FakeSessionStorage implements SessionStorage {
  final Map<String, String> values = <String, String>{};
  bool failSessionSave = false;
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCalls++;
    if (key == 'emby_session_v1' && failSessionSave) {
      throw StateError('session save failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls++;
    values.remove(key);
  }
}

class _IdleSocket implements EmbySocket {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  void add(String data) {}

  @override
  Future<void> close() => _messages.close();
}
