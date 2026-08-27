import 'package:media_kit/media_kit.dart';

import '../core/diagnostic_log.dart';
import 'cache/native_playback_property_access.dart';
import 'cache/playback_cache_capabilities.dart';
import 'cache/playback_cache_engine.dart';
import 'cache/playback_cache_policy.dart';
import 'cache/playback_cache_telemetry.dart';
import 'playback_diagnostics.dart';
import 'playback_output_quiescer.dart';

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
  Future<void> quiesce();
  Future<void> quiesceForLifecycle();
  Future<void> resumeFromLifecycleQuiescence();
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

class MediaKitPlaybackEngine
    implements
        PlaybackEngine,
        PlaybackCacheEngine,
        PlaybackCacheIdentitySnapshotReader {
  MediaKitPlaybackEngine(
    this.player, {
    this.nativePropertyWriter,
    PlaybackOutputQuiescer? outputQuiescer,
    PlaybackDiagnostics? diagnostics,
  }) : _outputQuiescer =
           outputQuiescer ?? MediaKitPlaybackOutputQuiescer(player),
       _diagnostics = diagnostics ?? PlaybackDiagnostics() {
    final platform = player.platform;
    if (platform is NativePlayer) {
      _cacheEngine = NativePlaybackCacheEngine(
        access: MediaKitNativePlaybackPropertyAccess(
          platform,
          timeoutReporter: _diagnostics.nativeOperationTimeout,
        ),
        hasOpenedMedia: () => _hasOpenedMedia,
      );
    }
  }

  final Player player;
  final NativePropertyWriter? nativePropertyWriter;
  final PlaybackOutputQuiescer _outputQuiescer;
  final PlaybackDiagnostics _diagnostics;
  NativePlaybackCacheEngine? _cacheEngine;
  final Set<Future<void>> _nativeOperations = <Future<void>>{};
  bool _hasOpenedMedia = false;
  bool _retiring = false;
  bool _lifecycleQuiesced = false;
  bool _disposeStarted = false;
  int _quiescenceEpoch = 0;
  Future<void>? _pauseOutputOperation;
  Future<void>? _disposeOperation;

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get durationStream => player.stream.duration;

  @override
  Stream<Duration> get bufferStream => player.stream.buffer;

  @override
  Stream<bool> get playingStream => player.stream.playing.map(
    (playing) =>
        playing && !_retiring && !_lifecycleQuiesced && !_disposeStarted,
  );

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
  }) {
    if (_retiring || _disposeStarted) return Future<void>.value();
    final quiescenceEpoch = _quiescenceEpoch;
    _hasOpenedMedia = true;
    return _trackNativeOperation(() async {
      await player.open(
        Media(uri.toString(), httpHeaders: headers),
        play: play,
      );
      if (play && _mustReassertQuiescence(quiescenceEpoch)) {
        await _pauseOutput();
      }
    });
  }

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() {
    final cacheEngine = _cacheEngine;
    if (_disposeStarted || cacheEngine == null) {
      return Future.value(PlaybackCacheEngineCapabilities.unsupported());
    }
    return _trackNativeOperation(cacheEngine.probeCacheCapabilities);
  }

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) {
    final cacheEngine = _cacheEngine;
    if (!_disposeStarted && cacheEngine != null) {
      return _trackNativeOperation(
        () => cacheEngine.configureCache(profile, capabilities),
      );
    }
    return Future.value(
      PlaybackCacheApplyResult(
        requestedMode: profile.runtimeMode,
        actualMode: PlaybackCacheRuntimeMode.unconfirmed,
        fallbackReason: PlaybackCacheFallbackReason.engineCapabilityUnavailable,
        requiresPlayerRecreation: false,
        readBack: const {},
      ),
    );
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot() {
    final cacheEngine = _cacheEngine;
    if (_disposeStarted || cacheEngine == null) return Future.value();
    return _trackNativeOperation(cacheEngine.readCacheSnapshot);
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshotForIdentity({
    required PlaybackCacheReadIdentity identity,
    required PlaybackCacheReadIdentityCurrent isIdentityCurrent,
  }) {
    final cacheEngine = _cacheEngine;
    if (_disposeStarted || cacheEngine == null) return Future.value();
    return _trackNativeOperation(
      () => cacheEngine.readCacheSnapshotForIdentity(
        identity: identity,
        isIdentityCurrent: isIdentityCurrent,
      ),
    );
  }

  @override
  Future<void> play() {
    if (_retiring || _lifecycleQuiesced || _disposeStarted) {
      return Future<void>.value();
    }
    final quiescenceEpoch = _quiescenceEpoch;
    return _trackNativeOperation(() async {
      await player.play();
      if (_mustReassertQuiescence(quiescenceEpoch)) await _pauseOutput();
    });
  }

  @override
  Future<void> pause() {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(player.pause);
  }

  @override
  Future<void> quiesce() {
    if (_disposeStarted) {
      return _disposeOperation ?? Future<void>.value();
    }
    _retiring = true;
    _quiescenceEpoch++;
    return _pauseOutput();
  }

  @override
  Future<void> quiesceForLifecycle() {
    if (_disposeStarted) {
      return _disposeOperation ?? Future<void>.value();
    }
    _lifecycleQuiesced = true;
    _quiescenceEpoch++;
    return _pauseOutput();
  }

  @override
  Future<void> resumeFromLifecycleQuiescence() async {
    if (_retiring || _disposeStarted) return;
    _lifecycleQuiesced = false;
    _quiescenceEpoch++;
  }

  @override
  Future<void> seek(Duration position) {
    if (_retiring || _lifecycleQuiesced || _disposeStarted) {
      return Future<void>.value();
    }
    final quiescenceEpoch = _quiescenceEpoch;
    return _trackNativeOperation(() async {
      await player.seek(position);
      if (_mustReassertQuiescence(quiescenceEpoch)) await _pauseOutput();
    });
  }

  bool _mustReassertQuiescence(int operationEpoch) =>
      operationEpoch != _quiescenceEpoch || _retiring || _lifecycleQuiesced;

  Future<void> _pauseOutput() {
    final existing = _pauseOutputOperation;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _pauseOutputSafely().whenComplete(() {
      if (identical(_pauseOutputOperation, operation)) {
        _pauseOutputOperation = null;
      }
    });
    _pauseOutputOperation = operation;
    return operation;
  }

  Future<void> _pauseOutputSafely() async {
    try {
      await _outputQuiescer.pauseUrgently();
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_urgent_pause_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Future<T> _trackNativeOperation<T>(Future<T> Function() operation) {
    final nativeOperation = Future<T>.sync(operation);
    late final Future<void> completion;
    completion = nativeOperation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _nativeOperations.remove(completion));
    _nativeOperations.add(completion);
    return nativeOperation;
  }

  Future<void> _waitForNativeOperations() async {
    while (_nativeOperations.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_nativeOperations));
    }
  }

  @override
  Future<void> selectAudioTrack(String trackId) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(() async {
      final track = player.state.tracks.audio
          .where((candidate) => candidate.id == trackId)
          .firstOrNull;
      if (track == null) {
        throw StateError('Audio track $trackId is unavailable');
      }
      await player.setAudioTrack(track);
    });
  }

  @override
  Future<void> selectSubtitleTrack(String? trackId) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(() async {
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
    });
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(
      () => player.setSubtitleTrack(
        SubtitleTrack.uri(uri.toString(), title: title, language: language),
      ),
    );
  }

  @override
  Future<void> setRate(double rate) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(() => player.setRate(rate));
  }

  @override
  Future<void> setAudioDelay(Duration delay) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(
      () => _setNativeProperty('audio-delay', _seconds(delay)),
    );
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(
      () => _setNativeProperty('sub-delay', _seconds(delay)),
    );
  }

  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(() async {
      await _setNativeProperty('sub-font-size', fontSize.toStringAsFixed(1));
      await _setNativeProperty('sub-color', _mpvColor(color));
      await _setNativeProperty('sub-border-color', _mpvColor(outlineColor));
      await _setNativeProperty('sub-pos', position.clamp(0, 100).toString());
    });
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
  Future<void> stop() {
    if (_disposeStarted) return Future<void>.value();
    return _trackNativeOperation(player.stop);
  }

  @override
  Future<void> dispose() {
    final existing = _disposeOperation;
    if (existing != null) return existing;
    final wasRetiring = _retiring;
    _disposeStarted = true;
    if (!wasRetiring) {
      _retiring = true;
      _quiescenceEpoch++;
    }
    final quiescence =
        _pauseOutputOperation ?? (wasRetiring ? null : _pauseOutput());
    final operation = _dispose(quiescence);
    _disposeOperation = operation;
    return operation;
  }

  Future<void> _dispose(Future<void>? quiescence) async {
    if (quiescence != null) await quiescence;
    await _waitForNativeOperations();
    _cacheEngine?.dispose();
    await player.dispose();
  }
}
