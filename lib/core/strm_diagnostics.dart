import 'dart:math';
import 'dart:convert';

import 'diagnostic_log.dart';

/// Closed vocabulary shared by local logging and full-export validation.
/// Numeric events remain closed; detailed runtime evidence uses JSON below.
abstract final class StrmDiagnosticSchema {
  // Detail records use JSON after `details=`. These are runtime display
  // copies; headers may be maps of lists and exception stacks may be multiline.
  // The common sink escapes controls, masks tokens and bounds each entry.
  static const detailFields = {
    'sourceUrl',
    'itemId',
    'sourceId',
    'requiredHttpHeaders',
    'requestUrl',
    'host',
    'port',
    'addresses',
    'ip',
    'headers',
    'fromUrl',
    'location',
    'toUrl',
    'http',
    'outcome',
    'elapsedMs',
    'requestHeaders',
    'errorType',
    'message',
    'stack',
    'osErrorCode',
    'osErrorMessage',
    'failure',
    'duplicate',
  };
  static const common = {
    'trace',
    'openAttempt',
    'request',
    'task',
    'cycle',
    'elapsedMs',
    'stale',
    'cancelled',
    'outcome',
  };
  static const events = <String, Set<String>>{
    'strm_entry': {'entry'},
    'strm_resolve': {
      'classification',
      'fixedSource',
      'conflict',
      'group',
      'attempt',
      'strict',
      'http',
      'route',
      'inputMode',
    },
    'strm_input': {'container', 'lengthKnown', 'headerCount'},
    'strm_http': {
      'stage',
      'http',
      'crossOrigin',
      'credentialsStripped',
      'redirects',
      'family',
      'candidates',
      'rangeValid',
      'lengthKnown',
    },
    'strm_native': {'stage'},
    'strm_failure': {
      'stage',
      'reason',
      'http',
      'failure',
      'recoverable',
      'recoveryExecuted',
      'duplicates',
    },
    'strm_recovery': {'continuingCycle', 'recoveryExecuted'},
    'strm_reporting': {'operation', 'http'},
    'strm_subtitle': {'stage', 'attached'},
    'strm_summary': {
      'scope',
      'nativeReads',
      'httpRequests',
      'redirects',
      'ranges',
      'networkBytes',
      'deliveredBytes',
      'prefixHits',
      'readAheadHits',
      'readAheadBytes',
      'requestMs',
      'rateBytes',
      'failures',
      'cancellations',
      'duplicates',
    },
    'playback_subtitle_apply_skipped_stale': {'generation'},
  };
  static const numbers = {
    'openAttempt',
    'request',
    'task',
    'cycle',
    'elapsedMs',
    'attempt',
    'headerCount',
    'redirects',
    'candidates',
    'failure',
    'duplicates',
    'nativeReads',
    'httpRequests',
    'ranges',
    'networkBytes',
    'deliveredBytes',
    'prefixHits',
    'readAheadHits',
    'readAheadBytes',
    'requestMs',
    'rateBytes',
    'failures',
    'cancellations',
    'generation',
  };
  static const booleans = {
    'stale',
    'cancelled',
    'fixedSource',
    'conflict',
    'strict',
    'lengthKnown',
    'crossOrigin',
    'credentialsStripped',
    'rangeValid',
    'recoverable',
    'recoveryExecuted',
    'continuingCycle',
    'attached',
  };
  static const enums = <String, Set<String>>{
    'outcome': {
      'started',
      'succeeded',
      'failed',
      'cancelled',
      'stale',
      'queued',
      'confirmed',
      'late',
      'released',
      'first_read',
      'periodic',
      'closed',
    },
    'entry': {'fullscreen', 'inline', 'unavailable'},
    'classification': {'strm', 'regular', 'unknown'},
    'group': {'strict', 'regular', 'detail'},
    'route': {'source_direct', 'server', 'offline'},
    'inputMode': {'stream_cb', 'player'},
    'container': {'mov', 'matroska', 'avi', 'mpegts', 'unknown'},
    'family': {'ipv4', 'ipv6', 'mixed'},
    'scope': {'input', 'playback'},
    'operation': {'start', 'stopped', 'progress'},
    'stage': {
      'metadata',
      'classification',
      'dns',
      'connect',
      'tls',
      'redirect',
      'range_response',
      'body_read',
      'native_register',
      'native_open',
      'native_read',
      'subtitle_download',
      'subtitle_apply',
      'reporting',
    },
    'reason': {
      'unknown',
      'source_denied',
      'range_unsupported',
      'source_changed',
      'truncated',
      'redirect_limit',
      'redirect_loop',
      'tls_downgrade',
      'tls_certificate',
      'dns_failed',
      'connect_failed',
      'timeout',
      'cancelled',
      'unsupported_container',
      'native_registration',
      'native_policy_option',
      'subtitle_format',
      'subtitle_budget',
      'subtitle_unconfirmed',
      'destination',
      'invalid_range',
      'body_limit',
      'redirect_location',
      'identity_conflict',
      'source_missing',
      'unresolved',
      'server_error',
    },
  };

