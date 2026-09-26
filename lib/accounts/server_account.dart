import '../core/server_scope.dart';
import '../models/emby_models.dart';

enum ServerConnectionState { unknown, online, offline, authenticationRequired }

class ServerAccount {
  const ServerAccount({
    required this.accountId,
    required this.session,
    this.connectionState = ServerConnectionState.unknown,
  });

  final String accountId;
  final EmbySession session;
  final ServerConnectionState connectionState;

  ServerScope get scope => ServerScope.fromSession(session);

  ServerAccount copyWith({
    EmbySession? session,
    ServerConnectionState? connectionState,
  }) => ServerAccount(
    accountId: accountId,
    session: session ?? this.session,
    connectionState: connectionState ?? this.connectionState,
  );

  Map<String, dynamic> toIndexJson() => {
    'accountId': accountId,
    'connectionState': connectionState.name,
  };

  factory ServerAccount.fromIndexJson(
    Map<String, dynamic> json,
    EmbySession session,
  ) {
    final accountId = json['accountId']?.toString().trim() ?? '';
    if (accountId.isEmpty) {
      throw const FormatException('Server account ID is empty');
    }
    final stateName = json['connectionState']?.toString();
    final state = ServerConnectionState.values.where(
      (candidate) => candidate.name == stateName,
    );
    return ServerAccount(
      accountId: accountId,
      session: session,
      connectionState: state.isEmpty
          ? ServerConnectionState.unknown
          : state.first,
    );
  }
}

class ServerAccountsSnapshot {
  const ServerAccountsSnapshot({
    this.accounts = const [],
    this.currentAccountId,
  });

  final List<ServerAccount> accounts;
  final String? currentAccountId;

  ServerAccount? get currentAccount => accountById(currentAccountId);

  ServerAccount? accountById(String? accountId) {
    if (accountId == null) return null;
    for (final account in accounts) {
      if (account.accountId == accountId) return account;
    }
    return null;
  }

  ServerAccount? accountForScope(ServerScope scope) {
    for (final account in accounts) {
      if (account.scope == scope) return account;
    }
    return null;
  }
}
