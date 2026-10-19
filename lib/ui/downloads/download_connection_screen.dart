import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/server_scope.dart';
import '../../downloads/download_connection.dart';
import '../../models/emby_models.dart';

class DownloadConnectionScreen extends StatefulWidget {
  const DownloadConnectionScreen({
    super.key,
    required this.session,
    this.manager,
  });
  final EmbySession session;
  final DownloadConnectionManager? manager;
  @override
  State<DownloadConnectionScreen> createState() =>
      _DownloadConnectionScreenState();
}

class _DownloadConnectionScreenState extends State<DownloadConnectionScreen> {
  late final _manager = widget.manager ?? DownloadConnectionManager.instance;
  late final _scope = ServerScope.fromSession(widget.session);
  final _link = TextEditingController();
  DownloadConnectionSettings _settings = const DownloadConnectionSettings();
  DownloadConnectionStatus _status = const DownloadConnectionStatus();
  DownloadConnectionTestResult? _test;
  Timer? _statusTimer;
  bool _loading = true;
  bool _working = false;
  bool _statusFailed = false;
  String? _error;
  String? _message;
  bool get _locked => _loading || _working || _status.isBusy || _statusFailed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _statusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _link.clear();
    _link.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await _manager.load(_scope);
      final status = await _manager.status();
      if (mounted) {
        setState(() {
          _settings = settings;
          _status = status;
          _statusFailed = false;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _friendly(error);
          _statusFailed = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshStatus() async {
    if (!mounted || _working) {
      return;
    }
    try {
      final status = await _manager.status();
      if (mounted) {
        setState(() {
          _status = status;
          _statusFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _statusFailed = true);
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_locked) return;
    setState(() {
      _working = true;
      _error = null;
      _message = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) {
        setState(() => _working = false);
        await _refreshStatus();
      }
    }
  }

  void _import() {
    if (_locked) return;
    try {
      final profile = Hysteria2Profile.parse(_link.text);
      setState(() {
        _settings = _settings.copyWith(profile: profile);
        _test = null;
        _error = null;
        _message = '配置已导入，尚未保存';
      });
      _link.clear();
    } catch (error) {
      setState(() => _error = _friendly(error));
    }
  }

  Future<void> _save() => _run(() async {
    await _manager.save(_scope, _settings);
    _link.clear();
    if (mounted) {
      setState(() => _message = '已保存');
    }
  });

  Future<void> _delete() => _run(() async {
    await _manager.delete(_scope);
    _link.clear();
    if (mounted) {
      setState(() {
        _settings = const DownloadConnectionSettings();
        _test = null;
        _message = '配置已删除，当前为普通连接';
      });
    }
  });

  Future<void> _probe() => _run(() async {
    final result = await _manager.test(widget.session, _settings.profile!);
    if (mounted) setState(() => _test = result);
  });

  @override
  Widget build(BuildContext context) {
    final profile = _settings.profile;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('离线下载连接'),
          actions: [
            IconButton(
              key: const ValueKey('download-connection-save'),
              tooltip: '保存',
              onPressed:
                  _locked ||
                      (_settings.mode == DownloadConnectionMode.hysteria2 &&
                          profile == null)
                  ? null
                  : _save,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  SegmentedButton<DownloadConnectionMode>(
                    key: const ValueKey('download-connection-mode'),
                    segments: const [
                      ButtonSegment(
                        value: DownloadConnectionMode.direct,
                        icon: Icon(Icons.public),
                        label: Text('普通连接'),
                      ),
                      ButtonSegment(
                        value: DownloadConnectionMode.hysteria2,
                        icon: Icon(Icons.route_outlined),
                        label: Text('Hysteria2'),
                      ),
                    ],
                    selected: {_settings.mode},
                    onSelectionChanged: _locked
                        ? null
                        : (values) => setState(() {
                            _settings = _settings.copyWith(mode: values.single);
                            _message = '连接方式尚未保存';
                          }),
                  ),
                  const SizedBox(height: 24),
                  if (_status.isBusy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text('连接正在使用，请先停止播放并暂停下载'),
                    ),
                  if (_statusFailed)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('连接状态不可用'),
                      trailing: IconButton(
                        tooltip: '重试',
                        onPressed: _working ? null : _load,
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  TextField(
                    key: const ValueKey('download-connection-link'),
                    controller: _link,
                    enabled: !_locked,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Hysteria2 连接链接',
                      suffixIcon: IconButton(
                        tooltip: '粘贴',
                        onPressed: _locked
                            ? null
                            : () async {
                                final value = await Clipboard.getData(
                                  Clipboard.kTextPlain,
                                );
                                if (mounted && !_locked) {
                                  _link.text = value?.text ?? '';
                                }
                              },
                        icon: const Icon(Icons.content_paste),
                      ),
                    ),
                    onSubmitted: (_) => _import(),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('download-connection-import'),
                      onPressed: _locked ? null : _import,
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('导入配置'),
                    ),
                  ),
                  if (profile != null) ...[
                    const Divider(height: 32),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(profile.label),
                      subtitle: Text('SNI: ${profile.sni}'),
                      trailing: IconButton(
                        key: const ValueKey('download-connection-delete'),
                        tooltip: '删除配置',
                        onPressed: _locked ? null : _delete,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('证书校验'),
                      trailing: const Icon(Icons.verified_user_outlined),
                    ),
                    if (profile.obfsPassword != null)
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Salamander'),
                        trailing: Icon(Icons.check),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('download-connection-test'),
                        onPressed: _locked ? null : _probe,
                        icon: const Icon(Icons.network_check),
                        label: const Text('测试连接'),
                      ),
                    ),
                  ],
                  if (_working)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (_test != null) ...[
                    const Divider(height: 32),
                    _result(
                      'Hysteria2 握手',
                      _test!.handshakeSucceeded,
                      _test!.handshakeTime,
                    ),
                    _result(
                      'Emby 访问',
                      _test!.serverReachable,
                      _test!.serverTime,
                    ),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _message!,
                        key: const ValueKey('download-connection-message'),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        key: const ValueKey('download-connection-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _result(String title, bool succeeded, Duration? elapsed) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(
      '${succeeded ? '成功' : '失败'}'
      '${elapsed == null ? '' : ' · ${elapsed.inMilliseconds} ms'}',
    ),
    trailing: Icon(
      succeeded ? Icons.check_circle_outline : Icons.error_outline,
    ),
  );

  String _friendly(Object error) {
    if (error is FormatException) return '连接链接无效或包含不支持的参数';
    if (error is DownloadConnectionException) {
      return switch (error.code) {
        'configBusy' => '连接正在使用，请先停止播放并暂停下载',
        'configurationUnavailable' => '无法读取或保存连接配置',
        'unsupported' => '此设备不支持内置 Hysteria2',
        _ => 'Hysteria2 不可用，请检查配置和网络',
      };
    }
    return '操作失败，请重试';
  }
}
