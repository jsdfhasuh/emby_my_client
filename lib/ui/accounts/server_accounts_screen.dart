import 'package:flutter/material.dart';

import '../../accounts/server_account.dart';
import '../../state/app_controller.dart';
import '../login_screen.dart';

class ServerAccountsScreen extends StatefulWidget {
  const ServerAccountsScreen({
    super.key,
    required this.controller,
    this.rootMode = false,
  });

  final AppController controller;
  final bool rootMode;

  @override
  State<ServerAccountsScreen> createState() => _ServerAccountsScreenState();
}

class _ServerAccountsScreenState extends State<ServerAccountsScreen> {
  String? _busyAccountId;
  bool _isRemoving = false;

  bool get _isBusy =>
      _busyAccountId != null ||
      _isRemoving ||
      widget.controller.isSwitchingServer;

  Future<void> _openLogin([ServerAccount? account]) async {
    if (_isBusy) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          controller: widget.controller,
          addAccountMode: true,
          initialServerUrl: account?.session.serverUrl,
          initialUsername: account?.session.username,
        ),
      ),
    );
  }

  Future<void> _switchTo(ServerAccount account) async {
    if (_isBusy || account.accountId == widget.controller.currentAccountId) {
      return;
    }
    if (account.connectionState ==
        ServerConnectionState.authenticationRequired) {
      await _openLogin(account);
      return;
    }
    setState(() => _busyAccountId = account.accountId);
    try {
      await widget.controller.switchAccount(account.accountId);
      if (!mounted || widget.rootMode) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_operationMessage(error, fallback: '服务器切换失败'))),
      );
    } finally {
      if (mounted) setState(() => _busyAccountId = null);
    }
  }

  Future<void> _confirmRemove(ServerAccount account) async {
    if (_isBusy) return;
    final dataPolicy = await showDialog<_AccountRemovalDataPolicy>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除服务器账户？'),
        content: Text(
          '将移除 ${account.session.serverName} 上 ${account.session.username} '
          '的保存凭据。你可以保留已下载内容和本地设置，以便以后重新添加；'
          '也可以同时永久删除该服务器的下载、离线记录和本地设置。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>(
              'confirm-remove-server-account-keep-data',
            ),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AccountRemovalDataPolicy.keep),
            child: const Text('保留本地数据'),
          ),
          FilledButton(
            key: const ValueKey<String>(
              'confirm-remove-server-account-delete-data',
            ),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_AccountRemovalDataPolicy.delete),
            child: const Text('同时删除本地数据'),
          ),
        ],
      ),
    );
    if (dataPolicy == null || !mounted) return;
    setState(() {
      _isRemoving = true;
      _busyAccountId = account.accountId;
    });
    try {
      await widget.controller.removeAccount(
        account.accountId,
        deleteLocalData: dataPolicy == _AccountRemovalDataPolicy.delete,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_operationMessage(error, fallback: '账户移除失败'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRemoving = false;
          _busyAccountId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final accounts = widget.controller.serverAccounts;
        return Scaffold(
          appBar: AppBar(title: const Text('服务器管理')),
          body: Column(
            children: [
              if (widget.controller.isSwitchingServer)
                const LinearProgressIndicator(
                  key: ValueKey<String>('server-switch-progress'),
                  minHeight: 2,
                ),
              if (!widget.controller.isSignedIn && accounts.isNotEmpty)
                const _NoActiveServerBanner(),
              Expanded(
                child: accounts.isEmpty
                    ? const _EmptyAccounts()
                    : ListView.separated(
                        key: const ValueKey<String>('server-account-list'),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                        itemCount: accounts.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final account = accounts[index];
                          return _ServerAccountCard(
                            account: account,
                            current:
                                widget.controller.currentAccountId ==
                                account.accountId,
                            busy: _busyAccountId == account.accountId,
                            interactionsEnabled: !_isBusy,
                            onTap: () => _switchTo(account),
                            onReauthenticate: () => _openLogin(account),
                            onRemove: () => _confirmRemove(account),
                          );
                        },
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            key: const ValueKey<String>('add-server-account-button'),
            onPressed: _isBusy ? null : _openLogin,
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        );
      },
    );
  }
}

enum _AccountRemovalDataPolicy { keep, delete }

class _ServerAccountCard extends StatelessWidget {
  const _ServerAccountCard({
    required this.account,
    required this.current,
    required this.busy,
    required this.interactionsEnabled,
    required this.onTap,
    required this.onReauthenticate,
    required this.onRemove,
  });

  final ServerAccount account;
  final bool current;
  final bool busy;
  final bool interactionsEnabled;
  final VoidCallback onTap;
  final VoidCallback onReauthenticate;
  final VoidCallback onRemove;

  bool get _authenticationRequired =>
      account.connectionState == ServerConnectionState.authenticationRequired;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey<String>('server-account-${account.accountId}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: interactionsEnabled && !current ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: current
                    ? scheme.primary.withValues(alpha: 0.18)
                    : scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.dns_outlined,
                  color: current ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            account.session.serverName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (current)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: _StatusChip(
                              label: '当前',
                              color: scheme.primary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      account.session.username,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.session.serverUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    if (_authenticationRequired) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(
                            Icons.lock_clock_outlined,
                            size: 17,
                            color: Color(0xFFFFB4AB),
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              '登录已失效',
                              style: TextStyle(color: Color(0xFFFFB4AB)),
                            ),
                          ),
                          TextButton(
                            key: ValueKey<String>(
                              'reauthenticate-${account.accountId}',
                            ),
                            onPressed: interactionsEnabled
                                ? onReauthenticate
                                : null,
                            child: const Text('重新登录'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  key: ValueKey<String>('remove-${account.accountId}'),
                  tooltip: '移除账户',
                  onPressed: interactionsEnabled ? onRemove : null,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _NoActiveServerBanner extends StatelessWidget {
  const _NoActiveServerBanner();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey<String>('no-active-server-banner'),
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Text('选择一个已保存的服务器继续，或重新登录失效的账户。'),
  );
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 44, color: Color(0xFF8F989B)),
          SizedBox(height: 14),
          Text('还没有保存的服务器账户'),
          SizedBox(height: 6),
          Text(
            '添加服务器后即可在这里快速切换。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8F989B)),
          ),
        ],
      ),
    ),
  );
}

String _operationMessage(Object error, {required String fallback}) {
  final text = error.toString().trim();
  if (text.startsWith('Bad state: ')) return text.substring(11);
  return text.isEmpty ? fallback : '$fallback：$text';
}
