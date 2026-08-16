import 'package:flutter/material.dart';

import '../../playback/cache/playback_cache_policy.dart';
import '../../playback/cache/playback_cache_settings.dart';
import '../../playback/playback_state.dart';
import '../playback_cache_settings_screen.dart';

class PlaybackCacheStatusSection extends StatelessWidget {
  const PlaybackCacheStatusSection({
    super.key,
    required this.settings,
    required this.state,
  });

  final PlaybackCacheSettings settings;
  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    final profile = state.cacheProfile;
    final observation = state.cacheObservation;
    final fileBytes = observation?.engineSnapshot?.fileCacheBytes;
    return Column(
      key: const ValueKey('playback-cache-status'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        Text(
          '播放缓存',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        _line(
          '缓存模式',
          '${playbackCacheModeLabel(settings.mode).replaceAll('（推荐）', '')}（${_runtimeModeLabel(state.cacheRuntimeMode)}）',
        ),
        if (profile == null)
          _line('实际缓存范围', '暂不可用')
        else ...[
          if (profile.sessionTargetBytes > 0)
            _line('本次目标', formatPlaybackCacheBytes(profile.sessionTargetBytes)),
          _line(
            '前向目标',
            formatPlaybackCacheTime(profile.forwardTarget.inSeconds),
          ),
          _line(
            '后向目标',
            formatPlaybackCacheTime(profile.backwardTarget.inSeconds),
          ),
          if (observation?.actualForward == null &&
              observation?.actualBackward == null)
            _line('实际缓存范围', '暂不可用')
          else ...[
            _line('实际可前向 Seek', _actualDuration(observation?.actualForward)),
            _line('实际可回退', _actualDuration(observation?.actualBackward)),
          ],
          if (fileBytes != null)
            _line('文件缓存已使用', formatPlaybackCacheBytes(fileBytes)),
          _line(
            '状态',
            state.cacheFallbackReason == PlaybackCacheFallbackReason.none
                ? '正常'
                : '已安全降级',
          ),
          if (state.cacheFallbackReason != PlaybackCacheFallbackReason.none)
            _line('原因', _fallbackReasonLabel(state.cacheFallbackReason)),
        ],
      ],
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(color: Color(0xFFB8C1C3)),
          ),
        ),
      ],
    ),
  );
}

String _runtimeModeLabel(PlaybackCacheRuntimeMode mode) => switch (mode) {
  PlaybackCacheRuntimeMode.disabled => '已关闭',
  PlaybackCacheRuntimeMode.memory => '内存',
  PlaybackCacheRuntimeMode.disk => '磁盘',
  PlaybackCacheRuntimeMode.memoryFallback => '内存降级',
  PlaybackCacheRuntimeMode.unconfirmed => '待确认',
};

String _actualDuration(Duration? value) =>
    value == null ? '暂不可用' : '约 ${formatPlaybackCacheTime(value.inSeconds)}';

String _fallbackReasonLabel(PlaybackCacheFallbackReason reason) =>
    switch (reason) {
      PlaybackCacheFallbackReason.none => '无',
      PlaybackCacheFallbackReason.offlineMedia => '离线媒体无需网络缓存',
      PlaybackCacheFallbackReason.liveOrUnknownLength => '直播或媒体时长未知',
      PlaybackCacheFallbackReason.segmentedTransport => '当前传输类型不使用磁盘缓存',
      PlaybackCacheFallbackReason.insufficientSpace => '可用空间不足',
      PlaybackCacheFallbackReason.storageCapacityUnknown => '无法确认可用空间',
      PlaybackCacheFallbackReason.directoryUnavailable => '缓存目录不可用',
      PlaybackCacheFallbackReason.engineCapabilityUnavailable => '播放器能力不支持',
      PlaybackCacheFallbackReason.mpvCacheCreateFailed => '磁盘缓存创建失败',
      PlaybackCacheFallbackReason.actualModeUnconfirmed => '实际缓存模式无法确认',
      PlaybackCacheFallbackReason.targetTooSmallForMinimumWindow =>
        '会话目标不足以满足最小缓存窗口',
      PlaybackCacheFallbackReason.metadataBudgetLimited => '内存元数据预算受限',
      PlaybackCacheFallbackReason.sessionBudgetReached => '已达到会话缓存目标',
      PlaybackCacheFallbackReason.fullReadAheadInsufficientSpace =>
        '持续预读所需空间不足，已使用有限窗口',
      PlaybackCacheFallbackReason.lowSpace => '设备空间不足',
      PlaybackCacheFallbackReason.memoryPressure => '系统内存压力',
    };
