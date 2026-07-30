import 'package:emby_my_client/core/server_capabilities.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scope isolates users on the same server', () {
    const first = ServerScope(serverId: 'server-1', userId: 'user-1');
    const second = ServerScope(serverId: 'server-1', userId: 'user-2');

    expect(first, isNot(second));
    expect(first.databaseKey, isNot(second.databaseKey));
    expect(ServerScope.fromJson(first.toJson()), first);
  });

  test('legacy sessions without a server ID get a deterministic scope', () {
    const first = EmbySession(
      serverUrl: 'https://emby.example.test',
      serverName: 'Emby',
      serverId: '',
      userId: 'user-1',
      username: 'tester',
      accessToken: 'secret-token',
      deviceId: 'device-1',
    );
    const second = EmbySession(
      serverUrl: 'https://emby.example.test',
      serverName: 'Emby',
      serverId: '',
      userId: 'user-1',
      username: 'tester',
      accessToken: 'different-token',
      deviceId: 'device-1',
    );

    final firstScope = ServerScope.fromSession(first);
    final secondScope = ServerScope.fromSession(second);

    expect(firstScope, secondScope);
    expect(firstScope.serverId, startsWith('endpoint:'));
    expect(firstScope.databaseKey, isNot(contains('secret-token')));
    expect(firstScope.logLabel, isNot(contains('user-1')));
  });

  test('capability observations preserve explicit evidence', () {
    final observedAt = DateTime.utc(2026, 7, 30, 10);
    final capabilities =
        ServerCapabilities.fromSession(
          _session,
          observedAt: observedAt,
        ).observe(
          ServerFeature.remoteControl,
          CapabilitySupport.supported,
          source: 'sessions-capabilities-full',
          observedAt: observedAt,
        );

    expect(
      capabilities.statusOf(ServerFeature.remoteControl),
      CapabilitySupport.supported,
    );
    expect(
      capabilities.statusOf(ServerFeature.syncPlay),
      CapabilitySupport.unknown,
    );
    expect(
      capabilities.evidence[ServerFeature.remoteControl]?.source,
      'sessions-capabilities-full',
    );
    expect(capabilities.productName, 'Emby Server');
    expect(capabilities.serverVersion, '4.8.11.0');
    expect(
      () => capabilities.observe(
        ServerFeature.liveTv,
        CapabilitySupport.unknown,
        source: 'invalid',
      ),
      throwsArgumentError,
    );
  });

  test('session metadata remains backward compatible', () {
    final restored = EmbySession.fromJson(_session.toJson());
    final legacy = EmbySession.fromJson({
      ..._session.toJson(),
      'productName': null,
      'serverVersion': null,
    });

    expect(restored.productName, 'Emby Server');
    expect(restored.serverVersion, '4.8.11.0');
    expect(legacy.productName, isNull);
    expect(legacy.serverVersion, isNull);
  });
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
  productName: 'Emby Server',
  serverVersion: '4.8.11.0',
);
