import 'dart:async';

import '../core/server_scope.dart';
import '../models/emby_models.dart';
import 'server_account.dart';
import 'server_account_store.dart';

class ServerAccountRepository {
  ServerAccountRepository({required ServerAccountStore store}) : _store = store;

  final ServerAccountStore _store;
  ServerAccountsSnapshot _snapshot = const ServerAccountsSnapshot();
  Future<void>? _initialization;
  Future<void> _tail = Future<void>.value();

  List<ServerAccount> get accounts => List.unmodifiable(_snapshot.accounts);
  String? get currentAccountId => _snapshot.currentAccountId;
  ServerAccount? get currentAccount => _snapshot.currentAccount;

  ServerAccount? accountById(String accountId) =>
      _snapshot.accountById(accountId);

  ServerAccount? accountForScope(ServerScope scope) =>
      _snapshot.accountForScope(scope);

  Future<void> initialize() => _initialization ??= _enqueue(() async {
    _snapshot = await _store.load();
  });

  Future<ServerAccount> upsert(
    EmbySession session, {
    bool makeCurrent = false,
    ServerConnectionState connectionState = ServerConnectionState.online,
  }) async {
    await initialize();
    return _enqueue(() async {
      final scope = ServerScope.fromSession(session);
      final existing = _snapshot.accountForScope(scope);
      final account = ServerAccount(
        accountId:
            existing?.accountId ??
            ServerAccountStore.accountIdForSession(session),
        session: session,
        connectionState: connectionState,
      );
      final accounts = [
        for (final candidate in _snapshot.accounts)
          if (candidate.accountId != account.accountId) candidate,
        account,
      ];
      final next = ServerAccountsSnapshot(
        accounts: List.unmodifiable(accounts),
        currentAccountId: makeCurrent
            ? account.accountId
            : _snapshot.currentAccountId,
      );
      await _commit(next);
      return account;
    });
  }

  Future<void> setCurrent(String? accountId) async {
    await initialize();
    return _enqueue(() async {
      if (accountId != null && _snapshot.accountById(accountId) == null) {
        throw StateError('Unknown server account');
      }
      if (_snapshot.currentAccountId == accountId) return;
      await _commit(
        ServerAccountsSnapshot(
          accounts: _snapshot.accounts,
          currentAccountId: accountId,
        ),
      );
    });
  }

  Future<void> markConnectionState(
    String accountId,
    ServerConnectionState state,
  ) async {
    await initialize();
    return _enqueue(() async {
      final account = _snapshot.accountById(accountId);
      if (account == null || account.connectionState == state) return;
      await _commit(
        ServerAccountsSnapshot(
          accounts: List.unmodifiable([
            for (final candidate in _snapshot.accounts)
              candidate.accountId == accountId
                  ? candidate.copyWith(connectionState: state)
                  : candidate,
          ]),
          currentAccountId: _snapshot.currentAccountId,
        ),
      );
    });
  }

  Future<String?> markAuthenticationRequired(String accountId) async {
    await initialize();
    return _enqueue(() async {
      final account = _snapshot.accountById(accountId);
      if (account == null) return _snapshot.currentAccountId;
      final accounts = List<ServerAccount>.unmodifiable([
        for (final candidate in _snapshot.accounts)
          candidate.accountId == accountId
              ? candidate.copyWith(
                  connectionState: ServerConnectionState.authenticationRequired,
                )
              : candidate,
      ]);
      final currentAccountId = _snapshot.currentAccountId == accountId
          ? _preferredCurrentAccountId(accounts)
          : _snapshot.currentAccountId;
      final next = ServerAccountsSnapshot(
        accounts: accounts,
        currentAccountId: currentAccountId,
      );
      try {
        await _commit(next);
      } catch (_) {
        // Authentication failure is a security boundary. Even when secure
        // storage is temporarily unavailable, keep the expired account
        // quarantined in memory so callers can move to another server instead
        // of restoring the rejected token in the current process.
        _snapshot = next;
        rethrow;
      }
      return currentAccountId;
    });
  }

  Future<ServerAccount?> remove(String accountId) async {
    await initialize();
    return _enqueue(() async {
      final removed = _snapshot.accountById(accountId);
      if (removed == null) return null;
      final remaining = [
        for (final account in _snapshot.accounts)
          if (account.accountId != accountId) account,
      ];
      var currentAccountId = _snapshot.currentAccountId;
      if (currentAccountId == accountId) {
        currentAccountId = _preferredCurrentAccountId(remaining);
      }
      await _commit(
        ServerAccountsSnapshot(
          accounts: List.unmodifiable(remaining),
          currentAccountId: currentAccountId,
        ),
        removedAccountIds: {accountId},
      );
      return removed;
    });
  }

  Future<void> _commit(
    ServerAccountsSnapshot next, {
    Set<String> removedAccountIds = const {},
  }) async {
    final previous = _snapshot;
    final previousIds = {
      for (final account in previous.accounts) account.accountId,
    };
    final addedAccountIds = {
      for (final account in next.accounts)
        if (!previousIds.contains(account.accountId)) account.accountId,
    };
    try {
      await _store.save(next);
      for (final accountId in removedAccountIds) {
        await _store.deleteSession(accountId);
      }
      _snapshot = next;
    } catch (_) {
      try {
        await _store.save(previous);
      } catch (_) {
        // Preserve the original failure. The next load repairs partial writes.
      }
      // A failed save can occur after the new account token was written but
      // before the account index became authoritative. Never leave that
      // unreferenced credential behind in secure storage.
      for (final accountId in addedAccountIds) {
        try {
          await _store.deleteSession(accountId);
        } catch (_) {
          // Preserve the original failure. A later successful write/load can
          // still repair the index without exposing this credential.
        }
      }
      rethrow;
    }
  }

  static String? _preferredCurrentAccountId(List<ServerAccount> accounts) {
    for (final account in accounts) {
      if (account.connectionState !=
          ServerConnectionState.authenticationRequired) {
        return account.accountId;
      }
    }
    return null;
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final next = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _tail = next;
    return completer.future;
  }
}
