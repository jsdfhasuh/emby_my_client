import 'dart:convert';

import 'package:emby_my_client/accounts/server_account.dart';
import 'package:emby_my_client/accounts/server_account_repository.dart';
import 'package:emby_my_client/accounts/server_account_store.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrates the legacy session once without exposing its token', () async {
    final storage = _MemorySessionStorage();
    storage.values['emby_session_v1'] = jsonEncode(_sessionA.toJson());

    final first = _repository(storage);
    await first.initialize();

    expect(first.accounts, hasLength(1));
    expect(first.currentAccount?.session, sameSessionAs(_sessionA));
    final accountId = first.currentAccount!.accountId;
    expect(accountId, startsWith('account_'));
    expect(
      storage.values['emby_server_accounts_v1'],
      isNot(contains('token-a')),
    );
    expect(
      storage.values['emby_server_account_session_v1_$accountId'],
      contains('token-a'),
    );

    final restored = _repository(storage);
    await restored.initialize();
    expect(restored.accounts, hasLength(1));
    expect(restored.currentAccountId, accountId);
  });

  test('persists two accounts and restores the selected server', () async {
    final storage = _MemorySessionStorage();
    final repository = _repository(storage);
    await repository.initialize();

    final accountA = await repository.upsert(_sessionA, makeCurrent: true);
    final accountB = await repository.upsert(_sessionB);
    await repository.setCurrent(accountB.accountId);

    expect(repository.accounts, hasLength(2));
    expect(repository.currentAccountId, accountB.accountId);
    expect(accountA.accountId, isNot(accountB.accountId));
    final index = storage.values['emby_server_accounts_v1']!;
    expect(index, isNot(contains('token-a')));
    expect(index, isNot(contains('token-b')));

    final restored = _repository(storage);
    await restored.initialize();
    expect(restored.accounts, hasLength(2));
    expect(restored.currentAccount?.session, sameSessionAs(_sessionB));
    expect(jsonDecode(storage.values['emby_session_v1']!), _sessionB.toJson());
  });

  test(
    'reauthenticating the same scope replaces instead of duplicating',
    () async {
      final storage = _MemorySessionStorage();
      final repository = _repository(storage);
      await repository.initialize();
      final original = await repository.upsert(_sessionA, makeCurrent: true);

      final refreshed = await repository.upsert(
        _copySession(_sessionA, accessToken: 'token-a-refreshed'),
      );

      expect(repository.accounts, hasLength(1));
      expect(refreshed.accountId, original.accountId);
      expect(
        repository.currentAccount!.session.accessToken,
        'token-a-refreshed',
      );
    },
  );

  test('removing one account clears only its secure session', () async {
    final storage = _MemorySessionStorage();
    final repository = _repository(storage);
    await repository.initialize();
    final accountA = await repository.upsert(_sessionA, makeCurrent: true);
    final accountB = await repository.upsert(_sessionB);

    await repository.remove(accountA.accountId);

    expect(repository.accounts, [hasAccountId(accountB.accountId)]);
    expect(repository.currentAccountId, accountB.accountId);
    expect(
      storage.values,
      isNot(contains('emby_server_account_session_v1_${accountA.accountId}')),
    );
    expect(
      storage.values['emby_server_account_session_v1_${accountB.accountId}'],
      contains('token-b'),
    );
  });

  test(
    'authentication-required state is persisted and not auto-selected',
    () async {
      final storage = _MemorySessionStorage();
      final repository = _repository(storage);
      await repository.initialize();
      final accountA = await repository.upsert(_sessionA, makeCurrent: true);
      final accountB = await repository.upsert(_sessionB);

      await repository.markConnectionState(
        accountA.accountId,
        ServerConnectionState.authenticationRequired,
      );
      await repository.setCurrent(null);

      final restored = _repository(storage);
      await restored.initialize();
      expect(
        restored.accountById(accountA.accountId)!.connectionState,
        ServerConnectionState.authenticationRequired,
      );
      expect(restored.currentAccountId, accountB.accountId);
      expect(restored.accountById(accountB.accountId), isNotNull);
    },
  );

  test(
    'expiring the current account atomically selects the next usable account',
    () async {
      final storage = _MemorySessionStorage();
      final repository = _repository(storage);
      await repository.initialize();
      final accountA = await repository.upsert(_sessionA, makeCurrent: true);
      final accountB = await repository.upsert(_sessionB);

      final selected = await repository.markAuthenticationRequired(
        accountA.accountId,
      );

      expect(selected, accountB.accountId);
      expect(repository.currentAccountId, accountB.accountId);
      expect(
        repository.accountById(accountA.accountId)!.connectionState,
        ServerConnectionState.authenticationRequired,
      );
      final restored = _repository(storage);
      await restored.initialize();
      expect(restored.currentAccountId, accountB.accountId);
      expect(
        restored.accountById(accountA.accountId)!.connectionState,
        ServerConnectionState.authenticationRequired,
      );
    },
  );

  test(
    'failed expiration persistence still quarantines the account in memory',
    () async {
      final storage = _MemorySessionStorage();
      final repository = _repository(storage);
      await repository.initialize();
      final accountA = await repository.upsert(_sessionA, makeCurrent: true);
      final accountB = await repository.upsert(_sessionB);
      storage.failIndexWrites = true;

      await expectLater(
        repository.markAuthenticationRequired(accountA.accountId),
        throwsA(isA<SecureStorageFailure>()),
      );

      expect(repository.currentAccountId, accountB.accountId);
      expect(
        repository.accountById(accountA.accountId)!.connectionState,
        ServerConnectionState.authenticationRequired,
      );
    },
  );

  test('failed account index write rolls back the previous snapshot', () async {
    final storage = _MemorySessionStorage();
    final repository = _repository(storage);
    await repository.initialize();
    final accountA = await repository.upsert(_sessionA, makeCurrent: true);
    storage.failNextIndexWrite = true;

    await expectLater(
      repository.upsert(_sessionB),
      throwsA(isA<SecureStorageFailure>()),
    );

    expect(repository.accounts, [hasAccountId(accountA.accountId)]);
    final accountBId = ServerAccountStore.accountIdForSession(_sessionB);
    expect(
      storage.values,
      isNot(contains('emby_server_account_session_v1_$accountBId')),
    );
    final restored = _repository(storage);
    await restored.initialize();
    expect(restored.accounts, [hasAccountId(accountA.accountId)]);
  });
}

ServerAccountRepository _repository(_MemorySessionStorage storage) =>
    ServerAccountRepository(
      store: ServerAccountStore(SessionStore(sessionStorage: storage)),
    );

Matcher sameSessionAs(EmbySession expected) => predicate<EmbySession>(
  (actual) => jsonEncode(actual.toJson()) == jsonEncode(expected.toJson()),
  'matches ${expected.serverName}/${expected.username}',
);

Matcher hasAccountId(String accountId) => isA<ServerAccount>().having(
  (account) => account.accountId,
  'accountId',
  accountId,
);

EmbySession _copySession(EmbySession source, {required String accessToken}) =>
    EmbySession(
      serverUrl: source.serverUrl,
      serverName: source.serverName,
      serverId: source.serverId,
      userId: source.userId,
      username: source.username,
      accessToken: accessToken,
      deviceId: source.deviceId,
      productName: source.productName,
      serverVersion: source.serverVersion,
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

class _MemorySessionStorage implements SessionStorage {
  final Map<String, String> values = {};
  bool failNextIndexWrite = false;
  bool failIndexWrites = false;

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
