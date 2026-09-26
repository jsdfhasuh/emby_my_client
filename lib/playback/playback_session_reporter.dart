import 'dart:async';

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../models/emby_models.dart';

abstract interface class PlaybackReporter {
  void activate(PlaybackPlan plan);
  void updatePlan(PlaybackPlan plan);
  Future<void> reportStart(Duration position, {required bool isPaused});
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

  _PlaybackReportingCycle? _cycle;

  PlaybackPlan? get plan => _cycle?.plan;
  bool get hasStarted => _cycle?.started ?? false;

  @override
  void activate(PlaybackPlan plan) {
    _cycle = _PlaybackReportingCycle(plan);
  }

  @override
  void updatePlan(PlaybackPlan plan) {
    final cycle = _cycle;
    if (cycle != null) cycle.plan = plan;
  }

  @override
  Future<void> reportStart(Duration position, {required bool isPaused}) {
    final cycle = _cycle;
    if (cycle == null || cycle.started || cycle.stopped) {
      return Future<void>.value();
    }
    final existing = cycle.startOperation;
    if (existing != null) return existing;
    cycle.startAttempted = true;
    final plan = cycle.plan;
    late final Future<void> operation;
    operation = (() async {
      try {
        await api.reportPlaybackStart(
          item,
          plan,
          position: position,
          isPaused: isPaused,
        );
        cycle.started = true;
      } finally {
        if (identical(cycle.startOperation, operation)) {
          cycle.startOperation = null;
        }
      }
    })();
    cycle.startOperation = operation;
    return operation;
  }

  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {
    final cycle = _cycle;
    if (cycle == null || !cycle.started || cycle.stopped) return;
    await api.reportPlaybackProgress(
      item,
      cycle.plan,
      position: position,
      isPaused: isPaused,
    );
  }

  @override
  Future<void> stop(Duration position) {
    final cycle = _cycle;
    if (cycle == null) return Future<void>.value();
    final existing = cycle.stopOperation;
    if (existing != null) return existing;
    final operation = _stop(cycle, position);
    cycle.stopOperation = operation;
    return operation;
  }

  Future<void> _stop(_PlaybackReportingCycle cycle, Duration position) async {
    if (cycle.stopped) return;
    cycle.stopped = true;
    final plan = cycle.plan;
    final cleanupOperation = cleanup(plan);
    final startOperation = cycle.startOperation;
    if (startOperation != null) {
      try {
        await startOperation;
      } catch (_) {
        // A failed Start is still followed by a conservative Stopped report;
        // the server may have accepted the request before the client failed.
      }
    }
    try {
      if (cycle.startAttempted) {
        try {
          await api.reportPlaybackStopped(item, plan, position: position);
        } catch (error) {
          DiagnosticLog.instance.warning(
            'playback',
            'event=playback_stopped_report_failed '
                'errorType=${error.runtimeType}',
          );
        }
      }
    } finally {
      await cleanupOperation;
    }
  }

  @override
  Future<void> cleanup(PlaybackPlan plan) async {
    await Future.wait<void>([
      _closeLiveStreamSafely(plan),
      _stopActiveEncodingSafely(plan),
    ]);
  }

  Future<void> _closeLiveStreamSafely(PlaybackPlan plan) async {
    try {
      await api.closeLiveStream(plan);
    } catch (error) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_live_stream_cleanup_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }

  Future<void> _stopActiveEncodingSafely(PlaybackPlan plan) async {
    try {
      await api.stopActiveEncoding(plan);
    } catch (error) {
      DiagnosticLog.instance.warning(
        'playback',
        'event=playback_encoding_cleanup_failed '
            'errorType=${error.runtimeType}',
      );
    }
  }
}

class _PlaybackReportingCycle {
  _PlaybackReportingCycle(this.plan);

  PlaybackPlan plan;
  bool startAttempted = false;
  bool started = false;
  bool stopped = false;
  Future<void>? startOperation;
  Future<void>? stopOperation;
}
