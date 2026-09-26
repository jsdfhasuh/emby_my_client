import 'dart:convert';

import '../core/server_scope.dart';
import '../core/sign_in_diagnostics.dart';
import '../data/session_store.dart';
import '../models/emby_models.dart';
import 'server_account.dart';

class ServerAccountStore {
  ServerAccountStore(this._sessionStore);

  static const _version = 1;

  final SessionStore _sessionStore;

  Future<ServerAccountsSnapshot> load() async {
    final encodedIndex = await _sessionStore.readAccountsIndex();
    if (encodedIndex == null || encodedIndex.isEmpty) {
      return _migrateLegacySession();
    }

    try {
      final decoded = Map<String, dynamic>.from(
        jsonDecode(encodedIndex) as Map,
      );
      if (decoded['version'] != _version) {
        throw const FormatException('Unsupported server account index');
      }
      final rawAccounts = decoded['accounts'];
      if (rawAccounts is! List) {
        throw const FormatException('Invalid server account index');
      }

      final accounts = <ServerAccount>[];
      var repaired = false;
      final seenIds = <String>{};
      for (final rawAccount in rawAccounts) {
        if (rawAccount is! Map) {
          repaired = true;
          continue;
        }
        final metadata = Map<String, dynamic>.from(rawAccount);
        final accountId = metadata['accountId']?.toString().trim() ?? '';
        if (accountId.isEmpty || !seenIds.add(accountId)) {
          repaired = true;
          continue;
        }
        final session = await _sessionStore.loadAccountSession(accountId);
        if (session == null) {
          repaired = true;
          continue;
        }
        accounts.add(ServerAccount.fromIndexJson(metadata, session));
      }

      var currentAccountId = decoded['currentAccountId']?.toString();
      if (currentAccountId != null &&
          !accounts.any((account) => account.accountId == currentAccountId)) {
        currentAccountId = null;
        repaired = true;
      }
      if (currentAccountId != null &&
          accounts
                  .firstWhere(
                    (account) => account.accountId == currentAccountId,
                  )
                  .connectionState ==
              ServerConnectionState.authenticationRequired) {
        currentAccountId = null;
        repaired = true;
      }
      if (currentAccountId == null) {
        currentAccountId = _preferredCurrentAccountId(accounts);
        repaired = currentAccountId != null || repaired;
      }
      final snapshot = ServerAccountsSnapshot(
        accounts: List.unmodifiable(accounts),
        currentAccountId: currentAccountId,
      );
      if (repaired) await save(snapshot);
      return snapshot;
    } on SecureStorageFailure {
      rethrow;
    } catch (_) {
      return _migrateLegacySession();
    }
  }

  Future<void> save(ServerAccountsSnapshot snapshot) async {
    for (final account in snapshot.accounts) {
      await _sessionStore.writeAccountSession(
        account.accountId,
        account.session,
      );
    }

    final current = snapshot.currentAccount;
    if (current == null) {
      // Keep the legacy key as a compatibility pointer for the currently
      // selected account, but avoid a destructive secure-storage call when an
      // empty repository has never written that pointer.
      if (await _sessionStore.readSession() != null) {
        await _sessionStore.clearSession();
      }
    } else {
      await _sessionStore.saveSession(current.session);
    }

    await _sessionStore.writeAccountsIndex(
      jsonEncode({
        'version': _version,
        'currentAccountId': snapshot.currentAccountId,
        'accounts': [
          for (final account in snapshot.accounts) account.toIndexJson(),
        ],
      }),
    );
  }

  Future<void> deleteSession(String accountId) =>
      _sessionStore.deleteAccountSession(accountId);

  Future<ServerAccountsSnapshot> _migrateLegacySession() async {
    final legacy = await _sessionStore.loadSession();
    if (legacy == null) {
      return const ServerAccountsSnapshot();
    }
    final account = ServerAccount(
      accountId: accountIdForSession(legacy),
      session: legacy,
      connectionState: ServerConnectionState.unknown,
    );
    final snapshot = ServerAccountsSnapshot(
      accounts: List.unmodifiable([account]),
      currentAccountId: account.accountId,
    );
    await save(snapshot);
    return snapshot;
  }

  static String accountIdForSession(EmbySession session) {
    final namespace = ServerScope.fromSession(session).cacheNamespace;
    return 'account_${namespace.substring(0, 32)}';
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
}
