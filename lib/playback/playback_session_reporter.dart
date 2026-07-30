import 'dart:async';

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../models/emby_models.dart';

abstract interface class PlaybackReporter {
  void activate(PlaybackPlan plan);
  void updatePlan(PlaybackPlan plan);
  Future<void> reportStart(Duration position);
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  });
  Future<void> stop(Duration position);
  Future<void> cleanup(PlaybackPlan plan);
}

class PlaybackSessionReporter implements PlaybackReporter {
  PlaybackSessionReporter({required this.api, required this.item});

  final EmbyApi api;
  final EmbyItem item;

  PlaybackPlan? _plan;
  bool _started = false;
  bool _stopped = false;
  Future<void>? _stopOperation;

  PlaybackPlan? get plan => _plan;
  bool get hasStarted => _started;

  @override
  void activate(PlaybackPlan plan) {
    _plan = plan;
    _started = false;
    _stopped = false;
    _stopOperation = null;
  }

  @override
  void updatePlan(PlaybackPlan plan) {
    _plan = plan;
  }

  @override
  Future<void> reportStart(Duration position) async {
    final plan = _plan;
    if (plan == null || _started || _stopped) return;
    await api.reportPlaybackStart(item, plan, position: position);
    _started = true;
  }

  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {
    final plan = _plan;
    if (plan == null || !_started || _stopped) return;
    await api.reportPlaybackProgress(
      item,
      plan,
      position: position,
      isPaused: isPaused,
    );
  }

  @override
  Future<void> stop(Duration position) {
    final existing = _stopOperation;
    if (existing != null) return existing;
    final operation = _stop(position);
    _stopOperation = operation;
    return operation;
  }

  Future<void> _stop(Duration position) async {
    if (_stopped) return;
    _stopped = true;
    final plan = _plan;
    if (plan == null) return;

    if (_started) {
      try {
        await api.reportPlaybackStopped(item, plan, position: position);
      } catch (error, stackTrace) {
        DiagnosticLog.instance.error(
          'playback',
          'PlaybackStopped report failed item=${item.id}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    await cleanup(plan);
  }

  @override
  Future<void> cleanup(PlaybackPlan plan) async {
    try {
      await api.closeLiveStream(plan);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback',
        'LiveStream cleanup failed item=${item.id}',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      await api.stopActiveEncoding(plan);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'playback',
        'ActiveEncoding cleanup failed item=${item.id}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
