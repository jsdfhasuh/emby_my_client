import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/full_diagnostic_export.dart';
import '../core/playback_diagnostic_snapshot.dart';
import 'diagnostic_scope_controls.dart';
import '../core/safe_diagnostic_export.dart';
import '../platform/platform_capabilities.dart';

const fullDiagnosticPreviewMaxBytes = 64 * 1024;
const _fullDiagnosticPreviewOmission = '……已省略较早日志；导出文件仍包含完整的有界快照……';

String buildFullDiagnosticPreview(
  String content, {
  int maxBytes = fullDiagnosticPreviewMaxBytes,
}) {
  if (maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
  }
  if (utf8.encode(content).length <= maxBytes) return content;

  final lines = content.split('\n');
  final fixedLines =
      lines.length > 8 && lines[8].startsWith('event=diagnostic_export ')
      ? 9
      : 8;
  final headerCount = lines.length < fixedLines ? lines.length : fixedLines;
  final header = lines.take(headerCount).join('\n');
  final prefix = '$header\n$_fullDiagnosticPreviewOmission\n';
  final prefixBytes = utf8.encode(prefix).length;
  if (prefixBytes > maxBytes) {
    return _takeUtf8Prefix(_fullDiagnosticPreviewOmission, maxBytes);
  }

  final reversedTail = <String>[];
  var tailBytes = 0;
  for (var index = lines.length - 1; index >= headerCount; index--) {
    final line = lines[index];
    final additionalBytes =
        utf8.encode(line).length + (reversedTail.isEmpty ? 0 : 1);
    if (prefixBytes + tailBytes + additionalBytes > maxBytes) break;
    reversedTail.add(line);
    tailBytes += additionalBytes;
  }
  return '$prefix${reversedTail.reversed.join('\n')}';
}

String _takeUtf8Prefix(String value, int maxBytes) {
  final result = StringBuffer();
  var byteLength = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final characterBytes = utf8.encode(character).length;
    if (byteLength + characterBytes > maxBytes) break;
    result.write(character);
    byteLength += characterBytes;
  }
  return result.toString();
}

class FullDiagnosticExportScreen extends StatefulWidget {
  const FullDiagnosticExportScreen({
    super.key,
    this.service,
    this.shareGateway,
    this.capabilities,
    this.playbackTraceId,
    this.initialScope = DiagnosticLogScope.currentPlayback,
    this.initialSnapshot,
  });

  final FullDiagnosticExportService? service;
  final FullDiagnosticShareGateway? shareGateway;
  final PlatformCapabilities? capabilities;
  final String? playbackTraceId;
  final DiagnosticLogScope initialScope;
  final PlaybackDiagnosticSnapshot? initialSnapshot;

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
  String? _previewContent;
  String? _errorCode;
  bool _loading = true;
  bool _sharing = false;
  bool _previewTruncated = false;
  late DiagnosticLogScope _scope =
      widget.initialSnapshot?.scope ?? widget.initialScope;
  late String? _playbackTraceId =
      widget.playbackTraceId ?? widget.initialSnapshot?.playbackTraceId;
  bool _selectionResolved = false;

  String get _exportLabel =>
      _scope == DiagnosticLogScope.all ? '导出完整调试日志' : '导出本次播放诊断';

  @override
  void initState() {
    super.initState();
    _load(snapshot: widget.initialSnapshot);
  }

