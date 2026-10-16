import 'package:flutter/material.dart';

import '../../playback/playback_state.dart';
import '../../playback/track_mapper.dart';
import '../../playback/subtitle_target.dart';
import '../../playback/subtitle_track_labels.dart';

class PlaybackSubtitleOptions extends StatelessWidget {
  const PlaybackSubtitleOptions({
    required this.tracks,
    required this.playbackState,
    required this.onSelect,
    this.nativeTracks = const [],
    this.localAssets = const [],
    this.onSelectNative,
    this.onSelectLocal,
    this.onExportDiagnostics,
    super.key,
  });

  final List<PlaybackTrack> tracks;
  final PlaybackState playbackState;
  final void Function(int? streamIndex) onSelect;
  final List<NativeSubtitleTrack> nativeTracks;
  final List<LocalExternalAsset> localAssets;
  final void Function(NativeSubtitleTrack)? onSelectNative;
  final void Function(LocalExternalAsset)? onSelectLocal;
  final VoidCallback? onExportDiagnostics;

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                playbackState.subtitleSelectionError ?? '字幕加载失败，请重试',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const Text('可重试当前字幕、切换其他字幕或关闭字幕'),
              if (onExportDiagnostics != null)
                TextButton.icon(
                  key: const ValueKey('subtitle-export-diagnostics'),
                  onPressed: onExportDiagnostics,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('导出本次日志'),
                ),
            ],
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
        onTap: _isApplying ? null : () => onSelect(null),
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
          title: Text(_nativeLabel(target, ordinal).title),
          subtitle: Text(_nativeLabel(target, ordinal).details),
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
      for (final (ordinal, track) in tracks.indexed)
        ListTile(
          key: ValueKey('server-subtitle-${track.index}-$ordinal'),
          leading: Icon(
            track.isExternal
                ? Icons.closed_caption_outlined
                : Icons.subtitles_outlined,
          ),
          title: Text(_serverLabel(track, ordinal).title),
          subtitle: Text(_serverLabel(track, ordinal).details),
          trailing: _isApplying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _isTrackApplied(track)
              ? const Icon(Icons.check, color: Color(0xFF80CBC4))
              : null,
          onTap: _isApplying || !_canSelect(track)
              ? null
              : () {
                  final matches = localAssets.where(
                    (asset) => asset.index == track.index,
                  );
                  final local = matches.length == 1 ? matches.single : null;
                  if (local != null && onSelectLocal != null) {
                    onSelectLocal!(local);
                  } else {
                    onSelect(track.index);
                  }
                },
        ),
    ],
  );

  bool _canSelect(PlaybackTrack track) =>
      tracks.where((candidate) => candidate.index == track.index).length == 1 &&
      localAssets.where((asset) => asset.index == track.index).length <= 1;

  SubtitleTrackLabel _serverLabel(PlaybackTrack track, int ordinal) =>
      labelServerSubtitle(
        track: track,
        ordinal: ordinal + 1,
        plan: playbackState.plan,
        downloaded:
            localAssets.where((asset) => asset.index == track.index).length ==
            1,
      );

  SubtitleTrackLabel _nativeLabel(NativeSubtitleTrack target, int ordinal) =>
      labelNativeSubtitle(
        track: target.track,
        ordinal: ordinal + 1,
        plan: playbackState.plan,
      );
}
