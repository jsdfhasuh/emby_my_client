import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import '../playback/cache/playback_cache_settings.dart';
import '../playback/cache/playback_cache_storage.dart';
import '../playback/playback_settings_repository.dart';

typedef PlaybackCacheSpaceProbe = Future<int?> Function();

class PlaybackCacheSettingsScreen extends StatefulWidget {
  const PlaybackCacheSettingsScreen({
    super.key,
    required this.session,
    required this.repository,
    required this.storage,
    this.spaceProbe,
  });

  final EmbySession session;
  final PlaybackSettingsRepository repository;
  final PlaybackCacheStorage storage;
  final PlaybackCacheSpaceProbe? spaceProbe;

  @override
  State<PlaybackCacheSettingsScreen> createState() =>
      _PlaybackCacheSettingsScreenState();
}

class _PlaybackCacheSettingsScreenState
    extends State<PlaybackCacheSettingsScreen> {
  PlaybackCacheSettings _settings = const PlaybackCacheSettings();
  bool _loading = true;
  bool _saving = false;
  int? _availableBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([
        widget.repository.load(widget.session),
        (widget.spaceProbe ?? _probeSpace)(),
      ]);
      if (!mounted) return;
      setState(() {
        _settings = (results[0] as PlaybackSettingsSnapshot).settings.cache;
        _availableBytes = results[1] as int?;
        _loading = false;
      });
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback-cache',
        'Playback cache settings load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<int?> _probeSpace() async {
    PlaybackCacheSession? session;
    try {
      final snapshot = await widget.storage.prepareSession();
      session = snapshot.session;
      return snapshot.isAvailable ? snapshot.freeBytes : null;
    } catch (_) {
      return null;
    } finally {
      if (session != null) {
        try {
          await widget.storage.cleanupSession(session);
        } catch (_) {
          // A settings-only capacity probe must remain best-effort.
        }
      }
    }
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() => _saving = true);
    try {
      final snapshot = await widget.repository.patch(
        widget.session,
        PlaybackSettingsPatch(cache: _settings),
      );
      if (!mounted) return;
      setState(() => _settings = snapshot.settings.cache);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存，将从下次播放生效')));
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback-cache',
        'Playback cache settings save failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('缓存设置保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _selectMode(PlaybackCacheMode mode, bool selected) {
    if (!selected || mode == _settings.mode || _saving) return;
    setState(() => _settings = _settings.copyWith(mode: mode));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放缓存'),
        actions: [
          TextButton(
            key: const ValueKey('save-playback-cache-settings'),
            onPressed: _loading || _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  '缓存模式',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in PlaybackCacheMode.values.where(
                      (mode) => mode != PlaybackCacheMode.fullReadAhead,
                    ))
                      ChoiceChip(
                        key: ValueKey('cache-mode-${mode.name}'),
                        label: Text(playbackCacheModeLabel(mode)),
                        selected: _settings.mode == mode,
                        onSelected: (selected) => _selectMode(mode, selected),
                      ),
                  ],
                ),
                if (_settings.mode == PlaybackCacheMode.custom) ...[
                  const SizedBox(height: 28),
                  Text(
                    '自定义目标',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _secondsField(
                    key: const ValueKey('cache-custom-forward'),
                    label: '前向缓存目标',
                    value: _settings.customForwardSeconds,
                    values: const [30, 60, 90, 120, 180, 300, 600, 900],
                    onChanged: (value) => setState(
                      () => _settings = _settings.copyWith(
                        customForwardSeconds: value,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _secondsField(
                    key: const ValueKey('cache-custom-backward'),
                    label: '后向缓存目标',
                    value: _settings.customBackwardSeconds,
                    values: const [15, 30, 60, 90, 120, 180, 300, 600],
                    onChanged: (value) => setState(
                      () => _settings = _settings.copyWith(
                        customBackwardSeconds: value,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _bytesField(
                    key: const ValueKey('cache-custom-session-target'),
                    label: '最大会话缓存目标',
                    value: _settings.customSessionTargetBytes,
                    values: const [
                      128 << 20,
                      256 << 20,
                      512 << 20,
                      1 << 30,
                      2 << 30,
                      4 << 30,
                    ],
                    onChanged: (value) => setState(
                      () => _settings = _settings.copyWith(
                        customSessionTargetBytes: value,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _bytesField(
                    key: const ValueKey('cache-reserved-space'),
                    label: '设备保留空间',
                    value: _settings.reservedFreeBytes,
                    values: const [
                      1 << 30,
                      2 << 30,
                      3 << 30,
                      4 << 30,
                      6 << 30,
                      8 << 30,
                    ],
                    onChanged: (value) => setState(
                      () => _settings = _settings.copyWith(
                        reservedFreeBytes: value,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                Text(
                  '当前设备',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _availableBytes == null
                      ? '可用于缓存的空间：无法确认'
                      : '可用于缓存的空间：约 ${formatPlaybackCacheBytes(_availableBytes!)}',
                  key: const ValueKey('playback-cache-free-space'),
                ),
                const SizedBox(height: 28),
                Text(
                  '说明',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text('缓存仅在当前媒体播放会话有效，退出后释放。'),
                const SizedBox(height: 6),
                const Text('后向时间为目标，实际范围取决于媒体格式和播放器缓存状态。'),
              ],
            ),
    );
  }

  Widget _secondsField({
    required Key key,
    required String label,
    required int value,
    required List<int> values,
    required ValueChanged<int> onChanged,
  }) => DropdownButtonFormField<int>(
    key: key,
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final item in values)
        DropdownMenuItem(
          value: item,
          child: Text(formatPlaybackCacheTime(item)),
        ),
    ],
    onChanged: _saving
        ? null
        : (next) {
            if (next != null) onChanged(next);
          },
  );

  Widget _bytesField({
    required Key key,
    required String label,
    required int value,
    required List<int> values,
    required ValueChanged<int> onChanged,
  }) => DropdownButtonFormField<int>(
    key: key,
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final item in values)
        DropdownMenuItem(
          value: item,
          child: Text(formatPlaybackCacheBytes(item)),
        ),
    ],
    onChanged: _saving
        ? null
        : (next) {
            if (next != null) onChanged(next);
          },
  );
}

String playbackCacheModeLabel(PlaybackCacheMode mode) => switch (mode) {
  PlaybackCacheMode.automatic => '自动（推荐）',
  PlaybackCacheMode.memoryOnly => '仅内存',
  PlaybackCacheMode.spaceSaving => '节省空间',
  PlaybackCacheMode.balanced => '平衡',
  PlaybackCacheMode.aggressive => '大缓存',
  PlaybackCacheMode.custom => '自定义',
  PlaybackCacheMode.fullReadAhead => '持续预读',
};

String playbackCacheSettingsSummary(PlaybackCacheSettings settings) {
  if (settings.mode == PlaybackCacheMode.automatic) {
    return '自动 · 根据可用空间动态决定';
  }
  if (settings.mode == PlaybackCacheMode.fullReadAhead) {
    return '持续预读 · 空间允许时预读至结尾';
  }
  final targets = switch (settings.mode) {
    PlaybackCacheMode.automatic => throw StateError('unreachable'),
    PlaybackCacheMode.memoryOnly => (60, 30),
    PlaybackCacheMode.spaceSaving => (90, 60),
    PlaybackCacheMode.balanced => (180, 120),
    PlaybackCacheMode.aggressive => (600, 300),
    PlaybackCacheMode.custom => (
      settings.customForwardSeconds,
      settings.customBackwardSeconds,
    ),
    PlaybackCacheMode.fullReadAhead => throw StateError('handled above'),
  };
  return '${playbackCacheModeLabel(settings.mode).replaceAll('（推荐）', '')} · '
      '前向 ${formatPlaybackCacheTime(targets.$1)} · '
      '后向 ${formatPlaybackCacheTime(targets.$2)}';
}

String formatPlaybackCacheTime(int seconds) {
  if (seconds % 60 == 0) return '${seconds ~/ 60} 分钟';
  if (seconds > 60) return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  return '$seconds 秒';
}

String formatPlaybackCacheBytes(int bytes) {
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  if (bytes >= gib) {
    final value = bytes / gib;
    return '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} GB';
  }
  return '${(bytes / mib).round()} MB';
}
