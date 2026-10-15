import 'package:flutter/material.dart';

import '../../playback/playback_state.dart';
import '../../playback/track_mapper.dart';
import '../../playback/subtitle_target.dart';

class PlaybackSubtitleOptions extends StatelessWidget {
  const PlaybackSubtitleOptions({
    required this.tracks,
    required this.playbackState,
    required this.onSelect,
    this.nativeTracks = const [],
    this.localAssets = const [],
    this.onSelectNative,
    this.onSelectLocal,
    super.key,
  });

  final List<PlaybackTrack> tracks;
  final PlaybackState playbackState;
  final void Function(int? streamIndex) onSelect;
  final List<NativeSubtitleTrack> nativeTracks;
  final List<LocalExternalAsset> localAssets;
  final void Function(NativeSubtitleTrack)? onSelectNative;
  final void Function(LocalExternalAsset)? onSelectLocal;

  bool get _isApplying =>
      playbackState.subtitleSelectionStatus == SubtitleSelectionStatus.applying;

  bool get _isSubtitleDisabled =>
      playbackState.subtitleSelectionStatus ==
          SubtitleSelectionStatus.disabled ||
      playbackState.subtitleSelectionStatus ==
          SubtitleSelectionStatus.appliedNone;

  bool _isTrackApplied(PlaybackTrack track) =>
      track.index == playbackState.appliedSubtitleStreamIndex &&
      (playbackState.subtitleSelectionStatus ==
              SubtitleSelectionStatus.appliedEmbedded ||
          playbackState.subtitleSelectionStatus ==
              SubtitleSelectionStatus.appliedExternal ||
          playbackState.subtitleSelectionStatus ==
              SubtitleSelectionStatus.appliedServer);

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      if (playbackState.subtitleSelectionStatus ==
          SubtitleSelectionStatus.waitingForTracks)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('字幕轨道仍在加载，视频可继续播放'),
        ),
      if (playbackState.subtitleSelectionStatus ==
          SubtitleSelectionStatus.failed)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            playbackState.subtitleSelectionError ?? '字幕加载失败，请重试',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ListTile(
        leading: const Icon(Icons.subtitles_off_outlined),
        title: const Text('关闭字幕'),
        trailing: _isApplying
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : _isSubtitleDisabled
            ? const Icon(Icons.check, color: Color(0xFF80CBC4))
            : null,
        onTap: _isApplying || _isSubtitleDisabled ? null : () => onSelect(null),
      ),
      if (nativeTracks.isNotEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('当前文件字幕'),
        ),
      for (final (ordinal, target) in nativeTracks.indexed)
        ListTile(
          key: ValueKey('native-subtitle-${target.track.id}'),
          leading: const Icon(Icons.subtitles_outlined),
          title: Text(target.track.title ?? target.track.language ?? '字幕'),
          subtitle: Text(
            [
              '轨道 ${ordinal + 1}',
              ?target.track.language,
              ?target.track.codec?.toUpperCase(),
            ].join(' · '),
          ),
          trailing:
              playbackState.appliedNativeSubtitleId == target.track.id &&
                  playbackState.subtitleSelectionStatus ==
                      SubtitleSelectionStatus.appliedEmbedded
              ? const Icon(Icons.check, color: Color(0xFF80CBC4))
              : null,
          onTap: _isApplying || onSelectNative == null
              ? null
              : () => onSelectNative!(target),
        ),
      if (nativeTracks.isNotEmpty && tracks.isNotEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('媒体库字幕'),
        ),
      for (final track in tracks)
        ListTile(
          leading: Icon(
            track.isExternal
                ? Icons.closed_caption_outlined
                : Icons.subtitles_outlined,
          ),
          title: Text(track.title ?? track.language ?? '字幕 ${track.index}'),
          subtitle: Text(
            [
              ?track.language,
              ?track.codec?.toUpperCase(),
              if (track.isForced) '强制',
              if (track.isDefault) '默认',
              if (track.isExternal) '外挂',
            ].join(' · '),
          ),
          trailing: _isApplying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _isTrackApplied(track)
              ? const Icon(Icons.check, color: Color(0xFF80CBC4))
              : null,
          onTap: _isApplying || _isTrackApplied(track)
              ? null
              : () {
                  final local = localAssets
                      .where((asset) => asset.index == track.index)
                      .firstOrNull;
                  if (local != null && onSelectLocal != null) {
                    onSelectLocal!(local);
                  } else {
                    onSelect(track.index);
                  }
                },
        ),
    ],
  );
}