  static String payload(String line) => line.replaceFirst(
    RegExp(
      r'^\d{4}-\d\d-\d\dT[0-9:.]+Z? \[(?:INFO|WARN|ERROR|DEBUG)\] \[[a-z_]+\] ',
    ),
    '',
  );

  static bool claimsStructured(String line) {
    final value = payload(line);
    return value.startsWith('event=strm_') ||
        value.startsWith('event=playback_subtitle_apply_skipped_stale');
  }

  static bool valid(String line) {
    if (line.length > 2048 || line.contains(RegExp(r'[\r\n\t]'))) return false;
    final parts = payload(line).split(' ');
    if (parts.isEmpty || !parts.first.startsWith('event=')) return false;
    final name = parts.first.substring(6);
    final fields = events[name];
    if (fields == null) return false;
    final seen = <String>{};
    for (final part in parts.skip(1)) {
      final pair = part.split('=');
      if (pair.length != 2 || !seen.add(pair[0])) return false;
      final key = pair[0], value = pair[1];
      if (!fields.contains(key) && !common.contains(key)) return false;
      if (key == 'trace') {
        if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(value)) return false;
      } else if (key == 'http') {
        if (value != 'unavailable' &&
            !RegExp(r'^[1-5][0-9]{2}$').hasMatch(value)) {
          return false;
        }
      } else if (numbers.contains(key)) {
        if (value != 'unavailable' &&
            (!RegExp(r'^(0|[1-9][0-9]{0,14})$').hasMatch(value))) {
          return false;
        }
      } else if (booleans.contains(key)) {
        if (!{'true', 'false'}.contains(value)) return false;
      } else if (!(enums[key]?.contains(value) ?? false)) {
        return false;
      }
    }
    return name == 'playback_subtitle_apply_skipped_stale'
        ? seen.contains('generation')
        : seen.contains('trace');
  }
}

/// Created per logical playback, never derived from business/session data.
/// Operations retain this object and immutable attempt numbers across awaits.
class StrmTrace {
  StrmTrace({DiagnosticLog? log})
    : log = log ?? DiagnosticLog.instance,
      id = List.generate(
        8,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  final DiagnosticLog log;
  final String id;
  final Stopwatch clock = Stopwatch()..start();
  int _opens = 0, _requests = 0, _tasks = 0, _cycles = 0, _failures = 0;
  bool _finished = false;
  bool get finished => _finished;
  final Map<String, int> _inputTotals = {};
  void addInputTotals(Map<String, int?> totals) {
    if (_finished) return;
    for (final entry in totals.entries) {
      if (entry.value != null) {
        _inputTotals.update(
          entry.key,
          (v) => v + entry.value!,
          ifAbsent: () => entry.value!,
        );
      }
    }
  }

  int get currentAttempt => _opens;
  int nextOpen() => ++_opens;
  int nextRequest() => ++_requests;
  int nextTask() => ++_tasks;
  int nextCycle() => ++_cycles;
  int nextFailure() => ++_failures;
  void emit(String event, Map<String, Object?> fields) {
    // Logging must never alter media control, even with a failed test/file sink.
    try {
      final line =
          'event=$event trace=$id ${fields.entries.map((e) => '${e.key}=${e.value ?? 'unavailable'}').join(' ')}'
              .trimRight();
      if (StrmDiagnosticSchema.valid(line)) log.info('strm', line);
    } catch (_) {
      /* diagnostic-only */
    }
  }

  /// JSON preserves field boundaries and escapes controls without rewriting
  /// opaque URLs. DiagnosticLog sanitizes only the serialized display copy.
  void detail(
    String stage,
    Map<String, Object?> fields, {
    int? openAttempt,
    int? request,
    int? task,
  }) {
    try {
      log.info(
        'strm',
        'event=strm_detail trace=$id '
            'openAttempt=${openAttempt ?? currentAttempt} '
            '${request == null ? '' : 'request=$request '}'
            '${task == null ? '' : 'task=$task '}'
            'stage=$stage elapsedMs=${clock.elapsedMilliseconds} '
            'details=${jsonEncode(fields)}',
      );
    } catch (_) {
      /* diagnostic-only */
    }
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    emit('strm_summary', {
      'scope': 'playback',
      'outcome': 'closed',
      'openAttempt': _opens,
      'elapsedMs': clock.elapsedMilliseconds,
      'nativeReads': _inputTotals['nativeReads'],
      'httpRequests': _inputTotals['httpRequests'],
      'redirects': _inputTotals['redirects'],
      'ranges': _inputTotals['ranges'],
      'networkBytes': _inputTotals['networkBytes'],
      'deliveredBytes': _inputTotals['deliveredBytes'],
      'prefixHits': _inputTotals['prefixHits'],
      'readAheadHits': _inputTotals['readAheadHits'],
      'requestMs': _inputTotals['requestMs'],
      'cancellations': _inputTotals['cancellations'],
      'duplicates': _inputTotals['duplicates'],
      'failures': _inputTotals['failures'],
    });
  }
}
