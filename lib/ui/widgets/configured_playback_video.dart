import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../playback/playback_settings.dart';

/// Text cues are painted by Flutter; mpv's font properties cannot style them.
/// Keep positioning outside SubtitleView (its padding is cached at initState).
class ConfiguredPlaybackVideo extends StatelessWidget {
  const ConfiguredPlaybackVideo({
    super.key,
    required this.controller,
    required this.fit,
    required this.settings,
  });
  final VideoController controller;
  final BoxFit fit;
  final PlaybackSettings settings;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Video(
        controller: controller,
        fit: fit,
        controls: NoVideoControls,
        subtitleViewConfiguration: const SubtitleViewConfiguration(
          visible: false,
        ),
      ),
      Positioned.fill(
        child: ConfiguredPlaybackSubtitles(
          controller: controller,
          settings: settings,
        ),
      ),
    ],
  );
}

/// The same subtitle layer used by the production video, independently of the
/// platform texture so its painted output can be checked without a device plugin.
class ConfiguredPlaybackSubtitles extends StatelessWidget {
  const ConfiguredPlaybackSubtitles({
    super.key,
    required this.controller,
    required this.settings,
  });
  final VideoController controller;
  final PlaybackSettings settings;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      // SubtitleView's default scale uses its own constraints. Position padding
      // must not shrink that scale: use the complete video viewport instead.
      final textScale = math.sqrt(
        ((size.maxWidth * size.maxHeight) / (1920.0 * 1080.0)).clamp(0.0, 1.0),
      );
      final bottom =
          24.0 +
          size.maxHeight *
              (100 - settings.subtitlePosition.clamp(0, 100)) /
              100;
      return IgnorePointer(
        child: Padding(
          key: const ValueKey('playback-text-subtitle-position'),
          padding: EdgeInsets.only(bottom: bottom),
          child: SubtitleView(
            // SubtitleView subscribes only in initState. A new video controller
            // needs a new subscription; style changes keep the current one.
            key: ObjectKey(controller),
            controller: controller,
            configuration: SubtitleViewConfiguration(
              textScaler: TextScaler.linear(textScale),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              style: TextStyle(
                height: 1.4,
                fontSize: settings.subtitleFontSize.clamp(16, 96).toDouble(),
                color: Color(settings.subtitleColor),
                shadows: [
                  for (final offset in const [
                    Offset(-1, -1),
                    Offset(1, -1),
                    Offset(-1, 1),
                    Offset(1, 1),
                  ])
                    Shadow(
                      color: Color(settings.subtitleOutlineColor),
                      offset: offset,
                      blurRadius: 1,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
