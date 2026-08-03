import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../discovery/emby_server_discovery.dart';
import '../models/discovered_server.dart';
import '../platform/platform_capabilities.dart';
import '../state/app_controller.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.controller,
    this.discovery,
    this.capabilities,
  });

  final AppController controller;
  final EmbyServerDiscovery? discovery;
  final PlatformCapabilities? capabilities;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  late final EmbyServerDiscovery _discovery =
      widget.discovery ?? EmbyServerDiscovery();
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  List<DiscoveredServer> _discoveredServers = const [];
  bool _obscurePassword = true;
  bool _isSubmitting = false;
  bool _isDiscovering = false;
  int _discoveryGeneration = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_capabilities.supportsLanUdpDiscovery) _startDiscovery();
  }

  @override
  void dispose() {
    _discoveryGeneration++;
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    if (_isDiscovering) return;
    final generation = ++_discoveryGeneration;
    setState(() {
      _isDiscovering = true;
      _discoveredServers = const [];
    });
    final servers = await _discovery.discover();
    if (!mounted || generation != _discoveryGeneration) return;
    setState(() {
      _discoveredServers = servers;
      _isDiscovering = false;
    });
  }

  void _selectDiscoveredServer(DiscoveredServer server) {
    _serverController
      ..text = server.address
      ..selection = TextSelection.collapsed(offset: server.address.length);
    FocusScope.of(context).requestFocus();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.controller.signIn(
        serverUrl: _serverController.text,
        username: _usernameController.text,
        password: _passwordController.text,
      );
    } on EmbyApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '登录失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          size: 38,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Emby 客户端',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '登录你的媒体服务器',
                      style: TextStyle(color: Color(0xFFADB5B7), fontSize: 16),
                    ),
                    const SizedBox(height: 24),
                    _buildDiscoverySection(),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _serverController,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: '192.168.1.10:8096',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请输入服务器地址'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _usernameController,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请输入用户名'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3A2020),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF74403D)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 20,
                              color: Color(0xFFFFA49C),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Color(0xFFFFC2BC),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: _isSubmitting ? null : _submit,
                      icon: _isSubmitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.login),
                      label: Text(_isSubmitting ? '正在连接' : '登录'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiscoverySection() {
    if (!_capabilities.supportsLanUdpDiscovery) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '局域网服务器',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '重新扫描',
              onPressed: _isDiscovering ? null : _startDiscovery,
              icon: _isDiscovering
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_isDiscovering && _discoveredServers.isEmpty)
          const LinearProgressIndicator(minHeight: 2)
        else if (_discoveredServers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '未发现局域网服务器',
              style: TextStyle(color: Color(0xFF8F989B), fontSize: 13),
            ),
          )
        else
          for (var index = 0; index < _discoveredServers.length; index++) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 54,
              leading: const Icon(Icons.dns_outlined),
              title: Text(
                _discoveredServers[index].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _discoveredServers[index].address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectDiscoveredServer(_discoveredServers[index]),
            ),
            if (index < _discoveredServers.length - 1) const Divider(height: 1),
          ],
      ],
    );
  }
}
