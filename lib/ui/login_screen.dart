import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../core/sign_in_diagnostics.dart';
import '../core/safe_diagnostic_export.dart';
import '../discovery/emby_server_discovery.dart';
import '../models/discovered_server.dart';
import '../platform/platform_capabilities.dart';
import '../state/app_controller.dart';
import 'safe_diagnostic_export_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.controller,
    this.discovery,
    this.capabilities,
    this.safeDiagnosticService,
    this.safeDiagnosticShareGateway,
  });

  final AppController controller;
  final EmbyServerDiscovery? discovery;
  final PlatformCapabilities? capabilities;
  final SafeDiagnosticExportService? safeDiagnosticService;
  final SafeDiagnosticShareGateway? safeDiagnosticShareGateway;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  static const _compactHeightThreshold = 600.0;

  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _scrollController = ScrollController();
  final _serverFocusNode = FocusNode();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _serverAnchorKey = GlobalKey();
  final _usernameAnchorKey = GlobalKey();
  final _passwordAnchorKey = GlobalKey();
  late final EmbyServerDiscovery _discovery =
      widget.discovery ?? EmbyServerDiscovery();
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  List<DiscoveredServer> _discoveredServers = const [];
  bool _obscurePassword = true;
  bool _isSubmitting = false;
  bool _isDiscovering = false;
  int _discoveryGeneration = 0;
  EmbyDiscoveryCancellation? _discoveryCancellation;
  bool _ensureVisibleScheduled = false;
  Duration _scheduledEnsureVisibleDuration = Duration.zero;
  String? _error;
  String? _diagnosticCode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serverFocusNode.addListener(_handleFieldFocusChanged);
    _usernameFocusNode.addListener(_handleFieldFocusChanged);
    _passwordFocusNode.addListener(_handleFieldFocusChanged);
    if (_capabilities.supportsLanUdpDiscovery) _startDiscovery();
  }

  @override
  void dispose() {
    _discoveryCancellation?.cancel();
    _discoveryCancellation = null;
    _discoveryGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _serverFocusNode.removeListener(_handleFieldFocusChanged);
    _usernameFocusNode.removeListener(_handleFieldFocusChanged);
    _passwordFocusNode.removeListener(_handleFieldFocusChanged);
    _serverFocusNode.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _scrollController.dispose();
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scheduleEnsureVisible(duration: Duration.zero);
  }

  void _handleFieldFocusChanged() {
    if (!_hasFocusedField) return;
    _scheduleEnsureVisible(duration: const Duration(milliseconds: 220));
  }

  bool get _hasFocusedField =>
      _serverFocusNode.hasFocus ||
      _usernameFocusNode.hasFocus ||
      _passwordFocusNode.hasFocus;

  GlobalKey? get _focusedFieldAnchorKey {
    if (_serverFocusNode.hasFocus) return _serverAnchorKey;
    if (_usernameFocusNode.hasFocus) return _usernameAnchorKey;
    if (_passwordFocusNode.hasFocus) return _passwordAnchorKey;
    return null;
  }

  FocusNode? get _focusedFieldFocusNode {
    if (_serverFocusNode.hasFocus) return _serverFocusNode;
    if (_usernameFocusNode.hasFocus) return _usernameFocusNode;
    if (_passwordFocusNode.hasFocus) return _passwordFocusNode;
    return null;
  }

  void _scheduleEnsureVisible({required Duration duration}) {
    if (!mounted || !_hasFocusedField) return;
    if (_ensureVisibleScheduled) {
      if (duration == Duration.zero) {
        _scheduledEnsureVisibleDuration = Duration.zero;
      }
      return;
    }
    _ensureVisibleScheduled = true;
    _scheduledEnsureVisibleDuration = duration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisibleScheduled = false;
      final anchorContext = _focusedFieldAnchorKey?.currentContext;
      final focusNode = _focusedFieldFocusNode;
      if (!mounted ||
          !_scrollController.hasClients ||
          focusNode == null ||
          !focusNode.hasFocus ||
          anchorContext == null) {
        return;
      }
      unawaited(
        _ensureFocusedFieldVisible(
          anchorContext,
          focusNode: focusNode,
          duration: _scheduledEnsureVisibleDuration,
        ),
      );
    });
  }

  Future<void> _ensureFocusedFieldVisible(
    BuildContext context, {
    required FocusNode focusNode,
    required Duration duration,
  }) async {
    if (!mounted || !_scrollController.hasClients || !focusNode.hasFocus) {
      return;
    }
    try {
      await Scrollable.ensureVisible(
        context,
        alignment: 0.14,
        duration: duration,
        curve: Curves.easeOut,
      );
    } catch (_) {
      // The field may be removed while the keyboard or route is closing.
    }
  }

  void _handleFieldTapOutside(PointerDownEvent event) {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _openSafeDiagnostics() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SafeDiagnosticExportScreen(
          service: widget.safeDiagnosticService,
          shareGateway: widget.safeDiagnosticShareGateway,
          capabilities: _capabilities,
        ),
      ),
    );
  }

  Future<void> _startDiscovery() async {
    _discoveryCancellation?.cancel();
    final cancellation = EmbyDiscoveryCancellation();
    _discoveryCancellation = cancellation;
    final generation = ++_discoveryGeneration;
    setState(() {
      _isDiscovering = true;
      _discoveredServers = const [];
    });
    try {
      final result = await _discovery.discover(cancellation: cancellation);
      if (!mounted || generation != _discoveryGeneration) return;
      setState(() {
        _discoveredServers = result.servers;
        _isDiscovering = false;
      });
    } finally {
      if (identical(_discoveryCancellation, cancellation)) {
        _discoveryCancellation = null;
        if (mounted && _isDiscovering) {
          setState(() => _isDiscovering = false);
        }
      }
    }
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
      _diagnosticCode = null;
    });
    try {
      await widget.controller.signIn(
        serverUrl: _serverController.text,
        username: _usernameController.text,
        password: _passwordController.text,
      );
    } on EmbyApiException catch (error) {
      final message =
          _capabilities.supportsLocalNetworkPermissionRecovery &&
              error.isLocalNetworkConnectionFailure
          ? '无法访问局域网服务器。请确认已在“设置 → 隐私与安全性 → 本地网络”中允许本应用，然后重试。'
          : error.message;
      if (mounted) {
        setState(() {
          _error = message;
          _diagnosticCode = _isIpadOS ? 'LOGIN-AUTH' : null;
        });
      }
    } on SignInFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = _signInFailureMessage(error);
          _diagnosticCode = _isIpadOS ? error.diagnosticCode : null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '登录失败，请稍后重试';
          _diagnosticCode = _isIpadOS ? 'LOGIN-UNKNOWN' : null;
        });
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
            final compact =
                keyboardVisible ||
                constraints.maxHeight < _compactHeightThreshold;
            final verticalPadding = compact ? 16.0 : 24.0;
            final minContentHeight = math.max(
              0.0,
              constraints.maxHeight - (2 * verticalPadding),
            );

            return SingleChildScrollView(
              key: const ValueKey<String>('login-scroll-view'),
              controller: _scrollController,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.symmetric(
                horizontal: 24,
                vertical: verticalPadding,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minContentHeight),
                child: Align(
                  alignment: compact ? Alignment.topCenter : Alignment.center,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildBrandHeader(compact),
                          SizedBox(height: compact ? 14 : 24),
                          _buildDiscoverySection(),
                          SizedBox(height: compact ? 14 : 20),
                          KeyedSubtree(
                            key: _serverAnchorKey,
                            child: TextFormField(
                              key: const ValueKey<String>('login-server-field'),
                              controller: _serverController,
                              focusNode: _serverFocusNode,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              onTapOutside: _handleFieldTapOutside,
                              onFieldSubmitted: (_) =>
                                  _usernameFocusNode.requestFocus(),
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
                          ),
                          const SizedBox(height: 14),
                          KeyedSubtree(
                            key: _usernameAnchorKey,
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'login-username-field',
                              ),
                              controller: _usernameController,
                              focusNode: _usernameFocusNode,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              onTapOutside: _handleFieldTapOutside,
                              onFieldSubmitted: (_) =>
                                  _passwordFocusNode.requestFocus(),
                              decoration: const InputDecoration(
                                labelText: '用户名',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '请输入用户名'
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 14),
                          KeyedSubtree(
                            key: _passwordAnchorKey,
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'login-password-field',
                              ),
                              controller: _passwordController,
                              focusNode: _passwordFocusNode,
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              onTapOutside: _handleFieldTapOutside,
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
                              validator: (value) =>
                                  value == null || value.isEmpty
                                  ? '请输入密码'
                                  : null,
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              key: const ValueKey<String>('login-error'),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF3A2020),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: const Color(0xFF74403D),
                                ),
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
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _error!,
                                          style: const TextStyle(
                                            color: Color(0xFFFFC2BC),
                                          ),
                                        ),
                                        if (_diagnosticCode != null) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            _diagnosticCode!,
                                            style: const TextStyle(
                                              color: Color(0xFFFFC2BC),
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          FilledButton.icon(
                            key: const ValueKey<String>('login-submit-button'),
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
            );
          },
        ),
      ),
    );
  }

  Widget _buildBrandHeader(bool compact) {
    final theme = Theme.of(context);
    final logoSize = compact ? 38.0 : 54.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: logoSize,
              height: logoSize,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                size: compact ? 28 : 38,
                color: Colors.black,
              ),
            ),
            if (_isIpadOS) ...[
              const Spacer(),
              TextButton.icon(
                key: const ValueKey<String>('login-safe-diagnostics-button'),
                onPressed: _openSafeDiagnostics,
                icon: const Icon(Icons.security_outlined),
                label: const Text('查看/导出安全诊断'),
              ),
            ],
          ],
        ),
        SizedBox(height: compact ? 10 : 24),
        Text(
          'Emby 客户端',
          style:
              (compact
                      ? theme.textTheme.titleLarge
                      : theme.textTheme.displaySmall)
                  ?.copyWith(fontWeight: FontWeight.w800),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (!compact) ...[
          const SizedBox(height: 8),
          const Text(
            '登录你的媒体服务器',
            style: TextStyle(color: Color(0xFFADB5B7), fontSize: 16),
          ),
        ],
      ],
    );
  }

  bool get _isIpadOS => _capabilities.platformName == 'ios';

  String _signInFailureMessage(SignInFailure failure) =>
      switch (failure.reason) {
        SignInFailureReason.secureStorageMissingEntitlement ||
        SignInFailureReason.secureStorageUnavailable ||
        SignInFailureReason.secureStorageAccessDenied ||
        SignInFailureReason.secureStorageUnexpected =>
          _isIpadOS
              ? '无法使用系统安全存储，登录信息不能安全保存。请记录诊断码并安装修复构建；除非验收步骤明确要求，请不要卸载现有版本。'
              : '登录失败，请稍后重试',
        SignInFailureReason.sessionPrepareFailed =>
          _isIpadOS ? '登录准备失败，请重试；如持续出现，请提供诊断码。' : '登录失败，请稍后重试',
        SignInFailureReason.sessionSaveFailed =>
          _isIpadOS ? '登录信息保存失败，请重试；如持续出现，请提供诊断码。' : '登录失败，请稍后重试',
        SignInFailureReason.activationFailed =>
          _isIpadOS ? '登录初始化失败，请重试；如持续出现，请提供诊断码。' : '登录失败，请稍后重试',
        SignInFailureReason.alreadyInProgress ||
        SignInFailureReason.alreadySignedIn ||
        SignInFailureReason.unknown => '登录失败，请稍后重试',
      };

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
