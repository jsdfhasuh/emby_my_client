import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/safe_diagnostic_export.dart';
import '../platform/platform_capabilities.dart';

class SafeDiagnosticExportScreen extends StatefulWidget {
  const SafeDiagnosticExportScreen({
    super.key,
    this.service,
    this.shareGateway,
    this.capabilities,
  });

  final SafeDiagnosticExportService? service;
  final SafeDiagnosticShareGateway? shareGateway;
  final PlatformCapabilities? capabilities;

  @override
  State<SafeDiagnosticExportScreen> createState() =>
      _SafeDiagnosticExportScreenState();
}

class _SafeDiagnosticExportScreenState
    extends State<SafeDiagnosticExportScreen> {
  late final SafeDiagnosticExportService _service =
      widget.service ?? SafeDiagnosticExportService();
  late final SafeDiagnosticShareGateway _shareGateway =
      widget.shareGateway ?? const MethodChannelSafeDiagnosticShareGateway();
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  final _exportButtonKey = GlobalKey();
  SafeDiagnosticReport? _report;
  String? _errorCode;
  bool _loading = true;
  bool _sharing = false;
  bool _nativeSharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorCode = null;
      });
    }
    if (_capabilities.platformName != 'ios') {
      if (!mounted) return;
      setState(() {
        _report = null;
        _errorCode = SafeDiagnosticExportException.unsafe;
        _loading = false;
      });
      return;
    }
    try {
      final report = await _service.buildReport();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } on SafeDiagnosticExportException catch (error) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _errorCode = _normalizeErrorCode(error.code);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _errorCode = SafeDiagnosticExportException.unsafe;
        _loading = false;
      });
    }
  }

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: report.content));
      if (mounted) {
        _showMessage('安全诊断报告已复制');
      }
    } catch (_) {
      if (mounted) {
        _showMessage(_failureMessage(SafeDiagnosticExportException.write));
      }
    }
  }

  Future<void> _clearReports() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空安全诊断？'),
        content: const Text('只会删除安全诊断事件，不会删除本机完整诊断日志。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.clearSafeEvents();
      await _load();
    } on SafeDiagnosticExportException catch (error) {
      if (mounted) {
        _showMessage(_failureMessage(error.code));
      }
    } catch (_) {
      if (mounted) {
        _showMessage(_failureMessage(SafeDiagnosticExportException.write));
      }
    }
  }

  Future<void> _shareReport() async {
    final report = _report;
    if (report == null || report.recordCount == 0) return;
    if (_sharing) {
      _showMessage(_failureMessage(SafeDiagnosticExportException.busy));
      return;
    }
    final anchor = _readExportButtonAnchor();
    setState(() => _sharing = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出安全诊断？'),
          content: const Text(
            '即将导出只包含固定登录诊断字段的安全报告。发送前仍请预览并确认不含账户、密码、Token、设备 ID 或服务器地址。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('导出'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _nativeSharing = true);
      final outcome = await _shareGateway.share(report, anchor: anchor);
      if (!mounted) return;
      if (outcome == SafeDiagnosticShareOutcome.completed) {
        _showMessage('安全诊断报告已准备分享');
      } else {
        _showMessage('已取消导出');
      }
    } on SafeDiagnosticExportException catch (error) {
      if (mounted) {
        _showMessage(_failureMessage(error.code));
      }
    } catch (_) {
      if (mounted) {
        _showMessage(_failureMessage(SafeDiagnosticExportException.share));
      }
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
          _nativeSharing = false;
        });
      } else {
        _sharing = false;
        _nativeSharing = false;
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  SafeDiagnosticPopoverAnchor _readExportButtonAnchor() {
    final renderObject = _exportButtonKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return const SafeDiagnosticPopoverAnchor(x: 0, y: 0, width: 0, height: 0);
    }
    final offset = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    if (![
          offset.dx,
          offset.dy,
          size.width,
          size.height,
        ].every((value) => value.isFinite) ||
        size.width < 0 ||
        size.height < 0 ||
        size.width == 0 ||
        size.height == 0) {
      return const SafeDiagnosticPopoverAnchor(x: 0, y: 0, width: 0, height: 0);
    }
    return SafeDiagnosticPopoverAnchor(
      x: offset.dx,
      y: offset.dy,
      width: size.width,
      height: size.height,
    );
  }

  String _normalizeErrorCode(String code) => switch (code) {
    SafeDiagnosticExportException.read => code,
    SafeDiagnosticExportException.unsafe => code,
    SafeDiagnosticExportException.write => code,
    SafeDiagnosticExportException.share => code,
    SafeDiagnosticExportException.busy => code,
    _ => SafeDiagnosticExportException.unsafe,
  };

  String _failureMessage(String code) =>
      '安全诊断操作失败（${_normalizeErrorCode(code)}）';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安全登录诊断'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final errorCode = _errorCode;
    if (errorCode != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('无法读取安全诊断'),
              const SizedBox(height: 8),
              Text(errorCode, style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _clearReports,
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空安全诊断'),
              ),
            ],
          ),
        ),
      );
    }
    final report = _report!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '安全说明',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text('此报告只包含固定的登录阶段诊断字段。完整诊断日志仅保存在本机应用私有目录，不会由此页面导出。'),
          const SizedBox(height: 18),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              Text('构建号：${report.buildNumber}'),
              Text('记录：${report.recordCount}'),
              Text(report.truncated ? '已截断：是' : '已截断：否'),
            ],
          ),
          const SizedBox(height: 18),
          if (report.recordCount == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Center(child: Text('暂无可导出的安全诊断记录')),
            )
          else ...[
            const Text(
              '安全报告预览',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SelectableText(
              report.content,
              key: const ValueKey<String>('safe-diagnostic-preview'),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
          const SizedBox(height: 22),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: report.recordCount == 0 ? null : _copyReport,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制安全报告'),
              ),
              OutlinedButton.icon(
                onPressed: _clearReports,
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空安全诊断'),
              ),
              FilledButton.icon(
                key: _exportButtonKey,
                onPressed: report.recordCount == 0 || _sharing
                    ? null
                    : _shareReport,
                icon: _nativeSharing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share),
                label: const Text('导出安全诊断'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
