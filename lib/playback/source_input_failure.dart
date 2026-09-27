import 'dart:async';
import 'dart:io';

import '../core/strm_diagnostics.dart';

/// Only a closed reason vocabulary can cross the network/native boundary.
/// Compatibility codes are normalized here, never parsed from remote text.
class SourceInputException implements Exception {
  const SourceInputException(
    this.code, {
    this.stage,
    this.httpStatus,
    this.failure,
  });
  final SourceInputFailure? failure;
  final String code;
  final String? stage;
  final int? httpStatus;
  String get reason => StrmDiagnosticSchema.enums['reason']!.contains(code)
      ? code
      : switch (code) {
          'native_api_version' || 'native_unavailable' => 'native_registration',
          'subtitle_limit' => 'subtitle_budget',
          'subtitle_timeout' => 'timeout',
          _ => 'unknown',
        };
  String get safeStage => StrmDiagnosticSchema.enums['stage']!.contains(stage)
      ? stage!
      : switch (reason) {
          'dns_failed' || 'destination' => 'dns',
          'connect_failed' => 'connect',
          'tls_certificate' => 'tls',
          'redirect_limit' ||
          'redirect_loop' ||
          'tls_downgrade' ||
          'redirect_location' => 'redirect',
          'source_denied' ||
          'range_unsupported' ||
          'source_changed' ||
          'invalid_range' => 'range_response',
          'native_registration' => 'native_register',
          'native_policy_option' => 'native_open',
          'subtitle_format' || 'subtitle_budget' => 'subtitle_download',
          'subtitle_unconfirmed' => 'subtitle_apply',
          _ => 'body_read',
        };
  int? get safeHttp =>
      httpStatus != null && httpStatus! >= 100 && httpStatus! <= 599
      ? httpStatus
      : null;
  bool get allowsSeekRecovery => reason == 'truncated';
  @override
  String toString() => 'SourceInputException($reason)';

  static SourceInputException from(
    Object error, {
    required String stage,
    bool cancelled = false,
  }) {
    if (cancelled) return SourceInputException('cancelled', stage: stage);
    if (error is SourceInputException) return error;
    if (error is TimeoutException) {
      return SourceInputException('timeout', stage: stage);
    }
    if (error is HandshakeException || error is TlsException) {
      return const SourceInputException('tls_certificate', stage: 'tls');
    }
    if (error is SocketException && (stage == 'dns' || stage == 'connect')) {
      return SourceInputException(
        stage == 'dns' ? 'dns_failed' : 'connect_failed',
        stage: stage,
      );
    }
    if (error is HttpException && stage == 'body_read') {
      return const SourceInputException('truncated', stage: 'body_read');
    }
    return SourceInputException('unknown', stage: stage);
  }
}

class SourceInputFailure {
  SourceInputFailure({
    required this.error,
    required this.trace,
    required this.openAttempt,
    required this.request,
    required this.stale,
  }) : id = trace.nextFailure();
  final SourceInputException error;
  final StrmTrace trace;
  final int openAttempt, request, id;
  final bool stale;
  String? _recorded;
  bool _recoverable = false, _recoveryExecuted = false, _observedStale = false;
  int _duplicates = 0;
  bool get cancelled => error.reason == 'cancelled';
  void record({
    bool? recoverable,
    bool? recoveryExecuted,
    int? duplicates,
    bool? staleOverride,
  }) {
    _recoverable = recoverable ?? _recoverable;
    _recoveryExecuted = recoveryExecuted ?? _recoveryExecuted;
    _observedStale = _observedStale || stale || staleOverride == true;
    if (duplicates != null && duplicates > _duplicates) {
      _duplicates = duplicates;
    }
    final state =
        '$_recoverable:$_recoveryExecuted:$_duplicates:$_observedStale';
    if (_recorded == state) return;
    _recorded = state;
    trace.emit('strm_failure', {
      'openAttempt': openAttempt,
      'request': request,
      'failure': id,
      'stage': error.safeStage,
      'reason': error.reason,
      'http': error.safeHttp,
      'stale': _observedStale,
      'cancelled': cancelled,
      'recoverable': _recoverable,
      'recoveryExecuted': _recoveryExecuted,
      'duplicates': _duplicates,
    });
  }
}

abstract interface class SourceFailureEmitter {
  Stream<SourceInputFailure> get sourceFailureStream;
}
