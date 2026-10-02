import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../core/diagnostic_log.dart';
import 'cache/native_playback_property_access.dart';
import 'cache/playback_cache_capabilities.dart';
import 'cache/playback_cache_engine.dart';
import 'cache/playback_cache_policy.dart';
import 'cache/playback_cache_telemetry.dart';
import 'playback_diagnostics.dart';
import 'playback_operation_coordinator.dart';
import 'playback_output_quiescer.dart';
import 'playback_resource_request.dart';
import 'mpv_source_input.dart';
import 'source_http_input.dart';

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

abstract interface class SourceDirectPlaybackEngine {
  Future<void> openSource(
    PlaybackResourceRequest request, {
    required bool play,
  });
}

abstract interface class PlaybackNativeResourceOwner {
  void retainUntilNativeDisposal(Future<void> Function() release);
}

/// Preflight the controlled input before configuring the native disk cache.
/// The prepared input must be reused by openSource on this same engine.
abstract interface class SourceDirectPreparationEngine {
  Future<VerifiedSourceInput> prepareSource(PlaybackResourceRequest request);
}

class MediaKitPlaybackEngine
    implements
        PlaybackEngine,
        SourceDirectPlaybackEngine,
        SourceDirectPreparationEngine,
        SourceFailureEmitter,
        PlaybackNativeResourceOwner,
        PlaybackCacheEngine,
        PlaybackCacheIdentitySnapshotReader {
  MediaKitPlaybackEngine(
    this.player, {
    this.nativePropertyWriter,
    PlaybackOutputQuiescer? outputQuiescer,
    PlaybackDiagnostics? diagnostics,
    NativePlaybackCacheEngine? cacheEngine,
    this.nativeOperationTimeouts = const PlaybackNativeOperationTimeouts(),
  }) : _outputQuiescer =
           outputQuiescer ?? MediaKitPlaybackOutputQuiescer(player),
       _diagnostics = diagnostics ?? PlaybackDiagnostics(),
       _cacheEngine = cacheEngine {
    final platform = player.platform;
    if (_cacheEngine == null && platform is NativePlayer) {
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
  final List<Future<void> Function()> _resourceReleases = [];
  @override
  void retainUntilNativeDisposal(Future<void> Function() release) =>
      _resourceReleases.add(release);
  MpvSourceInput? _sourceInput;
  _PreparedSource? _preparedSource;
  bool _preparingSource = false;
  int _inputRevision = 0;
  Future<void> _subtitleNativeTail = Future<void>.value();
  final _sourceErrors = StreamController<SourceInputFailure>.broadcast(
    sync: true,
  );
  SourceInputFailure? _sourceFailure;
  int _nativeFailureDuplicates = 0;
  void _flushSourceDuplicates() {
    final failure = _sourceFailure;
    if (failure != null && _nativeFailureDuplicates > 0) {
      failure.record(duplicates: _nativeFailureDuplicates);
      failure.trace.addInputTotals({'duplicates': _nativeFailureDuplicates});
      _nativeFailureDuplicates = 0;
    }
  }

  bool _forwardNativeMessage(String message) {
    final failure = _sourceFailure;
    if (failure == null) return true;
    _nativeFailureDuplicates++;
    if (_nativeFailureDuplicates == 1) {
      failure.record(duplicates: 1);
      failure.trace.detail(
        'native_read',
        {'message': message, 'failure': failure.id, 'duplicate': true},
        openAttempt: failure.openAttempt,
        request: failure.request,
      );
    }
    return false;
  }

  @override
  Stream<SourceInputFailure> get sourceFailureStream => _sourceErrors.stream;
  bool _sourceMode = false;
  final Map<String, String> _sourceOptionDefaults = {};

  static const _sourceOptions = {
    'demuxer': 'lavf',
    'demuxer-lavf-o': 'protocol_whitelist=none',
    'access-references': 'no',
    'ordered-chapters': 'no',
    'sub-auto': 'no',
    'audio-file-auto': 'no',
  };

  @override
  Future<VerifiedSourceInput> prepareSource(
    PlaybackResourceRequest request,
  ) async {
    late _PreparedSource prepared;
    await _runNativeOperation(
      kind: PlaybackNativeOperationKind.open,
      operation: () async {
        prepared = await _prepareSourceInput(request);
      },
    );
    return VerifiedSourceInput(request: request, sizeBytes: prepared.sizeBytes);
  }

  Future<_PreparedSource> _prepareSourceInput(
    PlaybackResourceRequest request,
  ) async {
    if (_isRetiring || _disposeStarted || !request.sessionActive) {
      throw const SourceInputException('cancelled');
    }
    final existing = _preparedSource;
    if (existing != null && identical(existing.request, request)) {
      return existing;
    }
    final revision = ++_inputRevision;
    final attempt = request.trace.nextOpen();
    _preparedSource = null;
    _preparingSource = true;
    _flushSourceDuplicates();
    _sourceFailure = null;
    _nativeFailureDuplicates = 0;
    void check() {
      if (revision != _inputRevision ||
          _isRetiring ||
          _disposeStarted ||
          !request.sessionActive) {
        throw const SourceInputException('cancelled');
      }
    }

    try {
      await _subtitleNativeTail;
      check();
      final native = player.platform;
      if (native is! NativePlayer) {
        throw const SourceInputException('native_unavailable');
      }
      _sourceInput ??= await MpvSourceInput.create(
        native,
        onReadFailure: (failure) {
          if (!_disposeStarted && !identical(_sourceFailure, failure)) {
            _sourceFailure = failure;
            _sourceErrors.add(failure);
          }
        },
      );
      check();
      final input = await _sourceInput!.prepare(request, attempt);
      check();
      return _preparedSource = _PreparedSource(
        request: request,
        uri: input.uri,
        format: input.format,
        sizeBytes: input.sizeBytes,
        attempt: attempt,
        revision: revision,
      );
    } finally {
      if (revision == _inputRevision) _preparingSource = false;
    }
  }

  void _cancelSourcePreparation() {
    if (!_preparingSource && _preparedSource == null) return;
    _inputRevision++;
    _preparingSource = false;
    _preparedSource = null;
    _sourceInput?.releaseAll();
  }

  @override
  Future<void> openSource(
    PlaybackResourceRequest request, {
    required bool play,
  }) {
    if (_isRetiring || _disposeStarted) return Future<void>.value();
    final epoch = _quiescenceEpoch;
    var openAttempt = request.trace.currentAttempt;
    var revision = _inputRevision;
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.open,
      operation: () async {
        var stage = 'native_register';
        try {
          final input = await _prepareSourceInput(request);
          openAttempt = input.attempt;
          revision = input.revision;
          _preparedSource = null;
          if (revision != _inputRevision || _isRetiring || _disposeStarted) {
            return;
          }
          final native = player.platform as NativePlayer;
          stage = 'native_open';
          _hasOpenedMedia = true;
          request.trace.emit('strm_native', {
            'openAttempt': openAttempt,
            'stage': 'native_open',
            'outcome': 'started',
          });
          await player.stop();
          await player.pause();
          for (final name in [..._sourceOptions.keys, 'demuxer-lavf-format']) {
            _sourceOptionDefaults.putIfAbsent(name, () => '');
            if (!_sourceMode) {
              _sourceOptionDefaults[name] = await native.getProperty(name);
            }
          }
          _sourceMode = true;
          for (final entry in {
            ..._sourceOptions,
            'demuxer-lavf-format': input.format,
          }.entries) {
            try {
              await native.setProperty(entry.key, entry.value);
            } catch (_) {
              throw const SourceInputException('native_policy_option');
            }
            // Unsupported options must fail before any native media open.
            if (await native.getProperty(entry.key) != entry.value) {
              throw const SourceInputException('native_policy_option');
            }
          }
          // The remote URL/credentials never enter Media or native global headers.
          Media(input.uri.toString(), httpHeaders: const {});
          await native.command(['loadfile', input.uri.toString(), 'replace']);
          request.trace.emit('strm_native', {
            'openAttempt': openAttempt,
            'stage': 'native_open',
            'outcome': 'succeeded',
          });
          if (play && !_mustReassertQuiescence(epoch)) await player.play();
          if (_mustReassertQuiescence(epoch)) await _pauseOutput();
        } catch (error) {
          final safe = error is SourceInputException
              ? error
              : SourceInputException(
                  stage == 'native_register'
                      ? 'native_registration'
                      : 'unknown',
                  stage: stage,
                );
          final failure =
              safe.failure ??
              SourceInputFailure(
                error: safe,
                trace: request.trace,
                openAttempt: openAttempt,
                request: 0,
                stale: revision != _inputRevision,
              );
          failure.record();
          throw SourceInputException(
            safe.code,
            stage: safe.safeStage,
            httpStatus: safe.safeHttp,
            failure: failure,
          );
        }
      },
    );
  }

  Future<void> _restoreSourceOptions() async {
    _cancelSourcePreparation();
    _sourceInput?.releaseAll();
    _flushSourceDuplicates();
    _sourceFailure = null;
    _nativeFailureDuplicates = 0;
    if (!_sourceMode) return;
    final native = player.platform as NativePlayer;
    for (final entry in _sourceOptionDefaults.entries) {
      await native.setProperty(entry.key, entry.value);
    }
    _sourceMode = false;
  }

  final NativePropertyWriter? nativePropertyWriter;
  final PlaybackOutputQuiescer _outputQuiescer;
  final PlaybackDiagnostics _diagnostics;
  final PlaybackNativeOperationTimeouts nativeOperationTimeouts;
  NativePlaybackCacheEngine? _cacheEngine;
  final Set<Future<void>> _nativeBarriers = <Future<void>>{};
  bool _hasOpenedMedia = false;
  PlaybackRetirementState _retirementState = PlaybackRetirementState.active;
  bool _lifecycleQuiesced = false;
  bool _disposeStarted = false;
  int _quiescenceEpoch = 0;
  Future<void>? _pauseOutputOperation;
  Future<void>? _disposeOperation;

  PlaybackRetirementState get retirementState => _retirementState;

  bool get _isRetiring => _retirementState != PlaybackRetirementState.active;

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get durationStream => player.stream.duration;

  @override
  Stream<Duration> get bufferStream => player.stream.buffer;

  @override
  Stream<bool> get playingStream => player.stream.playing.map(
    (playing) =>
        playing && !_isRetiring && !_lifecycleQuiesced && !_disposeStarted,
  );

  @override
  Stream<bool> get bufferingStream => player.stream.buffering;

  @override
  Stream<bool> get completedStream => player.stream.completed;

  @override
  Stream<String> get errorStream =>
      player.stream.error.where(_forwardNativeMessage);

  @override
  Stream<String> get logStream => player.stream.log
      .where(
        (log) =>
            !{'error', 'fatal', 'warn'}.contains(log.level) ||
            _forwardNativeMessage(log.toString()),
      )
      .map((log) => log.toString());

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
    if (_isRetiring || _disposeStarted) return Future<void>.value();
    final quiescenceEpoch = _quiescenceEpoch;
    _hasOpenedMedia = true;
    final revision = ++_inputRevision;
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.open,
      operation: () async {
        await _subtitleNativeTail;
        if (revision != _inputRevision || _isRetiring || _disposeStarted) {
          return;
        }
        await _restoreSourceOptions();
        await player.open(
          Media(uri.toString(), httpHeaders: headers),
          play: play,
        );
        if (play && _mustReassertQuiescence(quiescenceEpoch)) {
          await _pauseOutput();
        }
      },
    );
  }

  @override
  Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities() {
    final cacheEngine = _cacheEngine;
    if (_disposeStarted || cacheEngine == null) {
      return Future.value(PlaybackCacheEngineCapabilities.unsupported());
    }
    return _trackAuxiliaryNativeOperation(cacheEngine.probeCacheCapabilities);
  }

  @override
  Future<PlaybackCacheApplyResult> configureCache(
    ResolvedPlaybackCacheProfile profile,
    PlaybackCacheEngineCapabilities capabilities,
  ) {
    final cacheEngine = _cacheEngine;
    if (!_disposeStarted && cacheEngine != null) {
      return _trackAuxiliaryNativeOperation(
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
    return _trackAuxiliaryNativeOperation(cacheEngine.readCacheSnapshot);
  }

  @override
  Future<PlaybackCacheEngineSnapshot?> readCacheSnapshotForIdentity({
    required PlaybackCacheReadIdentity identity,
    required PlaybackCacheReadIdentityCurrent isIdentityCurrent,
  }) {
    final cacheEngine = _cacheEngine;
    if (_disposeStarted || cacheEngine == null) return Future.value();
    return _trackAuxiliaryNativeOperation(
      () => cacheEngine.readCacheSnapshotForIdentity(
        identity: identity,
        isIdentityCurrent: isIdentityCurrent,
      ),
    );
  }

  @override
  Future<void> play() {
    if (_isRetiring || _lifecycleQuiesced || _disposeStarted) {
      return Future<void>.value();
    }
    final quiescenceEpoch = _quiescenceEpoch;
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.play,
      operation: () async {
        await player.play();
        if (_mustReassertQuiescence(quiescenceEpoch)) await _pauseOutput();
      },
    );
  }

  @override
  Future<void> pause() {
    if (_disposeStarted) return Future<void>.value();
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.pause,
      operation: player.pause,
    );
  }

  @override
  Future<void> quiesce() {
    _cancelSourcePreparation();
    if (_disposeStarted) {
      return _disposeOperation ?? Future<void>.value();
    }
    if (_retirementState == PlaybackRetirementState.active) {
      _retirementState = PlaybackRetirementState.quiescing;
    }
    _quiescenceEpoch++;
    return _pauseOutput().whenComplete(() {
      if (_retirementState == PlaybackRetirementState.quiescing) {
        _retirementState = PlaybackRetirementState.retiring;
      }
    });
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
    if (_isRetiring || _disposeStarted) return;
    _lifecycleQuiesced = false;
    _quiescenceEpoch++;
  }

  @override
  Future<void> seek(Duration position) {
    if (_isRetiring || _lifecycleQuiesced || _disposeStarted) {
      return Future<void>.value();
    }
    final quiescenceEpoch = _quiescenceEpoch;
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.seek,
      operation: () async {
        await player.seek(position);
        if (_mustReassertQuiescence(quiescenceEpoch)) await _pauseOutput();
      },
    );
  }

  bool _mustReassertQuiescence(int operationEpoch) =>
      operationEpoch != _quiescenceEpoch || _isRetiring || _lifecycleQuiesced;

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
      final urgentMute = _startNativeOperation(
        kind: PlaybackNativeOperationKind.urgentMute,
        operation: _outputQuiescer.pauseUrgently,
      );
      await urgentMute.logicalFuture;
    } catch (error) {
      DiagnosticLog.instance.warning(
        'player',
        'event=playback_urgent_pause_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Future<void> _runNativeOperation({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
  }) => _startNativeOperation(kind: kind, operation: operation).logicalFuture;

  Future<void> _returnNativeOperation({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
  }) {
    // External subtitle discovery intentionally observes the raw native Future:
    // its 2-second foreground wait may continue in Stage B's bounded late-track
    // window. The operation still installs a typed, bounded teardown barrier.
    final future = _startNativeOperation(
      kind: kind,
      operation: operation,
    ).nativeFuture;
    _subtitleNativeTail = future.catchError((Object _) {});
    return future;
  }

  PlaybackNativeOperation _startNativeOperation({
    required PlaybackNativeOperationKind kind,
    required PlaybackEngineOperation operation,
    void Function()? onTimeout,
  }) {
    final nativeOperation = PlaybackNativeOperation.start(
      kind: kind,
      timeout: nativeOperationTimeouts.forKind(kind),
      operation: operation,
      onTimeout: onTimeout ?? () => _nativeOperationTimedOut(kind),
    );
    final barrier = nativeOperation.barrierFuture.then<void>((_) {});
    _nativeBarriers.add(barrier);
    unawaited(
      barrier.whenComplete(() {
        _nativeBarriers.remove(barrier);
      }),
    );
    return nativeOperation;
  }

  Future<T> _trackAuxiliaryNativeOperation<T>(Future<T> Function() operation) {
    final nativeOperation = Future<T>.sync(operation);
    final nativeCompletion = nativeOperation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    late final Future<void> barrier;
    barrier = nativeCompletion
        .timeout(
          nativeOperationTimeouts.propertyWrite,
          onTimeout: () => _nativeOperationTimedOut(
            PlaybackNativeOperationKind.propertyWrite,
          ),
        )
        .whenComplete(() => _nativeBarriers.remove(barrier));
    _nativeBarriers.add(barrier);
    return nativeOperation;
  }

  Future<void> _waitForNativeBarriers() async {
    while (_nativeBarriers.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_nativeBarriers));
    }
  }

  void _nativeOperationTimedOut(PlaybackNativeOperationKind kind) {
    if (kind == PlaybackNativeOperationKind.open ||
        kind == PlaybackNativeOperationKind.play ||
        kind == PlaybackNativeOperationKind.seek) {
      _quiescenceEpoch++;
    }
    DiagnosticLog.instance.warning(
      'player',
      'event=playback_native_operation_timeout kind=${kind.name}',
    );
  }

  @override
  Future<void> selectAudioTrack(String trackId) {
    if (_disposeStarted) return Future<void>.value();
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () async {
        final track = player.state.tracks.audio
            .where((candidate) => candidate.id == trackId)
            .firstOrNull;
        if (track == null) {
          throw StateError('Audio track $trackId is unavailable');
        }
        await player.setAudioTrack(track);
      },
    );
  }

  @override
  Future<void> selectSubtitleTrack(String? trackId) {
    if (_disposeStarted) return Future<void>.value();
    // The controller serializes subtitle writes until real native completion.
    return _returnNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () async {
        if (trackId == null) {
          await player.setSubtitleTrack(SubtitleTrack.no());
          await _confirmSubtitle('no');
          return;
        }
        final track = player.state.tracks.subtitle
            .where((candidate) => candidate.id == trackId)
            .firstOrNull;
        if (track == null) {
          throw StateError('Subtitle track $trackId is unavailable');
        }
        await player.setSubtitleTrack(track);
        await _confirmSubtitle(trackId);
      },
    );
  }

  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) {
    if (_disposeStarted) return Future<void>.value();
    return _returnNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () async {
        final native = player.platform;
        if (native is! NativePlayer) {
          throw const SourceInputException('subtitle_unconfirmed');
        }
        String? videoFormat;
        if (_sourceMode) {
          if (uri.scheme != 'file') {
            throw const SourceInputException('subtitle_local_required');
          }
          final format = switch (uri.path.split('.').last) {
            'srt' => 'srt',
            'vtt' => 'webvtt',
            'ass' => 'ass',
            _ => throw const SourceInputException('subtitle_format'),
          };
          videoFormat = await native.getProperty('demuxer-lavf-format');
          await native.setProperty('demuxer-lavf-format', format);
        }
        try {
          await player.setSubtitleTrack(
            SubtitleTrack.uri(uri.toString(), title: title, language: language),
          );
          final sid = await native.getProperty('sid');
          final tracks = await MediaKitNativePlaybackPropertyAccess(
            native,
          ).getNativeNode('track-list');
          final matched =
              tracks is List &&
              tracks.any(
                (entry) =>
                    entry is Map &&
                    entry['type'] == 'sub' &&
                    entry['id'].toString() == sid &&
                    entry['external'] == true &&
                    entry['external-filename'] == uri.toString(),
              );
          if (!matched) {
            throw const SourceInputException('subtitle_unconfirmed');
          }
        } finally {
          if (videoFormat != null) {
            await native.setProperty('demuxer-lavf-format', videoFormat);
          }
        }
      },
    );
  }

  Future<void> _confirmSubtitle(String expected) async {
    final native = player.platform;
    if (native is! NativePlayer ||
        await native.getProperty('sid') != expected) {
      throw const SourceInputException('subtitle_unconfirmed');
    }
  }

  @override
  Future<void> setRate(double rate) {
    if (_disposeStarted) return Future<void>.value();
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () => player.setRate(rate),
    );
  }

  @override
  Future<void> setAudioDelay(Duration delay) {
    if (_disposeStarted) return Future<void>.value();
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () => _setNativeProperty('audio-delay', _seconds(delay)),
    );
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) {
    if (_disposeStarted) return Future<void>.value();
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () => _setNativeProperty('sub-delay', _seconds(delay)),
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
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.propertyWrite,
      operation: () async {
        await _setNativeProperty('sub-font-size', fontSize.toStringAsFixed(1));
        await _setNativeProperty('sub-color', _mpvColor(color));
        await _setNativeProperty('sub-border-color', _mpvColor(outlineColor));
        await _setNativeProperty('sub-pos', position.clamp(0, 100).toString());
      },
    );
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
    _inputRevision++;
    _preparedSource = null;
    _preparingSource = false;
    _flushSourceDuplicates();
    _sourceInput?.releaseAll();
    return _runNativeOperation(
      kind: PlaybackNativeOperationKind.stop,
      operation: player.stop,
    );
  }

  @override
  Future<void> dispose() {
    final existing = _disposeOperation;
    if (existing != null) return existing;
    final wasRetiring = _isRetiring;
    _disposeStarted = true;
    if (!wasRetiring) {
      _retirementState = PlaybackRetirementState.quiescing;
      _quiescenceEpoch++;
    }
    final quiescence =
        _pauseOutputOperation ?? (wasRetiring ? null : _pauseOutput());
    final operation = _dispose(quiescence);
    _disposeOperation = operation;
    return operation;
  }

  Future<void> _dispose(Future<void>? quiescence) async {
    _cancelSourcePreparation();
    _sourceInput?.releaseAll();
    if (quiescence != null) await quiescence;
    if (_retirementState == PlaybackRetirementState.quiescing) {
      _retirementState = PlaybackRetirementState.retiring;
    }
    await _waitForNativeBarriers();
    _cacheEngine?.dispose();
    final disposal = _startNativeOperation(
      kind: PlaybackNativeOperationKind.dispose,
      operation: () async {
        await player.dispose();
        _sourceInput?.afterNativeDisposal();
        _flushSourceDuplicates();
        await _sourceErrors.close();
        for (final release in _resourceReleases) {
          await release();
        }
        _resourceReleases.clear();
      },
      onTimeout: () {
        _retirementState = PlaybackRetirementState.quarantined;
        _nativeOperationTimedOut(PlaybackNativeOperationKind.dispose);
      },
    );
    try {
      await disposal.logicalFuture;
      if (_retirementState != PlaybackRetirementState.quarantined) {
        _retirementState = PlaybackRetirementState.closed;
      }
    } catch (_) {
      _retirementState = PlaybackRetirementState.quarantined;
      rethrow;
    }
  }
}

class _PreparedSource {
  const _PreparedSource({
    required this.request,
    required this.uri,
    required this.format,
    required this.sizeBytes,
    required this.attempt,
    required this.revision,
  });
  final PlaybackResourceRequest request;
  final Uri uri;
  final String format;
  final int sizeBytes;
  final int attempt;
  final int revision;
}
