import 'package:flutter/material.dart';

import '../core/full_diagnostic_export.dart';
import '../core/safe_diagnostic_export.dart';
import '../platform/platform_capabilities.dart';

class FullDiagnosticExportScreen extends StatefulWidget {
  const FullDiagnosticExportScreen({
    super.key,
    this.service,
    this.shareGateway,
    this.capabilities,
  });

  final FullDiagnosticExportService? service;
  final FullDiagnosticShareGateway? shareGateway;
  final PlatformCapabilities? capabilities;

  @override
  State<FullDiagnosticExportScreen> createState() =>
      _FullDiagnosticExportScreenState();
}

class _FullDiagnosticExportScreenState
    extends State<FullDiagnosticExportScreen> {
  late final FullDiagnosticExportService _service =
      widget.service ?? FullDiagnosticExportService();
  late final FullDiagnosticShareGateway _shareGateway =
      widget.shareGateway ?? const MethodChannelFullDiagnosticShareGateway();
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  final _exportButtonKey = GlobalKey();
  FullDiagnosticReport? _report;
  String? _errorCode;
  bool _loading = true;
  bool _sharing = false;

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
        _errorCode = FullDiagnosticExportException.unsafe;
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
    } on FullDiagnosticExportException catch (error) {
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
        _errorCode = FullDiagnosticExportException.unsafe;
        _loading = false;
      });
    }
  }

  Future<void> _shareReport() async {
    final report = _report;
    if (report == null || report.lineCount == 0) return;
    if (_sharing) {
      _showMessage(_failureMessage(FullDiagnosticExportException.busy));
      return;
    }
    final anchor = _readExportButtonAnchor();
    setState(() => _sharing = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('导出完整调试日志？'),
          content: const Text('完整调试日志包含播放、方向、网络和错误栈信息。系统会执行脱敏，但发送前仍请人工检查。'),
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
      final outcome = await _shareGateway.share(report, anchor: anchor);
      if (!mounted) return;
      if (outcome == FullDiagnosticShareOutcome.completed) {
        _showMessage('完整调试日志已准备分享');
      } else {
        _showMessage('已取消导出');
      }
    } on FullDiagnosticExportException catch (error) {
      if (mounted) _showMessage(_failureMessage(error.code));
    } catch (_) {
      if (mounted) {
        _showMessage(_failureMessage(FullDiagnosticExportException.share));
      }
    } finally {
      if (mounted) {
        setState(() => _sharing = false);
      } else {
        _sharing = false;
      }
    }
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
        size.width <= 0 ||
        size.height <= 0) {
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
    FullDiagnosticExportException.read => code,
    FullDiagnosticExportException.unsafe => code,
    FullDiagnosticExportException.write => code,
    FullDiagnosticExportException.share => code,
    FullDiagnosticExportException.busy => code,
    _ => FullDiagnosticExportException.unsafe,
  };

  String _failureMessage(String code) =>
      '完整调试日志操作失败（${_normalizeErrorCode(code)}）';

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('完整调试日志'),
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
              const Text('无法读取完整调试日志'),
              const SizedBox(height: 8),
              Text(errorCode, style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
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
            '发送前请检查',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text('完整调试日志包含播放、方向、网络和错误栈信息。系统会执行脱敏，但发送前仍请人工检查。'),
          const SizedBox(height: 18),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              Text('构建号：${report.buildNumber}'),
              Text('日志行：${report.lineCount}'),
              Text(report.truncated ? '已截断：是' : '已截断：否'),
            ],
          ),
          const SizedBox(height: 18),
          if (report.lineCount == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Center(child: Text('暂无完整调试日志记录')),
            )
          else ...[
            const Text(
              '完整日志预览',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SelectableText(
              report.content,
              key: const ValueKey<String>('full-diagnostic-preview'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 22),
          FilledButton.icon(
            key: _exportButtonKey,
            onPressed: report.lineCount == 0 || _sharing ? null : _shareReport,
            icon: _sharing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            label: const Text('导出完整调试日志'),
          ),
        ],
      ),
    );
  }
}
