import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import '../playback/horizontal_scrub_mapping.dart';
import '../playback/playback_settings.dart';
import '../playback/playback_settings_repository.dart';
import '../playback/seek_preview_mode.dart';

const _bitrateOptions = <(int, String)>[
  (120000000, '原画'),
  (40000000, '40 Mbps'),
  (20000000, '20 Mbps'),
  (10000000, '10 Mbps'),
  (5000000, '5 Mbps'),
  (2000000, '2 Mbps'),
];
const _rateOptions = <(double, String)>[
  (0.5, '0.5×'),
  (1, '1×'),
  (1.5, '1.5×'),
  (2, '2×'),
];
const _fitOptions = <(String, String)>[
  ('contain', '适应'),
  ('cover', '裁剪'),
  ('fill', '填充'),
];
const _delayOptions = <(int, String)>[
  (-1000, '-1.0 秒'),
  (-500, '-0.5 秒'),
  (0, '0 秒'),
  (500, '+0.5 秒'),
  (1000, '+1.0 秒'),
];
const _fontSizeOptions = <(double, String)>[
  (32, '小'),
  (42, '中'),
  (52, '大'),
  (64, '特大'),
];
const _subtitlePositionOptions = <(int, String)>[
  (75, '偏上'),
  (88, '居中'),
  (100, '底部'),
];
const _seekPreviewModeOptions = <(SeekPreviewMode, String)>[
  (SeekPreviewMode.serverOnly, '服务器缩略图'),
  (SeekPreviewMode.off, '关闭画面预览'),
];

class PlaybackPreferencesScreen extends StatefulWidget {
  const PlaybackPreferencesScreen({
    super.key,
    required this.session,
    required this.repository,
  });

  final EmbySession session;
  final PlaybackSettingsRepository repository;

  @override
  State<PlaybackPreferencesScreen> createState() =>
      _PlaybackPreferencesScreenState();
}

