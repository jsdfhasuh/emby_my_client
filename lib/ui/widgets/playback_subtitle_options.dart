import 'package:flutter/material.dart';

import '../../playback/playback_state.dart';
import '../../playback/track_mapper.dart';

class PlaybackSubtitleOptions extends StatelessWidget {
  const PlaybackSubtitleOptions({
    required this.tracks,
    required this.playbackState,
    required this.onSelect,
    super.key,
  });

  final List<PlaybackTrack> tracks;
  final PlaybackState playbackState;
  final void Function(int? streamIndex) onSelect;

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
        onTap: _isApplying || _isSubtitleDisabled
            ? null
            : () {
                Navigator.pop(context);
                onSelect(null);
              },
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
                  Navigator.pop(context);
                  onSelect(track.index);
                },
        ),
    ],
  );
}
