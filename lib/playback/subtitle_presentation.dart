import 'playback_engine.dart';
import 'playback_state.dart';
import 'track_mapper.dart';

class SubtitlePresentation {
  const SubtitlePresentation({
    this.delay = false,
    this.position = false,
    this.textStyle = false,
    this.explanation = '选择并加载字幕后可调整显示',
  });
  final bool delay, position, textStyle;
  final String explanation;

  static String? activeCodec(PlaybackState state) {
    if (state.actualSubtitleCodec != null) return state.actualSubtitleCodec;
    final nativeId = state.appliedNativeSubtitleId;
    if (nativeId != null) {
      final tracks = state.subtitleTracks.where((t) => t.id == nativeId);
      return tracks.length == 1 ? tracks.single.codec : null;
    }
    final plan = state.plan;
    final index = state.appliedSubtitleStreamIndex;
    if (plan == null || index == null) return null;
    final track = const TrackMapper().findByIndex(plan, 'subtitle', index);
    if (track?.deliveryFor(plan) == SubtitleDelivery.external) {
      return track?.format ?? track?.codec;
    }
    return track?.mappingTrack(plan).codec;
  }

  factory SubtitlePresentation.fromState(PlaybackState state) {
    if (state.appliedSubtitleKind == AppliedSubtitleKind.server) {
      return const SubtitlePresentation(
        explanation: '字幕已由服务器烧录进画面，无法单独调整；可选择其他字幕',
      );
    }
    if (state.subtitleSelectionStatus !=
            SubtitleSelectionStatus.appliedEmbedded &&
        state.subtitleSelectionStatus !=
            SubtitleSelectionStatus.appliedExternal) {
      return const SubtitlePresentation();
    }
    final codec = activeCodec(state)?.toLowerCase();
    if (MediaKitPlaybackEngine.isBitmapSubtitleCodec(codec) ||
        const {'pgs', 'dvdsub', 'dvbsub'}.contains(codec)) {
      return const SubtitlePresentation(
        delay: true,
        position: true,
        explanation: '位图字幕可调时间和位置，保留原始图片尺寸、颜色与描边',
      );
    }
    if (const {
      'ass',
      'ssa',
      'srt',
      'subrip',
      'vtt',
      'webvtt',
      'text',
      'mov_text',
    }.contains(codec)) {
      return const SubtitlePresentation(
        delay: true,
        position: true,
        textStyle: true,
        explanation: '文本字幕：调整时间、字号、位置、颜色和描边',
      );
    }
    return const SubtitlePresentation(
      delay: true,
      explanation: '字幕格式尚未确认，仅开放时间调整',
    );
  }
}
