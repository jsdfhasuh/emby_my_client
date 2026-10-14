import 'dart:async';

import 'package:emby_my_client/playback/playback_engine.dart';

/// Only the native media boundary is fake; route tests use the real controller.
class RoutePlaybackEngine implements PlaybackEngine {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration>.broadcast(sync: true);
  final playing = StreamController<bool>.broadcast(sync: true);
  final subtitles = StreamController<List<EngineTrack>>.broadcast(sync: true);
  final audio = StreamController<List<EngineTrack>>.broadcast(sync: true);
  final subtitleSelections = <String?>[];
  final audioSelections = <String>[];
  bool failSubtitle = false;
  bool conflictingMetadata = false;
  bool isPlaying = false;
  int stops = 0;
  int disposals = 0;
  Uri? openedUri;

  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get durationStream => durations.stream;
  @override
  Stream<Duration> get bufferStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => playing.stream;
  @override
  Stream<bool> get bufferingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Stream<String> get logStream => const Stream.empty();
  @override
  Stream<List<EngineTrack>> get audioTracksStream => audio.stream;
  @override
  Stream<List<EngineTrack>> get subtitleTracksStream => subtitles.stream;

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    openedUri = uri;
    durations.add(const Duration(minutes: 10));
    subtitles.add([
      EngineTrack(
        id: '42',
        language: conflictingMetadata ? 'eng' : 'zho',
        codec: 'subrip',
      ),
    ]);
    audio.add(const [EngineTrack(id: '7', language: 'eng', codec: 'aac')]);
    if (play) await this.play();
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    playing.add(true);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    playing.add(false);
  }

  @override
  Future<void> quiesce() => pause();
  @override
  Future<void> quiesceForLifecycle() => pause();
  @override
  Future<void> resumeFromLifecycleQuiescence() => play();
  @override
  Future<void> seek(Duration position) async {
    positions.add(position);
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    audioSelections.add(trackId);
  }

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {
    subtitleSelections.add(trackId);
    if (failSubtitle) throw StateError('Synthetic native subtitle failure');
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {
    throw StateError('Route fixtures must not load external subtitles');
  }

  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setAudioDelay(Duration delay) async {}
  @override
  Future<void> setSubtitleDelay(Duration delay) async {}
  @override
  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) async {}
  @override
  Future<void> stop() async {
    stops++;
    await pause();
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await Future.wait([
      positions.close(),
      durations.close(),
      playing.close(),
      subtitles.close(),
      audio.close(),
    ]);
  }
}
