import 'dart:async';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

typedef MediaKitFrameProbePlayerFactory = Player Function();
typedef MediaKitFrameProbeVideoControllerFactory =
    VideoController Function(Player player);

class MediaKitFrameProbeResult {
  const MediaKitFrameProbeResult({
    required this.success,
    required this.reason,
    required this.stage,
    required this.format,
    required this.openLatency,
    required this.screenshotLatency,
    this.errorType,
    this.imageBytes,
  });

  final bool success;
  final String reason;
  final String stage;
  final String? format;
  final Duration openLatency;
  final Duration screenshotLatency;
  final String? errorType;
  final Uint8List? imageBytes;

  Map<String, Object?> toSafeMap() {
    return <String, Object?>{
      'success': success,
      'reason': reason,
      'stage': stage,
      'format': format,
      'errorType': errorType,
      'openLatencyMs': openLatency.inMilliseconds,
      'screenshotLatencyMs': screenshotLatency.inMilliseconds,
      'byteLength': imageBytes?.length ?? 0,
    };
  }

  @override
  String toString() => toSafeMap().toString();
}

class MediaKitFrameProbe {
  const MediaKitFrameProbe({
    this.playerFactory = _createPlayer,
    this.videoControllerFactory = _createVideoController,
    this.clock = _now,
    this.onVideoControllerCreated,
    this.screenshotFormat = 'image/jpeg',
  });

  static const defaultOpenTimeout = Duration(seconds: 3);
  static const defaultScreenshotTimeout = Duration(seconds: 2);
  static const defaultDisposeTimeout = Duration(seconds: 2);

  final MediaKitFrameProbePlayerFactory playerFactory;
  final MediaKitFrameProbeVideoControllerFactory videoControllerFactory;
  final DateTime Function() clock;
  final void Function(VideoController controller)? onVideoControllerCreated;
  final String? screenshotFormat;

  Future<MediaKitFrameProbeResult> capture({
    required String uri,
    required Duration target,
    Map<String, String> headers = const <String, String>{},
    Duration openTimeout = defaultOpenTimeout,
    Duration screenshotTimeout = defaultScreenshotTimeout,
    Duration disposeTimeout = defaultDisposeTimeout,
  }) async {
    final startedAt = clock();
    Player? player;
    var openLatency = Duration.zero;
    var screenshotLatency = Duration.zero;
    var stage = 'create';

    try {
      player = playerFactory();
      // media_kit defaults to --vid=no, so screenshot requires this output.
      final videoController = videoControllerFactory(player);
      onVideoControllerCreated?.call(videoController);

      stage = 'open';
      await player
          .open(
            Media(
              uri,
              httpHeaders: headers.isEmpty
                  ? null
                  : Map<String, String>.unmodifiable(headers),
            ),
            play: false,
          )
          .timeout(openTimeout);
      openLatency = clock().difference(startedAt);

      stage = 'metadata';
      await player.stream.duration
          .firstWhere((duration) => duration > Duration.zero)
          .timeout(openTimeout);

      stage = 'configure';
      await player.setVolume(0);
      await player.setAudioTrack(AudioTrack.no());
      await player.setSubtitleTrack(SubtitleTrack.no());
      try {
        await videoController.setSize(width: 240, height: 135);
      } on UnsupportedError {
        // Android 2.0.1 exposes setSize but does not implement it.
      }
      stage = 'seek';
      await player.seek(target);

      stage = 'decode_frame';
      await player.play();
      await videoController.waitUntilFirstFrameRendered.timeout(
        screenshotTimeout,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      stage = 'screenshot';
      final screenshotStartedAt = clock();
      final imageBytes = await player
          .screenshot(format: screenshotFormat)
          .timeout(screenshotTimeout);
      screenshotLatency = clock().difference(screenshotStartedAt);
      await player.pause();

      if (imageBytes == null || imageBytes.isEmpty) {
        return MediaKitFrameProbeResult(
          success: false,
          reason: 'screenshot_empty',
          stage: stage,
          format: screenshotFormat,
          openLatency: openLatency,
          screenshotLatency: screenshotLatency,
        );
      }

      return MediaKitFrameProbeResult(
        success: true,
        reason: 'ready',
        stage: stage,
        format: screenshotFormat,
        openLatency: openLatency,
        screenshotLatency: screenshotLatency,
        imageBytes: imageBytes,
      );
    } on TimeoutException {
      final elapsed = clock().difference(startedAt);
      return MediaKitFrameProbeResult(
        success: false,
        reason: 'timeout',
        stage: stage,
        format: screenshotFormat,
        openLatency: openLatency == Duration.zero ? elapsed : openLatency,
        screenshotLatency: screenshotLatency,
        errorType: 'TimeoutException',
      );
    } catch (error) {
      final elapsed = clock().difference(startedAt);
      return MediaKitFrameProbeResult(
        success: false,
        reason: 'native_error',
        stage: stage,
        format: screenshotFormat,
        openLatency: openLatency == Duration.zero ? elapsed : openLatency,
        screenshotLatency: screenshotLatency,
        errorType: error.runtimeType.toString(),
      );
    } finally {
      final currentPlayer = player;
      if (currentPlayer != null) {
        try {
          await currentPlayer.stop().timeout(disposeTimeout);
        } catch (_) {
          // Disposal must remain best effort for an isolated probe.
        }
        try {
          await currentPlayer.dispose().timeout(disposeTimeout);
        } catch (_) {
          // Disposal must not mask the probe result.
        }
      }
    }
  }
}

Player _createPlayer() {
  return Player(
    configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
  );
}

VideoController _createVideoController(Player player) {
  return VideoController(player);
}

DateTime _now() => DateTime.now();