  Future<void> _load({PlaybackDiagnosticSnapshot? snapshot}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _previewContent = null;
        _previewTruncated = false;
        _errorCode = null;
      });
    }
    if (!{'ios', 'android'}.contains(_capabilities.platformName)) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _previewContent = null;
        _errorCode = FullDiagnosticExportException.unsafe;
        _loading = false;
      });
      return;
    }
    try {
      final report = await _service.buildReport(
        scope: _scope,
        playbackTraceId: _playbackTraceId,
        resolveLatest: !_selectionResolved,
        snapshot: snapshot,
      );
      final preview = buildFullDiagnosticPreview(report.content);
      if (!mounted) return;
      setState(() {
        _report = report;
        _playbackTraceId ??= report.playbackTraceId;
        if (report.scope == DiagnosticLogScope.currentPlayback) {
          _selectionResolved = true;
        }
        _previewContent = preview;
        _previewTruncated = preview != report.content;
        _loading = false;
      });
    } on FullDiagnosticExportException catch (error) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _previewContent = null;
        _errorCode = _normalizeErrorCode(error.code);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _previewContent = null;
        _errorCode = FullDiagnosticExportException.unsafe;
        _loading = false;
      });
    }
  }

  Future<void> _shareReport({bool save = false}) async {
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
          title: Text('$_exportLabel？'),
          content: Text('${report.associationLabel}\n\n$_privacyDescription'),
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
      final outcome =
          await (save
                  ? const MethodChannelFullDiagnosticShareGateway(save: true)
                  : _shareGateway)
              .share(report, anchor: anchor);
      if (!mounted) return;
      if (outcome == FullDiagnosticShareOutcome.saved) {
        _showMessage('诊断文件已保存；${report.associationLabel}');
      } else if (outcome == FullDiagnosticShareOutcome.opened) {
        _showMessage('已打开系统分享面板；请自行选择目标，未自动发送。${report.associationLabel}');
      } else if (outcome == FullDiagnosticShareOutcome.completed) {
        _showMessage('诊断日志已准备分享；${report.associationLabel}');
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

  String get _privacyDescription =>
      '导出副本会隐藏密码、Token、授权头、Cookie 和 URL 参数值。仍可能包含服务器地址、媒体标识、路径及错误栈，请预览后自行选择保存或分享目标。本地原始日志保持不变。';

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_scope == DiagnosticLogScope.all ? '完整调试日志' : '本次播放诊断'),
        actions: [
          if (_capabilities.platformName == 'android')
            IconButton(
              tooltip: _scope == DiagnosticLogScope.all
                  ? '保存完整调试日志'
                  : '保存本次播放诊断',
              onPressed: !_loading && !_sharing && (_report?.lineCount ?? 0) > 0
                  ? () => _shareReport(save: true)
                  : null,
              icon: const Icon(Icons.save_alt),
            ),
          _buildExportAction(),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading || _sharing ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildExportAction() {
    final canShare =
        !_loading &&
        _errorCode == null &&
        (_report?.lineCount ?? 0) > 0 &&
        !_sharing;
    return IconButton(
      key: _exportButtonKey,
      tooltip: _exportLabel,
      onPressed: canShare ? _shareReport : null,
      icon: _sharing
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.ios_share),
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
          DiagnosticScopeControls(
            scope: _scope,
            onChanged: _sharing
                ? null
                : (value) {
                    if (value == _scope) return;
                    setState(() => _scope = value);
                    _load();
                  },
          ),
          const SizedBox(height: 12),
          SelectableText(
            report.associationLabel,
            key: const ValueKey('export-association'),
          ),
          if (report.scope == DiagnosticLogScope.currentPlayback)
            PlaybackDiagnosticSummaryCard(summary: report.summary),
          const Text(
            '发送前请检查',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(_privacyDescription),
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Center(
                child: Text(
                  _scope == DiagnosticLogScope.all
                      ? '暂无完整调试日志记录'
                      : '暂无可关联的本次播放记录，可切换到全部日志。',
                ),
              ),
            )
          else ...[
            const Text(
              '完整日志预览',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            if (_previewTruncated) ...[
              const SizedBox(height: 6),
              const Text('为避免超长文本卡顿，页面仅预览最近 64 KiB；导出文件内容不受影响。'),
            ],
            const SizedBox(height: 8),
            SelectableText(
              _previewContent ?? '',
              key: const ValueKey<String>('full-diagnostic-preview'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
