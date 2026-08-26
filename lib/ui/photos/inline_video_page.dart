import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../images/emby_image_request.dart';
import '../../playback/inline_playback_session.dart';
import '../widgets/media_widgets.dart';

class InlineVideoPage extends StatefulWidget {
  const InlineVideoPage({
    super.key,
    required this.itemId,
    required this.coverRequest,
    required this.isActive,
    required this.state,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    required this.onRetry,
    required this.onSeekInteractionChanged,
  });

  final String itemId;
  final EmbyImageRequest? coverRequest;
  final bool isActive;
  final InlinePlaybackState state;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onRetry;
  final ValueChanged<bool> onSeekInteractionChanged;

  @override
  State<InlineVideoPage> createState() => _InlineVideoPageState();
}

class _InlineVideoPageState extends State<InlineVideoPage> {
  bool _seeking = false;
  Duration _previewPosition = Duration.zero;

  InlinePlaybackState get _activeState =>
      widget.isActive && widget.state.itemId == widget.itemId
      ? widget.state
      : InlinePlaybackState(itemId: widget.itemId);

  @override
  void didUpdateWidget(covariant InlineVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_seeking && (!widget.isActive || oldWidget.itemId != widget.itemId)) {
      _finishSeekInteraction(commit: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _activeState;
    return ColoredBox(
      key: ValueKey('inline-video-page-${widget.itemId}'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!state.isReady) _buildCover(),
          if (state.isReady) _buildVideoSurface(state),
          if (state.phase == InlinePlaybackPhase.inactive) _buildInactiveIcon(),
          if (state.phase == InlinePlaybackPhase.loading)
            _buildLoadingIndicator(),
          if (state.hasError) _buildFailure(),
          if (state.isReady) ...[
            if (!state.isPlaying) _buildCenterPlay(state),
            if (state.isBuffering) _buildLoadingIndicator(),
            _buildControls(context, state),
          ],
        ],
      ),
    );
  }

  Widget _buildCover() => EmbyImage(
    request: widget.coverRequest,
    fit: BoxFit.contain,
    icon: Icons.video_library_outlined,
    fadeInDuration: Duration.zero,
  );

  Widget _buildVideoSurface(InlinePlaybackState state) {
    final controller = state.videoController;
    return ColoredBox(
      key: ValueKey('inline-video-surface-${widget.itemId}'),
      color: Colors.black,
      child: controller == null
          ? const SizedBox.expand()
          : Video(
              controller: controller,
              fit: BoxFit.contain,
              controls: NoVideoControls,
            ),
    );
  }

  Widget _buildInactiveIcon() => Center(
    child: Icon(
      Icons.play_circle_outline,
      key: ValueKey('inline-video-inactive-${widget.itemId}'),
      size: 68,
      color: Colors.white70,
    ),
  );

  Widget _buildLoadingIndicator() => Center(
    child: SizedBox.square(
      key: ValueKey('inline-video-loading-${widget.itemId}'),
      dimension: 40,
      child: const CircularProgressIndicator(strokeWidth: 3),
    ),
  );

  Widget _buildCenterPlay(InlinePlaybackState state) => Center(
    child: IconButton.filled(
      key: ValueKey('inline-video-center-play-${widget.itemId}'),
      tooltip: state.isCompleted ? '重新播放' : '播放',
      onPressed: widget.onPlay,
      iconSize: 42,
      padding: const EdgeInsets.all(16),
      icon: Icon(state.isCompleted ? Icons.replay : Icons.play_arrow),
    ),
  );

  Widget _buildFailure() => Center(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Semantics(
        container: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44, color: Colors.white70),
            const SizedBox(height: 12),
            const Text('视频加载失败，请重试', style: TextStyle(color: Colors.white)),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: ValueKey('inline-video-retry-${widget.itemId}'),
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildControls(BuildContext context, InlinePlaybackState state) {
    final duration = state.duration > Duration.zero
        ? state.duration
        : const Duration(microseconds: 1);
    final requestedPosition = _seeking ? _previewPosition : state.position;
    final position = requestedPosition < Duration.zero
        ? Duration.zero
        : requestedPosition > duration
        ? duration
        : requestedPosition;
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 72,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xB3000000),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: state.isPlaying ? '暂停' : '播放',
                  onPressed: state.isPlaying ? widget.onPause : widget.onPlay,
                  icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                Text(
                  _formatDuration(position),
                  style: const TextStyle(
                    color: Colors.white,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Expanded(
                  child: Slider(
                    key: ValueKey('inline-video-slider-${widget.itemId}'),
                    min: 0,
                    max: duration.inMicroseconds.toDouble(),
                    value: position.inMicroseconds.toDouble(),
                    onChangeStart: (value) {
                      widget.onSeekInteractionChanged(true);
                      setState(() {
                        _seeking = true;
                        _previewPosition = Duration(
                          microseconds: value.round(),
                        );
                      });
                    },
                    onChanged: (value) => setState(() {
                      _previewPosition = Duration(microseconds: value.round());
                    }),
                    onChangeEnd: (value) {
                      _previewPosition = Duration(microseconds: value.round());
                      _finishSeekInteraction(commit: true);
                    },
                  ),
                ),
                Text(
                  _formatDuration(state.duration),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (state.isBuffering) ...[
                  const SizedBox(width: 10),
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _finishSeekInteraction({required bool commit}) {
    if (!_seeking) return;
    final position = _previewPosition;
    setState(() => _seeking = false);
    widget.onSeekInteractionChanged(false);
    if (commit) widget.onSeek(position);
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }
}
