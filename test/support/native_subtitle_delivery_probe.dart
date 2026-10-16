import 'dart:convert';

import 'package:emby_my_client/core/token_redactor.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test diagnostics use cached Dart state; reporting must never call libmpv after
/// the controller has retired a failed startup. Keep first events, not just tail.
class NativeSubtitleDeliveryProbe {
  NativeSubtitleDeliveryProbe({
    required this.mode,
    required this.state,
    required this.disposed,
  });

  final String mode;
  final PlaybackState Function() state;
  final bool Function() disposed;
  final clock = Stopwatch()..start();
  final events = <Map<String, Object?>>[];
  final native = <String, String>{};
  var droppedEvents = 0;
  var stage = 'startup';

  static String safeMessage(String message) {
    final safe = TokenRedactor.redact(message)
        .replaceAll(RegExp(r'(?:https?|file)://[^\s]+'), '<uri>')
        .replaceAll(
          RegExp(r'(?<![A-Za-z0-9])(?:[A-Za-z]:[\\/]|/)[^\s,;]+'),
          '<path>',
        );
    return safe.length <= 2048 ? safe : '${safe.substring(0, 2048)}<truncated>';
  }

  void record(String event, [Map<String, Object?> fields = const {}]) {
    if (events.length == 128) {
      droppedEvents++;
      return;
    }
    events.add({'atUs': clock.elapsedMicroseconds, 'event': event, ...fields});
  }

  void diagnostic(String line) {
    final event = RegExp(r'\bevent=([a-z_]+)').firstMatch(line)?.group(1);
    if (!const {
      'playback_start_failed',
      'playback_ready',
      'playback_operation_timeout',
      'playback_engine_error',
      'playback_engine_dispose_failed',
      'playback_engine_stop_failed',
    }.contains(event)) {
      return;
    }
    final fields = <String, Object?>{};
    for (final key in ['errorType', 'kind', 'stage', 'fingerprint', 'method']) {
      final value = RegExp('\\b$key=([A-Za-z_]+)').firstMatch(line)?.group(1);
      if (value != null) fields[key] = value;
    }
    record(event!, fields);
  }

  Map<String, Object?> snapshot() {
    final current = state();
    return {
      'mode': mode,
      'stage': stage,
      'phase': current.phase.name,
      'selection': current.subtitleSelectionStatus.name,
      'error': safeMessage(current.errorMessage ?? ''),
      'subtitleError': safeMessage(current.subtitleSelectionError ?? ''),
      'tracks': current.subtitleTracks.length,
      'positionMs': current.position.inMilliseconds,
      'durationMs': current.duration.inMilliseconds,
      'playing': current.isPlaying,
      'engineDisposed': disposed(),
      'nativeLastObserved': native,
      'events': events,
      'droppedEvents': droppedEvents,
    };
  }

  String describe() => jsonEncode(snapshot());

  void requireReady() {
    if (state().phase != PlaybackPhase.ready || disposed()) {
      fail('Subtitle delivery requires a ready live input: ${describe()}');
    }
  }

  Future<T> observe<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (_) {
      printOnFailure('SUBTITLE_DELIVERY_DIAGNOSTIC ${describe()}');
      rethrow;
    }
  }

  Future<void> until(Future<bool> Function() check) async {
    for (var i = 0; i < 200; i++) {
      requireReady();
      if (await observe(check)) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail(
      'Expected subtitle state or decoded cue did not arrive: ${describe()}',
    );
  }
}
