import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import 'emby_stream_resolver.dart';
import 'playback_engine.dart';
import 'playback_session_reporter.dart';
import 'playback_state.dart';
import 'track_mapper.dart';

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.item,
    required this.engine,
    required this.resolver,
    required this.reporter,
    required this.playbackHeaders,
    int maxStreamingBitrate = 120000000,
    this.readyTimeout = const Duration(seconds: 18),
    this.resumeVerificationTimeout = const Duration(seconds: 5),
    this.progressInterval = const Duration(seconds: 10),
  }) : _maxStreamingBitrate = maxStreamingBitrate {
    _bindEngine();
  }

  final EmbyItem item;
  final PlaybackEngine engine;
  final PlaybackStreamResolver resolver;
  final PlaybackReporter reporter;
  final Map<String, String> playbackHeaders;
  final Duration readyTimeout;
  final Duration resumeVerificationTimeout;
  final Duration progressInterval;
  final TrackMapper _trackMapper = const TrackMapper();

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  PlaybackState _state = const PlaybackState();
  Completer<void>? _readyCompleter;
  Timer? _progressTimer;
  Future<void>? _shutdownOperation;
  Future<void> _reconfiguration = Future<void>.value();
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex;
  int? _selectedSubtitleStreamIndex;
  int _maxStreamingBitrate;
  int _generation = 0;
  bool _sawBuffering = false;
  bool _startupFailureSignaled = false;
  bool _disposed = false;
  bool _engineDisposed = false;
  final Map<String, DateTime> _engineLogLastWritten = {};

  PlaybackState get state => _state;
  int get maxStreamingBitrate => _maxStreamingBitrate;

  Future<void> start({
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) {
    _selectedMediaSourceId = mediaSourceId;
    _selectedAudioStreamIndex = audioStreamIndex;
    _selectedSubtitleStreamIndex = subtitleStreamIndex;
    return _startPlayback();
  }

  Future<void> _startPlayback({
    Duration? resumePosition,
    bool playAfterReady = true,
    bool forceTranscodeInitially = false,
  }) async {
    final token = ++_generation;
    _setState(
      const PlaybackState(phase: PlaybackPhase.resolving, isBuffering: true),
    );
    var forceTranscode = forceTranscodeInitially;
    var retriedWithTranscode = forceTranscodeInitially;
    var fellBackToTranscode = false;

    while (_isCurrent(token)) {
      PlaybackPlan? plan;
      try {
        plan = await resolver.resolve(
          item,
          mediaSourceId: _selectedMediaSourceId,
          audioStreamIndex: _selectedAudioStreamIndex,
          subtitleStreamIndex: _selectedSubtitleStreamIndex,
          maxStreamingBitrate: _maxStreamingBitrate,
          forceTranscode: forceTranscode,
        );
        if (!_isCurrent(token)) {
          await reporter.cleanup(plan);
          return;
        }

        reporter.activate(plan);
        _setState(
          _state.copyWith(
            phase: PlaybackPhase.opening,
            plan: plan,
            clearError: true,
            isBuffering: true,
          ),
        );
        _prepareReadyWait();
        final resume =
            resumePosition ??
            (item.resumePosition > const Duration(seconds: 10)
                ? item.resumePosition
                : Duration.zero);
        await engine.open(
          plan.uri,
          headers: plan.usesServerAuthentication
              ? playbackHeaders
              : const <String, String>{},
          play: resume == Duration.zero && playAfterReady,
        );
        _throwIfStale(token);
        _setState(
          _state.copyWith(
            phase: PlaybackPhase.waitingForReady,
            isBuffering: true,
          ),
        );
        await _waitUntilReady(token);
        _throwIfStale(token);
        if (plan.method == PlayMethod.directPlay) {
          await _applySelectedDirectPlayTracks(plan, token);
        }

        if (resume > Duration.zero) {
          final target = _clampToDuration(resume);
          _setState(_state.copyWith(phase: PlaybackPhase.seekingResume));
          await engine.seek(target);
          await _verifyResumePosition(target, token);
          _throwIfStale(token);
          if (playAfterReady) await engine.play();
        }

        _setState(
          _state.copyWith(
            phase: PlaybackPhase.ready,
            isBuffering: false,
            clearError: true,
            clearStatus: true,
          ),
        );
        try {
          await reporter.reportStart(_state.position);
        } catch (error, stackTrace) {
          DiagnosticLog.instance.error(
            'playback',
            'PlaybackStart report failed item=${item.id}',
            error: error,
            stackTrace: stackTrace,
          );
        }
        _throwIfStale(token);
        _startProgressTimer();
        DiagnosticLog.instance.info(
          'player',
          'Playback ready item=${item.id} '
              'method=${plan.method.serverValue} '
              'positionMs=${_state.position.inMilliseconds}',
        );
        return;
      } on _PlaybackCancelled {
        if (plan != null) await reporter.stop(_state.position);
        return;
      } catch (error, stackTrace) {
        if (!_isCurrent(token)) return;
        final canRetry =
            !retriedWithTranscode &&
            resolver.canForceTranscode &&
            plan != null &&
            plan.method != PlayMethod.transcode &&
            _state.phase != PlaybackPhase.ready;
        if (canRetry) {
          retriedWithTranscode = true;
          fellBackToTranscode = true;
          forceTranscode = true;
          DiagnosticLog.instance.warning(
            'player',
            'Playback did not become ready item=${item.id}; '
                'retrying once with Transcode: $error',
          );
          _setState(
            _state.copyWith(
              phase: PlaybackPhase.retryingWithTranscode,
              isBuffering: true,
              statusMessage: '直连失败，正在切换到服务器转码…',
            ),
          );
          try {
            await engine.stop();
          } catch (_) {}
          await reporter.stop(_state.position);
          continue;
        }

        DiagnosticLog.instance.error(
          'player',
          'Failed to initialize playback item=${item.id}',
          error: error,
          stackTrace: stackTrace,
        );
        if (_isCurrent(token)) {
          final friendly = friendlyPlaybackError(error);
          _setState(
            _state.copyWith(
              phase: PlaybackPhase.failed,
              isBuffering: false,
              errorMessage: fellBackToTranscode
                  ? '直连失败，服务器转码也不可用：$friendly'
                  : friendly,
              clearStatus: true,
            ),
          );
        }
        try {
          await engine.stop();
        } catch (stopError, stopStackTrace) {
          DiagnosticLog.instance.error(
            'player',
            'Failed to stop player after startup failure item=${item.id}',
            error: stopError,
            stackTrace: stopStackTrace,
          );
        }
        if (plan != null) await reporter.stop(_state.position);
        return;
      }
    }
  }

  Future<void> playOrPause() async {
    if (_state.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    if (!_state.isPlaying) await engine.play();
    await _reportProgress();
  }

  Future<void> pause() async {
    if (_state.isPlaying) await engine.pause();
    await _reportProgress();
  }

  Future<void> pauseForLifecycle() async {
    await pause();
  }

  Future<void> seek(Duration position) async {
    final target = _clampToDuration(position);
    await engine.seek(target);
    _setState(_state.copyWith(position: target));
    await _reportProgress();
  }

  Future<void> seekRelative(Duration offset) => seek(_state.position + offset);

  Future<void> selectMediaSource(String mediaSourceId) =>
      reconfigure(mediaSourceId: mediaSourceId);

  Future<void> setMaximumBitrate(int bitrate) =>
      reconfigure(maxStreamingBitrate: bitrate);

  Future<void> selectAudioStream(int streamIndex) async {
    final plan = _state.plan;
    if (plan == null || plan.audioStreamIndex == streamIndex) return;
    final serverTrack = _trackMapper.findByIndex(plan, 'audio', streamIndex);
    if (plan.method == PlayMethod.directPlay) {
      await _waitForTracks(audio: true);
    }
    final engineTrackId = serverTrack == null
        ? null
        : _trackMapper.engineTrackId(serverTrack, _state.audioTracks);
    if (plan.method == PlayMethod.directPlay && engineTrackId != null) {
      await engine.selectAudioTrack(engineTrackId);
      _selectedAudioStreamIndex = streamIndex;
      final updated = plan.copyWith(audioStreamIndex: streamIndex);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }
    await reconfigure(
      audioStreamIndex: streamIndex,
      forceTranscode: plan.method == PlayMethod.directPlay,
    );
  }

  Future<void> selectSubtitleStream(int? streamIndex) async {
    final plan = _state.plan;
    if (plan == null || plan.subtitleStreamIndex == streamIndex) return;
    if (streamIndex == null) {
      await engine.selectSubtitleTrack(null);
      _selectedSubtitleStreamIndex = null;
      final updated = plan.copyWith(clearSubtitleStreamIndex: true);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }

    final serverTrack = _trackMapper.findByIndex(plan, 'subtitle', streamIndex);
    if (serverTrack?.isExternal == true && serverTrack?.deliveryUrl != null) {
      final url = resolver.resolveExternalUrl(serverTrack!.deliveryUrl!);
      await engine.loadExternalSubtitle(
        url,
        title: serverTrack.title,
        language: serverTrack.language,
      );
      _selectedSubtitleStreamIndex = streamIndex;
      final updated = plan.copyWith(subtitleStreamIndex: streamIndex);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }

    if (plan.method == PlayMethod.directPlay) {
      await _waitForTracks(audio: false);
    }
    final engineTrackId = serverTrack == null
        ? null
        : _trackMapper.engineTrackId(serverTrack, _state.subtitleTracks);
    if (plan.method == PlayMethod.directPlay && engineTrackId != null) {
      await engine.selectSubtitleTrack(engineTrackId);
      _selectedSubtitleStreamIndex = streamIndex;
      final updated = plan.copyWith(subtitleStreamIndex: streamIndex);
      reporter.updatePlan(updated);
      _setState(_state.copyWith(plan: updated));
      await _reportProgress();
      return;
    }
    await reconfigure(
      subtitleStreamIndex: streamIndex,
      forceTranscode: plan.method == PlayMethod.directPlay,
    );
  }

  Future<void> setPlaybackRate(double rate) async {
    final safeRate = rate.clamp(0.25, 3.0).toDouble();
    await engine.setRate(safeRate);
    _setState(_state.copyWith(playbackRate: safeRate));
  }

  Future<void> setAudioDelay(Duration delay) => engine.setAudioDelay(delay);

  Future<void> setSubtitleDelay(Duration delay) =>
      engine.setSubtitleDelay(delay);

  Future<void> configureSubtitleStyle({
    required double fontSize,
    required int color,
    required int outlineColor,
    required int position,
  }) => engine.configureSubtitleStyle(
    fontSize: fontSize,
    color: color,
    outlineColor: outlineColor,
    position: position,
  );

  Future<void> reconfigure({
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool clearSubtitle = false,
    int? maxStreamingBitrate,
    bool forceTranscode = false,
  }) {
    final operation = _reconfiguration.then((_) async {
      if (_disposed || _engineDisposed) return;
      final position = _state.position;
      final wasPlaying = _state.isPlaying;
      _generation++;
      _progressTimer?.cancel();
      _setState(
        _state.copyWith(
          phase: PlaybackPhase.resolving,
          isBuffering: true,
          clearError: true,
        ),
      );
      try {
        await engine.stop();
      } finally {
        await reporter.stop(position);
      }

      if (mediaSourceId != null) _selectedMediaSourceId = mediaSourceId;
      if (audioStreamIndex != null) {
        _selectedAudioStreamIndex = audioStreamIndex;
      }
      if (clearSubtitle) {
        _selectedSubtitleStreamIndex = null;
      } else if (subtitleStreamIndex != null) {
        _selectedSubtitleStreamIndex = subtitleStreamIndex;
      }
      if (maxStreamingBitrate != null) {
        _maxStreamingBitrate = maxStreamingBitrate;
      }
      await _startPlayback(
        resumePosition: position,
        playAfterReady: wasPlaying,
        forceTranscodeInitially: forceTranscode,
      );
    });
    _reconfiguration = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> shutdown() {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    final operation = _shutdown();
    _shutdownOperation = operation;
    return operation;
  }

  Future<void> _shutdown() async {
    _generation++;
    _progressTimer?.cancel();
    _setState(_state.copyWith(phase: PlaybackPhase.stopping));
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _PlaybackCancelled());
    }
    await _cancelSubscriptions();

    DiagnosticLog.instance.info(
      'player',
      'Closing player item=${item.id} '
          'positionMs=${_state.position.inMilliseconds}',
    );
    final cleanup = reporter.stop(_state.position);
    final release = _disposeEngine();
    await Future.wait([cleanup, release]);
    _setState(
      _state.copyWith(
        phase: PlaybackPhase.idle,
        isPlaying: false,
        isBuffering: false,
      ),
    );
  }

  void _bindEngine() {
    _subscriptions.addAll([
      engine.positionStream.listen((position) {
        _setState(_state.copyWith(position: position));
        if (position > Duration.zero) _markReady();
      }),
      engine.durationStream.listen((duration) {
        _setState(_state.copyWith(duration: duration));
        if (duration > Duration.zero) _markReady();
      }),
      engine.bufferStream.listen((buffer) {
        _setState(_state.copyWith(buffer: buffer));
        if (buffer > Duration.zero) _markReady();
      }),
      engine.playingStream.listen((playing) {
        _setState(_state.copyWith(isPlaying: playing));
      }),
      engine.bufferingStream.listen((buffering) {
        if (buffering) _sawBuffering = true;
        _setState(_state.copyWith(isBuffering: buffering));
        if (!buffering && _sawBuffering) _markReady();
      }),
      engine.completedStream.listen(
        (completed) => _setState(_state.copyWith(isCompleted: completed)),
      ),
      engine.errorStream.listen(_handleEngineError),
      engine.logStream.listen(_handleEngineLog),
      engine.audioTracksStream.listen(
        (tracks) => _setState(_state.copyWith(audioTracks: tracks)),
      ),
      engine.subtitleTracksStream.listen(
        (tracks) => _setState(_state.copyWith(subtitleTracks: tracks)),
      ),
    ]);
  }

  void _handleEngineError(String error) {
    DiagnosticLog.instance.error(
      'player',
      'libmpv failed while playing item=${item.id}',
      error: error,
    );
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
      return;
    }
    if (_state.phase == PlaybackPhase.ready) {
      _setState(
        _state.copyWith(
          phase: PlaybackPhase.failed,
          isBuffering: false,
          errorMessage: friendlyPlaybackError(error),
        ),
      );
    }
  }

  void _handleEngineLog(String log) {
    final lower = log.toLowerCase();
    final fingerprint = _engineLogFingerprint(lower);
    final now = DateTime.now();
    final lastWritten = _engineLogLastWritten[fingerprint];
    if (lastWritten == null ||
        now.difference(lastWritten) >= const Duration(seconds: 2)) {
      if (_engineLogLastWritten.length >= 64) {
        _engineLogLastWritten.clear();
      }
      _engineLogLastWritten[fingerprint] = now;
      DiagnosticLog.instance.warning('libmpv', log);
    }

    if (_startupFailureSignaled || !_isStartupPhase(_state.phase)) return;
    if (!_isFatalStartupLog(lower)) return;

    final completer = _readyCompleter;
    if (completer == null || completer.isCompleted) return;
    _startupFailureSignaled = true;
    completer.completeError(log);
  }

  static bool _isStartupPhase(PlaybackPhase phase) =>
      phase == PlaybackPhase.opening ||
      phase == PlaybackPhase.waitingForReady ||
      phase == PlaybackPhase.retryingWithTranscode;

  static bool _isFatalStartupLog(String lower) {
    if (lower.contains('failed to resolve hostname') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('unknown host')) {
      return true;
    }
    if (lower.contains('inflate return value') &&
        lower.contains('incorrect header check')) {
      return true;
    }
    if (lower.contains('failed to open http://') ||
        lower.contains('failed to open https://')) {
      return true;
    }
    return lower.contains('http error 4') ||
        lower.contains('http error 5') ||
        lower.contains('server returned 4') ||
        lower.contains('server returned 5');
  }

  static String _engineLogFingerprint(String lower) {
    if (lower.contains('inflate return value')) return 'http-inflate';
    if (lower.contains('log message buffer overflow')) return 'log-overflow';
    if (lower.contains('failed to resolve hostname')) return 'dns-resolution';
    if (lower.contains('failed to open http')) return 'http-open';
    return lower;
  }

  Future<void> _applySelectedDirectPlayTracks(
    PlaybackPlan plan,
    int token,
  ) async {
    final audioIndex = _selectedAudioStreamIndex;
    if (audioIndex != null) {
      await _waitForTracks(audio: true);
      _throwIfStale(token);
      final track = _trackMapper.findByIndex(plan, 'audio', audioIndex);
      final engineId = track == null
          ? null
          : _trackMapper.engineTrackId(track, _state.audioTracks);
      if (engineId == null) {
        throw StateError('Unable to map Emby audio track $audioIndex');
      }
      await engine.selectAudioTrack(engineId);
    }

    final subtitleIndex = _selectedSubtitleStreamIndex;
    if (subtitleIndex == null) return;
    final track = _trackMapper.findByIndex(plan, 'subtitle', subtitleIndex);
    if (track?.isExternal == true && track?.deliveryUrl != null) {
      await engine.loadExternalSubtitle(
        resolver.resolveExternalUrl(track!.deliveryUrl!),
        title: track.title,
        language: track.language,
      );
      return;
    }
    await _waitForTracks(audio: false);
    _throwIfStale(token);
    final engineId = track == null
        ? null
        : _trackMapper.engineTrackId(track, _state.subtitleTracks);
    if (engineId == null) {
      throw StateError('Unable to map Emby subtitle track $subtitleIndex');
    }
    await engine.selectSubtitleTrack(engineId);
  }

  Future<void> _waitForTracks({required bool audio}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      final tracks = audio ? _state.audioTracks : _state.subtitleTracks;
      if (tracks.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  void _prepareReadyWait() {
    _sawBuffering = false;
    _startupFailureSignaled = false;
    _readyCompleter = Completer<void>();
  }

  void _markReady() {
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _waitUntilReady(int token) async {
    _throwIfStale(token);
    final completer = _readyCompleter;
    if (completer == null) {
      throw StateError('Playback ready wait was not initialized');
    }
    await completer.future.timeout(
      readyTimeout,
      onTimeout: () => throw TimeoutException(
        'Media did not become ready within ${readyTimeout.inSeconds}s',
      ),
    );
  }

  Future<void> _verifyResumePosition(Duration target, int token) async {
    final deadline = DateTime.now().add(resumeVerificationTimeout);
    while (DateTime.now().isBefore(deadline)) {
      _throwIfStale(token);
      final difference = (_state.position - target).abs();
      if (difference <= const Duration(seconds: 2)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
      'Resume seek was not applied near ${target.inMilliseconds}ms',
    );
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(
      progressInterval,
      (_) => unawaited(_reportProgress()),
    );
  }

  Future<void> _reportProgress() async {
    try {
      await reporter.reportProgress(
        position: _state.position,
        isPaused: !_state.isPlaying,
      );
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback',
        'Playback progress report failed item=${item.id}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Duration _clampToDuration(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    final duration = _state.duration;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  bool _isCurrent(int token) => !_disposed && token == _generation;

  void _throwIfStale(int token) {
    if (!_isCurrent(token)) throw const _PlaybackCancelled();
  }

  void _setState(PlaybackState next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  Future<void> _cancelSubscriptions() async {
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }

  Future<void> _disposeEngine() async {
    if (_engineDisposed) return;
    _engineDisposed = true;
    try {
      await engine.dispose();
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'player',
        'Player release failed item=${item.id}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  static String friendlyPlaybackError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('failed to resolve hostname') ||
        message.contains('no address associated with hostname') ||
        message.contains('unknown host')) {
      return '无法解析媒体地址，请检查 .strm 链接或 DNS';
    }
    if (message.contains('inflate return value') ||
        message.contains('incorrect header check')) {
      return '服务器返回的转码流格式异常';
    }
    if (message.contains('timeout') ||
        message.contains('did not become ready')) {
      return '媒体连接超时';
    }
    if (message.contains('failed to open') ||
        message.contains('http') ||
        message.contains('network')) {
      return '无法连接媒体流';
    }
    if (message.contains('codec') || message.contains('decoder')) {
      return '设备无法解码这个媒体';
    }
    return '播放失败，请返回后重试';
  }
}

class _PlaybackCancelled implements Exception {
  const _PlaybackCancelled();
}
