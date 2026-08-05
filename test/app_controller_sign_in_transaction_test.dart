import 'dart:async';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/data/client_registry.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(storage.deleteCalls, 0);
      expect(tracker.registry.scopes, isEmpty);
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
}

AppController _controller(
  _FakeSessionStorage storage, {
  required ClientRegistry<EmbyApi> clients,
  SignInApiFactory? apiFactory,
}) => AppController(
  store: SessionStore(sessionStorage: storage),
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
      }) async => _session,
  apiFactory: apiFactory ?? _idleApiFactory,
);

EmbyApi _idleApiFactory(EmbySession session, ServerScope scope) =>
    EmbyApi(session, realtimeConnector: (_) async => _IdleSocket());

class _ClientTracker {
  late final ClientRegistry<EmbyApi> registry = ClientRegistry<EmbyApi>(
    disposeClient: (api) async {
      disposed++;
      await api.dispose();
    },
  );

  int disposed = 0;
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
