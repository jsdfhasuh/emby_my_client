import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../platform/platform_capabilities.dart';
import '../playback/playback_diagnostics_test_overrides.dart';
import '../playback/playback_diagnostics_test_overrides_scope.dart';
import 'full_diagnostic_export_screen.dart';
import 'playback_acceptance_test_screen.dart';
import 'safe_diagnostic_export_screen.dart';

class DiagnosticLogScreen extends StatefulWidget {
  const DiagnosticLogScreen({
    super.key,
    this.capabilities,
    this.playbackTestOverrides,
  });

  final PlatformCapabilities? capabilities;
  final PlaybackDiagnosticsTestOverridesController? playbackTestOverrides;

  @override
  State<DiagnosticLogScreen> createState() => _DiagnosticLogScreenState();
}

class _DiagnosticLogScreenState extends State<DiagnosticLogScreen> {
  late final PlatformCapabilities _capabilities =
      widget.capabilities ?? PlatformCapabilities.current();
  late Future<String> _future;
  PlaybackDiagnosticsTestOverridesController? _playbackTestOverrides;

  @override
  void initState() {
    super.initState();
    _future = DiagnosticLog.instance.read();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playbackTestOverrides ??=
        widget.playbackTestOverrides ??
        PlaybackDiagnosticsTestOverridesScope.maybeOf(context);
  }

  Future<void> _refresh() async {
    final future = DiagnosticLog.instance.read();
    setState(() {
      _future = future;
    });
    await future;
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
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refresh,
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
          if (_capabilities.platformName == 'ios')
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
          if (_capabilities.platformName == 'ios')
            IconButton(
              tooltip: '导出完整调试日志',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      FullDiagnosticExportScreen(capabilities: _capabilities),
                ),
              ),
              icon: const Icon(Icons.bug_report_outlined),
            ),
          IconButton(
            tooltip: '清空',
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final log = snapshot.data!;
          if (log.isEmpty) {
            return const Center(child: Text('暂无诊断记录'));
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '本机完整诊断（仅本机查看）',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  log,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFFD0D5D6),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