class _PlaybackPreferencesScreenState extends State<PlaybackPreferencesScreen> {
  PlaybackSettings _settings = const PlaybackSettings();
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await widget.repository.load(widget.session);
      if (!mounted) return;
      setState(() {
        _settings = snapshot.settings;
        _loading = false;
        _loadFailed = false;
      });
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback-settings',
        'Playback preferences load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _retryLoad() async {
    if (_loading || _saving) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    await _load();
  }

  Future<void> _save() async {
    if (_loading || _loadFailed || _saving) return;
    setState(() => _saving = true);
    try {
      final snapshot = await widget.repository.patch(
        widget.session,
        PlaybackSettingsPatch(
          maxStreamingBitrate: _settings.maxStreamingBitrate,
          seekBackwardSeconds: _settings.seekBackwardSeconds,
          seekForwardSeconds: _settings.seekForwardSeconds,
          horizontalSwipeSeekSpanSeconds:
              _settings.horizontalSwipeSeekSpanSeconds,
          seekPreviewMode: _settings.seekPreviewMode,
          playbackRate: _settings.playbackRate,
          videoFit: _settings.videoFit,
          subtitleDelayMilliseconds: _settings.subtitleDelayMilliseconds,
          audioDelayMilliseconds: _settings.audioDelayMilliseconds,
          subtitleFontSize: _settings.subtitleFontSize,
          subtitleColor: _settings.subtitleColor,
          subtitleOutlineColor: _settings.subtitleOutlineColor,
          subtitlePosition: _settings.subtitlePosition,
        ),
      );
      if (!mounted) return;
      setState(() => _settings = snapshot.settings);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存，将从下次播放生效')));
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback-settings',
        'Playback preferences save failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放设置保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放设置'),
        actions: [
          TextButton(
            key: const ValueKey('save-playback-preferences'),
            onPressed: _loading || _loadFailed || _saving ? null : _save,
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
          : _loadFailed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 42),
                  const SizedBox(height: 12),
                  const Text('播放设置读取失败'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('retry-playback-preferences'),
                    onPressed: _retryLoad,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionTitle(context, '画质'),
                        _responsiveFields([
                          _dropdown<int>(
                            key: const ValueKey('playback-bitrate'),
                            label: '默认画质',
                            icon: Icons.network_check,
                            value: _settings.maxStreamingBitrate,
                            options: _bitrateOptions,
                            onChanged: (value) => _update(
                              _settings.copyWith(maxStreamingBitrate: value),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 28),
                        _sectionTitle(context, '播放'),
                        _responsiveFields([
                          _dropdown<double>(
                            key: const ValueKey('playback-rate'),
                            label: '播放速度',
                            icon: Icons.speed,
                            value: _settings.playbackRate,
                            options: _rateOptions,
                            onChanged: (value) => _update(
                              _settings.copyWith(playbackRate: value),
                            ),
                          ),
                          _dropdown<String>(
                            key: const ValueKey('playback-video-fit'),
                            label: '画面模式',
                            icon: Icons.fit_screen,
                            value: _settings.videoFit,
                            options: _fitOptions,
                            onChanged: (value) =>
                                _update(_settings.copyWith(videoFit: value)),
                          ),
                          _dropdown<int>(
                            key: const ValueKey('playback-seek-backward'),
                            label: '按钮/双击快退',
                            icon: Icons.fast_rewind,
                            value: _settings.seekBackwardSeconds,
                            options: [
                              for (final seconds
                                  in playbackSeekStepSecondsOptions)
                                (seconds, '$seconds 秒'),
                            ],
                            onChanged: (value) => _update(
                              _settings.copyWith(seekBackwardSeconds: value),
                            ),
                          ),
                          _dropdown<int>(
                            key: const ValueKey('playback-seek-forward'),
                            label: '按钮/双击快进',
                            icon: Icons.fast_forward,
                            value: _settings.seekForwardSeconds,
                            options: [
                              for (final seconds
                                  in playbackSeekStepSecondsOptions)
                                (seconds, '$seconds 秒'),
                            ],
                            onChanged: (value) => _update(
                              _settings.copyWith(seekForwardSeconds: value),
                            ),
                          ),
                          _dropdown<int>(
                            key: const ValueKey(
                              'playback-horizontal-swipe-span',
                            ),
                            label: '横向滑动跨度',
                            icon: Icons.swap_horiz,
                            value: _settings.horizontalSwipeSeekSpanSeconds,
                            options: [
                              for (final seconds
                                  in horizontalSwipeSeekSpanOptions)
                                (seconds, _seekSpanLabel(seconds)),
                            ],
                            onChanged: (value) => _update(
                              _settings.copyWith(
                                horizontalSwipeSeekSpanSeconds: value,
                              ),
                            ),
                          ),
                          _dropdown<SeekPreviewMode>(
                            key: const ValueKey('playback-seek-preview-mode'),
                            label: '滑动预览画面',
                            icon: Icons.photo_library_outlined,
                            value: _settings.seekPreviewMode.normalized,
                            options: _seekPreviewModeOptions,
                            helperText: '服务器未生成 Trickplay 时，仅显示时间与进度。',
                            onChanged: (value) => _update(
                              _settings.copyWith(seekPreviewMode: value),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 28),
                        _sectionTitle(context, '同步'),
                        _responsiveFields([
                          _dropdown<int>(
                            key: const ValueKey('playback-audio-delay'),
                            label: '音频延迟',
                            icon: Icons.graphic_eq,
                            value: _settings.audioDelayMilliseconds,
                            options: _delayOptions,
                            onChanged: (value) => _update(
                              _settings.copyWith(audioDelayMilliseconds: value),
                            ),
                          ),
                          _dropdown<int>(
                            key: const ValueKey('playback-subtitle-delay'),
                            label: '字幕延迟',
                            icon: Icons.subtitles_outlined,
                            value: _settings.subtitleDelayMilliseconds,
                            options: _delayOptions,
                            onChanged: (value) => _update(
                              _settings.copyWith(
                                subtitleDelayMilliseconds: value,
                              ),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 28),
                        _sectionTitle(context, '字幕样式'),
                        _responsiveFields([
                          _dropdown<double>(
                            key: const ValueKey('playback-subtitle-size'),
                            label: '字幕字号',
                            icon: Icons.format_size,
                            value: _settings.subtitleFontSize,
                            options: _fontSizeOptions,
                            onChanged: (value) => _update(
                              _settings.copyWith(subtitleFontSize: value),
                            ),
                          ),
                          _dropdown<int>(
                            key: const ValueKey('playback-subtitle-position'),
                            label: '字幕位置',
                            icon: Icons.vertical_align_bottom,
                            value: _settings.subtitlePosition,
                            options: _subtitlePositionOptions,
                            onChanged: (value) => _update(
                              _settings.copyWith(subtitlePosition: value),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 16),
                        _colorSelector(
                          keyPrefix: 'playback-subtitle-color',
                          label: '字幕颜色',
                          icon: Icons.palette_outlined,
                          selected: _settings.subtitleColor,
                          options: const [
                            (0xFFFFFFFF, '白色'),
                            (0xFFFFFF00, '黄色'),
                            (0xFF80CBC4, '青色'),
                          ],
                          onChanged: (value) =>
                              _update(_settings.copyWith(subtitleColor: value)),
                        ),
                        const SizedBox(height: 12),
                        _colorSelector(
                          keyPrefix: 'playback-subtitle-outline',
                          label: '字幕描边',
                          icon: Icons.format_color_text,
                          selected: _settings.subtitleOutlineColor,
                          options: const [
                            (0xFF000000, '黑色'),
                            (0xFF404040, '深灰'),
                            (0xFFFFFFFF, '白色'),
                          ],
                          onChanged: (value) => _update(
                            _settings.copyWith(subtitleOutlineColor: value),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  void _update(PlaybackSettings settings) {
    if (_saving) return;
    setState(() => _settings = settings);
  }

  Widget _sectionTitle(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );

  Widget _responsiveFields(List<Widget> fields) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 700 ? 2 : 1;
      final width = columns == 2
          ? (constraints.maxWidth - 12) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final field in fields) SizedBox(width: width, child: field),
        ],
      );
    },
  );

  Widget _dropdown<T>({
    required Key key,
    required String label,
    required IconData icon,
    required T value,
    required List<(T, String)> options,
    required ValueChanged<T> onChanged,
    String? helperText,
  }) {
    final hasCurrentValue = options.any((option) => option.$1 == value);
    return DropdownButtonFormField<T>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
      items: [
        if (!hasCurrentValue)
          DropdownMenuItem<T>(value: value, child: const Text('当前值')),
        for (final option in options)
          DropdownMenuItem<T>(
            value: option.$1,
            child: Text(option.$2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _saving
          ? null
          : (next) {
              if (next != null) onChanged(next);
            },
    );
  }

  Widget _colorSelector({
    required String keyPrefix,
    required String label,
    required IconData icon,
    required int selected,
    required List<(int, String)> options,
    required ValueChanged<int> onChanged,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Expanded(child: Text(label)),
      Wrap(
        spacing: 2,
        children: [
          for (final option in options)
            IconButton(
              key: ValueKey('$keyPrefix-${option.$1}'),
              tooltip: option.$2,
              onPressed: _saving ? null : () => onChanged(option.$1),
              icon: Icon(
                option.$1 == selected ? Icons.check_circle : Icons.circle,
                color: Color(option.$1),
                shadows: const [
                  Shadow(color: Colors.black54, blurRadius: 2),
                  Shadow(color: Colors.white38, blurRadius: 1),
                ],
              ),
            ),
        ],
      ),
    ],
  );
}

String _seekSpanLabel(int seconds) =>
    seconds < 60 ? '$seconds 秒' : '${seconds ~/ 60} 分钟';

String playbackPreferencesSummary(PlaybackSettings settings) {
  final bitrate = _bitrateOptions
      .where((option) => option.$1 == settings.maxStreamingBitrate)
      .firstOrNull
      ?.$2;
  final rate = _rateOptions
      .where((option) => option.$1 == settings.playbackRate)
      .firstOrNull
      ?.$2;
  return '${bitrate ?? '自定义画质'} · ${rate ?? '${settings.playbackRate}×'} · '
      '双击 ${settings.seekBackwardSeconds}/${settings.seekForwardSeconds} 秒';
}
