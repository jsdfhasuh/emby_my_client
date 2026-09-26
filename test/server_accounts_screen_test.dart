import 'dart:async';

import 'package:emby_my_client/accounts/server_account.dart';
import 'package:emby_my_client/app.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/accounts/server_accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists saved servers and shows reauthentication state', (
    tester,
  ) async {
    final controller = _FakeAccountsController([
      _accountA,
      _accountB.copyWith(
        connectionState: ServerConnectionState.authenticationRequired,
      ),
    ]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));

    expect(find.text('Server A'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('Server B'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('登录已失效'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);
  });

  testWidgets('switch shows progress until the target becomes current', (
    tester,
  ) async {
    final controller = _FakeAccountsController([_accountA, _accountB]);
    final gate = Completer<void>();
    controller.switchGate = gate;
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    await tester.tap(
      find.byKey(const ValueKey<String>('server-account-account-b')),
    );
    await tester.pump();

    expect(controller.switchCalls, ['account-b']);
    expect(
      find.byKey(const ValueKey<String>('server-switch-progress')),
      findsOneWidget,
    );
    expect(controller.currentAccountId, 'account-a');

    gate.complete();
    await tester.pumpAndSettle();

    expect(controller.currentAccountId, 'account-b');
    expect(
      find.byKey(const ValueKey<String>('server-switch-progress')),
      findsNothing,
    );
  });

  testWidgets('add server mode submits credentials through addAccount', (
    tester,
  ) async {
    final controller = _FakeAccountsController([_accountA]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    await tester.tap(
      find.byKey(const ValueKey<String>('add-server-account-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('添加服务器账户'), findsOneWidget);
    expect(find.text('添加并切换'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-server-field')),
      'https://new.example.test',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-username-field')),
      'charlie',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password-field')),
      'fixture-password',
    );
    await tester.tap(find.byKey(const ValueKey<String>('login-submit-button')));
    await tester.pumpAndSettle();

    expect(controller.addCalls, [
      (
        serverUrl: 'https://new.example.test',
        username: 'charlie',
        password: 'fixture-password',
      ),
    ]);
    expect(find.text('服务器管理'), findsOneWidget);
  });

  testWidgets('reauthentication pre-fills the server and username', (
    tester,
  ) async {
    final controller = _FakeAccountsController([
      _accountA,
      _accountB.copyWith(
        connectionState: ServerConnectionState.authenticationRequired,
      ),
    ]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    await tester.tap(
      find.byKey(const ValueKey<String>('reauthenticate-account-b')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final serverField = tester.widget<TextFormField>(
      find.byKey(const ValueKey<String>('login-server-field')),
    );
    final usernameField = tester.widget<TextFormField>(
      find.byKey(const ValueKey<String>('login-username-field')),
    );
    expect(serverField.controller?.text, _accountB.session.serverUrl);
    expect(usernameField.controller?.text, _accountB.session.username);
  });

  testWidgets('remove can keep scoped downloads and local settings', (
    tester,
  ) async {
    final controller = _FakeAccountsController([_accountA, _accountB]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.byKey(const ValueKey<String>('remove-account-b')));
    await tester.pumpAndSettle();

    expect(find.text('移除服务器账户？'), findsOneWidget);
    expect(find.textContaining('你可以保留已下载内容和本地设置'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('confirm-remove-server-account-keep-data'),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.removeCalls, [
      (accountId: 'account-b', deleteLocalData: false),
    ]);
    expect(find.text('Server A'), findsOneWidget);
    expect(find.text('Server B'), findsNothing);
  });

  testWidgets('remove can delete scoped downloads and local settings', (
    tester,
  ) async {
    final controller = _FakeAccountsController([_accountA, _accountB]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.byKey(const ValueKey<String>('remove-account-b')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('confirm-remove-server-account-delete-data'),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.removeCalls, [
      (accountId: 'account-b', deleteLocalData: true),
    ]);
    expect(find.text('Server B'), findsNothing);
  });

  testWidgets('app root shows account recovery when no workspace is active', (
    tester,
  ) async {
    final controller = _FakeAccountsController([_accountA], signedIn: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(EmbyClientApp(controller: controller));

    expect(find.text('服务器管理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('no-active-server-banner')),
      findsOneWidget,
    );
  });
}

Widget _app(_FakeAccountsController controller) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: ServerAccountsScreen(controller: controller, rootMode: true),
);

class _FakeAccountsController extends AppController {
  _FakeAccountsController(List<ServerAccount> accounts, {bool signedIn = true})
    : _accounts = List.of(accounts),
      _signedIn = signedIn,
      _currentAccountId = accounts.isEmpty ? null : accounts.first.accountId;

  final List<ServerAccount> _accounts;
  bool _signedIn;
  String? _currentAccountId;
  bool _switching = false;
  Completer<void>? switchGate;
  final List<String> switchCalls = [];
  final List<({String accountId, bool deleteLocalData})> removeCalls = [];
  final List<({String serverUrl, String username, String password})> addCalls =
      [];

  @override
  bool get isInitializing => false;

  @override
  bool get isSignedIn => _signedIn;

  @override
  bool get hasServerAccounts => _accounts.isNotEmpty;

  @override
  List<ServerAccount> get serverAccounts => List.unmodifiable(_accounts);

  @override
  String? get currentAccountId => _currentAccountId;

  @override
  bool get isSwitchingServer => _switching;

  @override
  Future<void> switchAccount(
    String accountId, {
    bool forceReload = false,
  }) async {
    switchCalls.add(accountId);
    _switching = true;
    notifyListeners();
    await switchGate?.future;
    _currentAccountId = accountId;
    _signedIn = true;
    _switching = false;
    notifyListeners();
  }

  @override
  Future<void> removeAccount(
    String accountId, {
    bool deleteLocalData = false,
  }) async {
    removeCalls.add((accountId: accountId, deleteLocalData: deleteLocalData));
    _accounts.removeWhere((account) => account.accountId == accountId);
    if (_currentAccountId == accountId) {
      _currentAccountId = _accounts.firstOrNull?.accountId;
      _signedIn = _currentAccountId != null;
    }
    notifyListeners();
  }

  @override
  Future<void> addAccount({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    addCalls.add((
      serverUrl: serverUrl,
      username: username,
      password: password,
    ));
  }
}

const _accountA = ServerAccount(
  accountId: 'account-a',
  session: EmbySession(
    serverUrl: 'https://a.example.test',
    serverName: 'Server A',
    serverId: 'server-a',
    userId: 'user-a',
    username: 'alice',
    accessToken: 'token-a',
    deviceId: 'device-1',
  ),
  connectionState: ServerConnectionState.online,
);

const _accountB = ServerAccount(
  accountId: 'account-b',
  session: EmbySession(
    serverUrl: 'https://b.example.test',
    serverName: 'Server B',
    serverId: 'server-b',
    userId: 'user-b',
    username: 'bob',
    accessToken: 'token-b',
    deviceId: 'device-1',
  ),
  connectionState: ServerConnectionState.unknown,
);
