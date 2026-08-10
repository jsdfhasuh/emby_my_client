import 'package:media_kit/media_kit.dart';

import '../core/diagnostic_log.dart';
import 'cache/native_playback_property_access.dart';
import 'cache/playback_cache_capabilities.dart';
import 'cache/playback_cache_engine.dart';
import 'cache/playback_cache_policy.dart';

typedef NativePropertyWriter =
    Future<void> Function(String property, String value);

class SafeNativePropertyWriter {
  const SafeNativePropertyWriter(this.writer);

  final NativePropertyWriter writer;

  Future<void> write(String property, String value) async {
    try {
      await writer(property, value);
    } catch (error) {
      _logFailure(property, error);
    }
  }

  static void _logFailure(String property, Object error) {
    // These properties affect presentation only. An unsupported mpv
    // property must not turn a playable media source into a failed session.
    DiagnosticLog.instance.warning(
      'player',
      'Optional mpv property failed property=$property '
          'errorType=${error.runtimeType}',
    );
  }
}

class EngineTrack {
  const EngineTrack({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.channels,
    this.isDefault = false,
  });

  final String id;
  final String? title;
  final String? language;
  final String? codec;
  final int? channels;
  final bool isDefault;
}

abstract interface class PlaybackEngine {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;
  Stream<String> get logStream;
  Stream<List<EngineTrack>> get audioTracksStream;
  Stream<List<EngineTrack>> get subtitleTracksStream;

  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> selectAudioTrack(String trackId);
  Future<void> selectSubtitleTrack(String? trackId);
  Future<void> loadExternalSubtitle(Uri uri, {String? title, String? language});
  Future<void> setRate(double rate);
  Future<void> setAudioDelay(Duration delay);
  Future<void> setSubtitleDelay(Duration delay);
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  });
  Future<void> stop();
  Future<void> dispose();
}

class MediaKitPlaybackEngine implements PlaybackEngine, PlaybackCacheEngine {
  MediaKitPlaybackEngine(this.player, {this.nativePropertyWriter}) {
    final platform = player.platform;
    if (platform is NativePlayer) {
      _cacheEngine = NativePlaybackCacheEngine(
        access: MediaKitNativePlaybackPropertyAccess(platform),
        hasOpenedMedia: () => _hasOpenedMedia,
      );
    }
  }

  final Player player;
  final NativePropertyWriter? nativePropertyWriter;
  NativePlaybackCacheEngine? _cacheEngine;
  bool _hasOpenedMedia = false;

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get durationStream => player.stream.duration;

  @override
  Stream<Duration> get bufferStream => player.stream.buffer;

  @override
  Stream<bool> get playingStream => player.stream.playing;

  @override
  Stream<bool> get bufferingStream => player.stream.buffering;

  @override
  Stream<bool> get completedStream => player.stream.completed;

  @override
  Stream<String> get errorStream => player.stream.error;

  @override
  Stream<String> get logStream =>
      player.stream.log.map((log) => log.toString());

  @override
  Stream<List<EngineTrack>> get audioTracksStream => player.stream.tracks.map(
    (tracks) => tracks.audio
        .map(
          (track) => EngineTrack(
            id: track.id,
            title: track.title,
            language: track.language,
            codec: track.codec,
            channels: track.channelscount,
            isDefault: track.isDefault ?? false,
          ),
        )
        .toList(growable: false),
  );

  @override
  Stream<List<EngineTrack>> get subtitleTracksStream =>
      player.stream.tracks.map(
        (tracks) => tracks.subtitle
            .map(
              (track) => EngineTrack(
                id: track.id,
                title: track.title,
                language: track.language,
                codec: track.codec,
                isDefault: track.isDefault ?? false,
              ),
            )
            .toList(growable: false),
      );

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    _hasOpenedMedia = true;
    await player.open(Media(uri.toString(), httpHeaders: headers), play: play);
  }

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() async {
    final cacheEngine = _cacheEngine;
    if (cacheEngine != null) return cacheEngine.probeCacheCapabilities();
    return PlaybackCacheEngineCapabilities.unsupported();
  }

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) async {
    final cacheEngine = _cacheEngine;
    if (cacheEngine != null) {
      return cacheEngine.configureCache(profile, capabilities);
    }
    return PlaybackCacheApplyResult(
      requestedMode: profile.runtimeMode,
      actualMode: PlaybackCacheRuntimeMode.unconfirmed,
      fallbackReason: PlaybackCacheFallbackReason.engineCapabilityUnavailable,
      requiresPlayerRecreation: false,
      readBack: const {},
    );
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() =>
      _cacheEngine?.readCacheSnapshot() ?? Future.value();

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> selectAudioTrack(String trackId) async {
    final track = player.state.tracks.audio
        .where((candidate) => candidate.id == trackId)
        .firstOrNull;
    if (track == null) {
      throw StateError('Audio track $trackId is unavailable');
    }
    await player.setAudioTrack(track);
  }

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {
    if (trackId == null) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    final track = player.state.tracks.subtitle
        .where((candidate) => candidate.id == trackId)
        .firstOrNull;
    if (track == null) {
      throw StateError('Subtitle track $trackId is unavailable');
    }
    await player.setSubtitleTrack(track);
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) => player.setSubtitleTrack(
    SubtitleTrack.uri(uri.toString(), title: title, language: language),
  );

  @override
  Future<void> setRate(double rate) => player.setRate(rate);

  @override
  Future<void> setAudioDelay(Duration delay) =>
      _setNativeProperty('audio-delay', _seconds(delay));

  @override
  Future<void> setSubtitleDelay(Duration delay) =>
      _setNativeProperty('sub-delay', _seconds(delay));

  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {
    await _setNativeProperty('sub-font-size', fontSize.toStringAsFixed(1));
    await _setNativeProperty('sub-color', _mpvColor(color));
    await _setNativeProperty('sub-border-color', _mpvColor(outlineColor));
    await _setNativeProperty('sub-pos', position.clamp(0, 100).toString());
  }

  Future<void> _setNativeProperty(String property, String value) async {
    try {
      final writer = nativePropertyWriter;
      if (writer != null) {
        await SafeNativePropertyWriter(writer).write(property, value);
        return;
      }
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty(property, value);
      }
    } catch (error) {
      SafeNativePropertyWriter._logFailure(property, error);
    }
  }

  String _seconds(Duration duration) =>
      (duration.inMilliseconds / 1000).toStringAsFixed(3);

  String _mpvColor(int value) =>
      '#${value.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> dispose() => player.dispose();
}
