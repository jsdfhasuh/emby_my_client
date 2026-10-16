import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../core/playback_diagnostic_snapshot.dart';
import '../platform/platform_capabilities.dart';
import '../playback/playback_diagnostics_test_overrides.dart';
import '../playback/playback_diagnostics_test_overrides_scope.dart';
import 'diagnostic_scope_controls.dart';
import 'full_diagnostic_export_screen.dart';
import 'playback_acceptance_test_screen.dart';
import 'safe_diagnostic_export_screen.dart';

class DiagnosticLogScreen extends StatefulWidget {
  const DiagnosticLogScreen({
    super.key,
    this.capabilities,
    this.playbackTestOverrides,
    this.playbackTraceId,
    this.readLog,
  });

  final PlatformCapabilities? capabilities;
  final PlaybackDiagnosticsTestOverridesController? playbackTestOverrides;
  final String? playbackTraceId;
  final Future<String> Function()? readLog;

  @override
  State<DiagnosticLogScreen> createState() => _DiagnosticLogScreenState();
}

class _DiagnosticLogScreenState extends State<DiagnosticLogScreen> {
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  late Future<PlaybackDiagnosticSnapshot> _future;
  late String? _playbackTraceId = widget.playbackTraceId;
  DiagnosticLogScope _scope = DiagnosticLogScope.currentPlayback;
  bool _selectionResolved = false;
  bool _loading = true;
  PlaybackDiagnosticSnapshot? _snapshot;
  PlaybackDiagnosticsTestOverridesController? _playbackTestOverrides;

  @override
  void initState() {
    super.initState();
    _future = _read();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playbackTestOverrides ??=
        widget.playbackTestOverrides ??
        PlaybackDiagnosticsTestOverridesScope.maybeOf(context);
  }

  Future<PlaybackDiagnosticSnapshot> _read() async {
    try {
      final log = await (widget.readLog ?? DiagnosticLog.instance.read)();
      final snapshot = PlaybackDiagnosticSnapshot.capture(
        log,
        scope: _scope,
        playbackTraceId: _playbackTraceId,
        resolveLatest: !_selectionResolved,
      );
      if (mounted) {
        setState(() {
          _playbackTraceId ??= snapshot.playbackTraceId;
          _selectionResolved = true;
          _snapshot = snapshot;
        });
      }
      return snapshot;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _snapshot = null;
      _future = _read();
    });
    try {
      await _future;
    } catch (_) {
      /* FutureBuilder shows the read error. */
    }
  }

  void _changeScope(DiagnosticLogScope value) {
    if (_loading || value == _scope) return;
    _scope = value;
    _refresh();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空诊断日志？'),
        content: const Text('现有播放和网络诊断记录将被删除。'),
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
    await DiagnosticLog.instance.clear();
    if (mounted) await _refresh();
  }

  void _export() {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FullDiagnosticExportScreen(
          capabilities: _capabilities,
          playbackTraceId: _playbackTraceId,
          initialScope: _scope,
          initialSnapshot: snapshot,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('诊断日志'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
        if (_playbackTestOverrides != null)
          IconButton(
            tooltip: '播放验收测试',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlaybackAcceptanceTestScreen(
                  controller: _playbackTestOverrides!,
                ),
              ),
            ),
            icon: const Icon(Icons.science_outlined),
          ),
        if ({'ios', 'android'}.contains(_capabilities.platformName))
          IconButton(
            tooltip: '安全登录诊断',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    SafeDiagnosticExportScreen(capabilities: _capabilities),
              ),
            ),
            icon: const Icon(Icons.security_outlined),
          ),
        if ({'ios', 'android'}.contains(_capabilities.platformName))
          IconButton(
            tooltip: _scope == DiagnosticLogScope.all ? '导出完整调试日志' : '导出本次播放诊断',
            onPressed: _loading || _snapshot == null ? null : _export,
            icon: const Icon(Icons.ios_share),
          ),
        IconButton(
          tooltip: '清空',
          onPressed: _loading ? null : _clear,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: DiagnosticScopeControls(
            scope: _scope,
            onChanged: _loading ? null : _changeScope,
          ),
        ),
        Expanded(
          child: FutureBuilder<PlaybackDiagnosticSnapshot>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('诊断日志读取失败，请重试'));
              }
              if (!snapshot.hasData || _loading) {
                return const Center(child: CircularProgressIndicator());
              }
              final selected = snapshot.data!;
              final log = selected.content;
              final preview = buildFullDiagnosticPreview(log);
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      selected.associationLabel,
                      key: const ValueKey('diagnostic-association'),
                    ),
                    if (_scope == DiagnosticLogScope.currentPlayback)
                      PlaybackDiagnosticSummaryCard(summary: selected.summary),
                    const Text('显示与导出均隐藏凭据。完整日志可包含服务器地址和媒体路径。'),
                    if (selected.sourceTruncated ||
                        DiagnosticLog.instance.writeFailed ||
                        DiagnosticLog.instance.droppedWrites > 0)
                      const Text('部分诊断记录未保留，播放不受影响。'),
                    if (preview != log)
                      const Text('页面仅预览最近 64 KiB，导出保留完整的有界快照。'),
                    const SizedBox(height: 10),
                    if (log.isEmpty)
                      Text(
                        _scope == DiagnosticLogScope.currentPlayback
                            ? '暂无可关联的本次播放记录。可选择全部日志查看其他诊断。'
                            : '暂无诊断记录',
                      ),
                    SelectableText(
                      preview,
                      key: const ValueKey('diagnostic-preview'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
