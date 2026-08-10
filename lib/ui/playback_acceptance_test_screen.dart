import 'package:flutter/material.dart';

import '../playback/playback_diagnostics_test_overrides.dart';

class PlaybackAcceptanceTestScreen extends StatefulWidget {
  const PlaybackAcceptanceTestScreen({super.key, required this.controller});

  final PlaybackDiagnosticsTestOverridesController controller;

  @override
  State<PlaybackAcceptanceTestScreen> createState() =>
      _PlaybackAcceptanceTestScreenState();
}

class _PlaybackAcceptanceTestScreenState
    extends State<PlaybackAcceptanceTestScreen> {
  int _streamBufferBytes = 0;
  int _sessionTargetBytes = 0;
  PlaybackDiagnosticsStorageSimulation _storageSimulation =
      PlaybackDiagnosticsStorageSimulation.none;
  bool _injectSeekFailure = false;
  bool _forceCacheCreateFailure = false;

  PlaybackDiagnosticsTestOverrides get _draft =>
      PlaybackDiagnosticsTestOverrides(
        streamBufferBytes: _streamBufferBytes == 0 ? null : _streamBufferBytes,
        sessionTargetBytes: _sessionTargetBytes == 0
            ? null
            : _sessionTargetBytes,
        storageSimulation: _storageSimulation,
        injectApprovedSeekFailureAfterNextExecutedSeek: _injectSeekFailure,
        forceCacheCreateFailureObservation: _forceCacheCreateFailure,
      );

  Future<void> _enable() async {
    final draft = _draft;
    if (!draft.isActive) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启用播放验收测试？'),
        content: const Text(
          '这些覆盖仅用于下一次播放，可模拟缓存和 Seek 故障。'
          '验收结束后必须清除，且不得用于普通播放。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认启用'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.controller.enable(draft);
    setState(() {});
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除全部测试覆盖？'),
        content: const Text('下一次播放将恢复使用普通缓存设置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放验收测试')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => Container(
              key: const ValueKey('playback-test-override-status'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: widget.controller.isActive
                    ? Theme.of(context).colorScheme.errorContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.controller.isActive ? '测试覆盖已启用，将由下一次播放消费' : '测试覆盖未启用',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<int>(
            key: const ValueKey('test-stream-buffer'),
            initialValue: _streamBufferBytes,
            decoration: const InputDecoration(labelText: 'stream-buffer-size'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('不覆盖')),
              DropdownMenuItem(value: 128 << 10, child: Text('128 KiB')),
              DropdownMenuItem(value: 512 << 10, child: Text('512 KiB')),
              DropdownMenuItem(value: 1 << 20, child: Text('1 MiB')),
              DropdownMenuItem(value: 2 << 20, child: Text('2 MiB')),
            ],
            onChanged: (value) =>
                setState(() => _streamBufferBytes = value ?? 0),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            key: const ValueKey('test-session-target'),
            initialValue: _sessionTargetBytes,
            decoration: const InputDecoration(labelText: '小会话缓存目标'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('不覆盖')),
              DropdownMenuItem(value: 128 << 20, child: Text('128 MiB')),
              DropdownMenuItem(value: 256 << 20, child: Text('256 MiB')),
            ],
            onChanged: (value) =>
                setState(() => _sessionTargetBytes = value ?? 0),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<PlaybackDiagnosticsStorageSimulation>(
            key: const ValueKey('test-storage-snapshot'),
            initialValue: _storageSimulation,
            decoration: const InputDecoration(labelText: '模拟存储状态'),
            items: const [
              DropdownMenuItem(
                value: PlaybackDiagnosticsStorageSimulation.none,
                child: Text('不覆盖'),
              ),
              DropdownMenuItem(
                value: PlaybackDiagnosticsStorageSimulation.lowSpace,
                child: Text('低空间'),
              ),
              DropdownMenuItem(
                value: PlaybackDiagnosticsStorageSimulation.capacityUnknown,
                child: Text('空间未知'),
              ),
            ],
            onChanged: (value) => setState(
              () => _storageSimulation =
                  value ?? PlaybackDiagnosticsStorageSimulation.none,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('下一次已执行 Seek 后注入批准故障'),
            subtitle: const Text('验证一次有界恢复，不包含媒体或账户信息'),
            value: _injectSeekFailure,
            onChanged: (value) => setState(() => _injectSeekFailure = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('模拟 cache create failed 观察'),
            subtitle: const Text('仍以播放器实际 read-back 判定运行模式'),
            value: _forceCacheCreateFailure,
            onChanged: (value) =>
                setState(() => _forceCacheCreateFailure = value),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('enable-playback-test-overrides'),
            onPressed: _draft.isActive ? _enable : null,
            icon: const Icon(Icons.science_outlined),
            label: const Text('启用测试覆盖'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('clear-playback-test-overrides'),
            onPressed: widget.controller.isActive ? _clear : null,
            icon: const Icon(Icons.delete_outline),
            label: const Text('清除全部测试覆盖'),
          ),
        ],
      ),
    );
  }
}
