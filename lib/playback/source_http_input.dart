import 'dart:async';
import 'dart:convert';
import '../core/token_redactor.dart';
import 'dart:io';
import 'dart:typed_data';

import 'playback_resource_request.dart';
import 'source_input_failure.dart';
import 'source_read_ahead_policy.dart';
import 'source_socket_connector.dart';
import 'strm_direct_play_policy.dart';
export 'source_input_failure.dart';

/// Progressive input only. HTTP is never delegated to libmpv/FFmpeg. Each
/// bounded Range request (including a seek) repeats destination/auth policy.
class SourceHttpInput {
  SourceHttpInput(
    this.request, {
    required this.embyServer,
    int? openAttempt,
    this.maxConcurrentRequests = 8,
    this.demandReadAheadTimeout = const Duration(seconds: 4),
    int? rangeBytes,
  }) : openAttempt = openAttempt ?? request.trace.currentAttempt,
       _readAheadPolicy = SourceReadAheadPolicy(
         fixedRangeBytes: rangeBytes,
         maximumConcurrency: maxConcurrentRequests,
       ) {
    assert(maxConcurrentRequests >= 1 && maxConcurrentRequests <= 8);
    assert(
      demandReadAheadTimeout > Duration.zero &&
          demandReadAheadTimeout <= const Duration(seconds: 4),
    );
    assert(
      rangeBytes == null || (rangeBytes > 0 && rangeBytes <= 6 * 1024 * 1024),
    );
    _client
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = _connect;
  }

  final PlaybackResourceRequest request;
  final Uri embyServer;
  final int openAttempt;
  final int maxConcurrentRequests;
  final Duration demandReadAheadTimeout;
  final SourceReadAheadPolicy _readAheadPolicy;
  int get rangeBytes => _readAheadPolicy.rangeBytes;
  int get prefetchConcurrency => _parallelEnabled
      ? _readAheadPolicy.concurrency(maxConcurrentRequests)
      : 1;
  final Stopwatch _clock = Stopwatch()..start();
  String _stage = 'connect';
  int? _responseStatus;
  int requestNumber = 0;
  int nativeReads = 0, httpRequests = 0, redirects = 0, ranges = 0;
  int networkBytes = 0, deliveredBytes = 0, prefixHits = 0, requestMs = 0;
  int readAheadHits = 0;
  int prefetchCancellations = 0, prefetchFailures = 0;
  int failures = 0, cancellations = 0, duplicates = 0;
  int _active = 0, _windowAt = 0, _windowBytes = 0;
  bool _summaryWritten = false, _firstRead = false, _nativeMeasured = false;
  final Set<String> _stagesWritten = {};
  final Map<String, SourceInputFailure> _failureKinds = {};
  SourceInputFailure? lastFailure;

  void _event(
    String event,
    Map<String, Object?> fields, {
    _HttpTransfer? transfer,
  }) => request.trace.emit(event, {
    'openAttempt': openAttempt,
    'request': transfer?.requestNumber ?? requestNumber,
    'stale': request.trace.finished || !request.sessionActive,
    ...fields,
  });
  void _stageEvent(
    String stage,
    Map<String, Object?> fields, {
    _HttpTransfer? transfer,
  }) {
    // At most one successful event per stage per input, not one per Range.
    if (_stagesWritten.add(
      '$stage:${fields['crossOrigin']}:${fields['credentialsStripped']}',
    )) {
      _event('strm_http', {'stage': stage, ...fields}, transfer: transfer);
    }
  }

  String? _target;
  Map<String, Object?> _outboundHeaders = {};
  final Map<String, (String, int)> _detailsWritten = {};
  void _detail(
    String stage,
    Map<String, Object?> fields, {
    bool sampled = false,
    _HttpTransfer? transfer,
  }) {
    final target = transfer?.target ?? _target;
    final key = jsonEncode(fields);
    final prior = _detailsWritten[stage];
    if (sampled &&
        prior != null &&
        prior.$1 == target &&
        _clock.elapsedMilliseconds - prior.$2 < 5000) {
      return;
    }
    _detailsWritten[stage] = (
      sampled ? target ?? key : key,
      _clock.elapsedMilliseconds,
    );
    request.trace.detail(
      stage,
      fields,
      openAttempt: openAttempt,
      request: transfer?.requestNumber ?? requestNumber,
    );
  }

  Map<String, Object?> _headers(HttpHeaders headers) {
    final result = <String, Object?>{};
    headers.forEach((key, values) => result[key] = values);
    return result;
  }

  void _recordPolicyFailure(
    Object error, {
    required String stage,
    int? status,
  }) {
    if (!request.isProgressive) return;
    if (error is PlaybackResolveException) {
      request.revokeNativeFallback();
      return;
    }
    // Do not map cancellation here: a concurrently closed transfer may already
    // have observed a disqualifying response, which must remain sticky.
    final failure = SourceInputException.from(error, stage: stage);
    if (const {
          'destination',
          'tls_certificate',
          'tls_downgrade',
          'redirect_limit',
          'redirect_loop',
          'redirect_location',
          'source_denied',
          'source_changed',
          'invalid_range',
          'body_limit',
        }.contains(failure.reason) ||
        (failure.reason == 'range_unsupported' &&
            !const {200, 206}.contains(failure.safeHttp ?? status))) {
      request.revokeNativeFallback();
    }
  }

  SourceInputException _failure(
    Object error, [
    StackTrace? stack,
    _HttpTransfer? transfer,
  ]) {
    final stage = transfer?.stage ?? _stage;
    final status = transfer?.responseStatus ?? _responseStatus;
    _recordPolicyFailure(error, stage: stage, status: status);
    final mapped = SourceInputException.from(
      error is PlaybackResolveException
          ? const SourceInputException('destination')
          : error,
      stage: stage,
      stackTrace: stack,
      cancelled: _closed && error is! SourceInputException,
    );
    final failure = SourceInputException(
      mapped.code,
      stage: mapped.safeStage,
      httpStatus: mapped.safeHttp ?? status,
      cause: mapped.cause ?? error,
      stackTrace: mapped.stackTrace ?? stack,
    );
    if (failure.reason == 'cancelled') {
      cancellations++;
    } else {
      failures++;
    }
    final key = '${failure.safeStage}:${failure.reason}:${failure.safeHttp}';
    if (_failureKinds.containsKey(key)) {
      duplicates++;
      lastFailure = _failureKinds[key];
    } else {
      _detail(stage, {
        'outcome': 'failed',
        'requestUrl': transfer?.target ?? _target,
        'requestHeaders': transfer?.outboundHeaders ?? _outboundHeaders,
        'elapsedMs': _clock.elapsedMilliseconds,
      }, transfer: transfer);
      lastFailure = SourceInputFailure(
        error: failure,
        trace: request.trace,
        openAttempt: openAttempt,
        request: transfer?.requestNumber ?? requestNumber,
        stale: !request.sessionActive,
      );
      _failureKinds[key] = lastFailure!;
      lastFailure!.record();
    }
    return SourceInputException(
      failure.code,
      stage: failure.safeStage,
      httpStatus: failure.safeHttp,
      failure: lastFailure,
    );
  }

  void recordNativeRead() {
    _nativeMeasured = true;
    nativeReads++;
  }

  void recordDelivery(int bytes) {
    deliveredBytes += bytes;
    if (!_firstRead) {
      _firstRead = true;
      _event('strm_native', {'stage': 'native_read', 'outcome': 'first_read'});
    }
    _summary(periodic: true);
  }

  void _summary({bool periodic = false}) {
    if (!periodic && (!_wasClosed || _active != 0 || _summaryWritten)) return;
    final now = _clock.elapsedMilliseconds;
    if (periodic && (now - _windowAt < 5000 || networkBytes == _windowBytes)) {
      return;
    }
    if (!periodic) {
      _summaryWritten = true;
      request.trace.addInputTotals({
        'nativeReads': _nativeMeasured ? nativeReads : null,
        'httpRequests': httpRequests,
        'redirects': redirects,
        'ranges': ranges,
        'networkBytes': networkBytes,
        'deliveredBytes': _nativeMeasured ? deliveredBytes : null,
        'prefixHits': prefixHits,
        'readAheadHits': readAheadHits,
        'requestMs': requestMs,
        'failures': failures,
        'cancellations': cancellations,
        'duplicates': duplicates,
      });
    }
    _event('strm_summary', {
      'scope': 'input',
      'outcome': periodic ? 'periodic' : 'closed',
      'nativeReads': _nativeMeasured ? nativeReads : null,
      'httpRequests': httpRequests,
      'redirects': redirects,
      'ranges': ranges,
      'networkBytes': networkBytes,
      'deliveredBytes': _nativeMeasured ? deliveredBytes : null,
      'prefixHits': prefixHits,
      'readAheadHits': readAheadHits,
      'readAheadBytes': _readAheadBytes,
      'prefetchConcurrency': prefetchConcurrency,
      'prefetchBlockBytes': rangeBytes,
      'activeRequests': _pending.length,
      'prefetchCancellations': prefetchCancellations,
      'prefetchFailures': prefetchFailures,
      'requestMs': requestMs,
      'elapsedMs': now,
      'rateBytes': now == _windowAt
          ? null
          : (networkBytes - _windowBytes) * 1000 ~/ (now - _windowAt),
      'failures': failures,
      'cancellations': cancellations,
      'duplicates': duplicates,
    });
    _windowAt = now;
    _windowBytes = networkBytes;
  }

  final HttpClient _client = HttpClient();
  late final _subtitleTransfer = _HttpTransfer(this, _client, 0, 0, true);
  bool _wasClosed = false;
  bool get _closed => _wasClosed || !request.sessionActive;
  int? _size;
  String? _validator;
  Uint8List? _prefix;
  // Keep the sniffed prefix pinned and recent ranges in LRU order. This cache
  // is per input/attempt and never shared between sources or login sessions.
  static const readAheadSize = 2 * 1024 * 1024;
  static const cacheBudget = 32 * 1024 * 1024;
  final _readAhead = <int, Uint8List>{};
  int _readAheadBytes = 0;
  int get cachedBytes => (_prefix?.length ?? 0) + _readAheadBytes;
  int get reservedBytes => _transfers
      .where((transfer) => !transfer.closed)
      .fold(0, (bytes, transfer) => bytes + transfer.count);
  Future<void> _readTail = Future<void>.value();
  String? format;
  int get size => _size!;

  /// Text subtitle fetch on the same controlled socket/TLS transport. Headers
  /// here are independently authorized by the subtitle owner, never copied
  /// from the video request. Every redirect is checked before sending.
  Future<Uint8List> downloadText({
    required Map<String, String> headers,
    bool Function(String)? authorizeHeaders,
  }) async {
    Future<Uint8List> fetch() async {
      _client.autoUncompress = true;
      var raw = request.rawUrl;
      final origin = Uri.parse(raw).origin;
      var includeHeaders = true;
      final visited = <String>{};
      for (var jumps = 0; jumps <= 5; jumps++) {
        if (_closed) throw const SourceInputException('cancelled');
        includeHeaders = includeHeaders && Uri.parse(raw).origin == origin;
        raw = request.redirectTarget(raw, credentialsAllowed: includeHeaders);
        request.validateTarget(raw);
        if (!visited.add(raw)) {
          throw const SourceInputException('redirect_loop');
        }
        final uri = OpaqueHttpUri(raw);
        includeHeaders =
            includeHeaders &&
            uri.origin == origin &&
            (authorizeHeaders?.call(raw) ?? true);
        requestNumber = request.trace.nextRequest();
        _responseStatus = null;
        _stage = 'connect';
        _target = raw;
        _outboundHeaders = {};
        TokenRedactor.registerCredentials(raw);
        _detail('connect', {
          'outcome': 'started',
          'requestUrl': raw,
          'host': uri.host,
          'port': uri.port,
        }, sampled: true);
        final outbound = await _client.getUrl(uri);
        outbound.followRedirects = false;
        if (includeHeaders) {
          headers.forEach((name, value) => outbound.headers.set(name, value));
        }
        _outboundHeaders = _headers(outbound.headers);
        _detail('request_headers', {
          'requestUrl': raw,
          'headers': _outboundHeaders,
        }, sampled: true);
        _stage = 'range_response';
        httpRequests++;
        final response = await outbound.close();
        _responseStatus = response.statusCode;
        _detail('response_headers', {
          'requestUrl': raw,
          'http': response.statusCode,
          'headers': _headers(response.headers),
        }, sampled: response.statusCode == 200);
        if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          late final String next;
          var cross = false;
          try {
            if (location == null) {
              throw const SourceInputException('redirect_limit');
            }
            next = resolveRawLocation(raw, location);
            cross = Uri.parse(next).origin != uri.origin;
            if (cross) request.markCrossOriginRedirect();
            if (jumps == 5) throw const SourceInputException('redirect_limit');
          } catch (error) {
            _recordPolicyFailure(error, stage: 'redirect');
            rethrow;
          } finally {
            // Record redirect evidence before cancellation can yield to a
            // timeout/stop and its fallback decision. Never drain this body.
            await response.listen((_) {}).cancel();
          }
          if (_closed) throw const SourceInputException('cancelled');
          redirects++;
          _stage = 'redirect';
          _detail('redirect', {
            'fromUrl': raw,
            'location': location,
            'toUrl': next,
            'http': response.statusCode,
          });
          _stageEvent('redirect', {
            'outcome': 'succeeded',
            'http': response.statusCode,
            'redirects': redirects,
            'crossOrigin': cross,
            'credentialsStripped': cross,
          });
          if (uri.scheme == 'https' && Uri.parse(next).scheme != 'https') {
            throw const SourceInputException('tls_downgrade');
          }
          raw = next;
          continue;
        }
        if (response.statusCode != 200 ||
            response.contentLength > 10 * 1024 * 1024) {
          final failure = SourceInputException(
            response.statusCode == 401 || response.statusCode == 403
                ? 'source_denied'
                : response.contentLength > 10 * 1024 * 1024
                ? 'subtitle_budget'
                : 'unknown',
            stage: 'subtitle_download',
            httpStatus: response.statusCode,
          );
          _recordPolicyFailure(failure, stage: 'subtitle_download');
          await response.listen((_) {}).cancel();
          throw failure;
        }
        _stage = 'body_read';
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (_closed || bytes.length + chunk.length > 10 * 1024 * 1024) {
            throw SourceInputException(
              _closed ? 'cancelled' : 'subtitle_budget',
              stage: 'subtitle_download',
            );
          }
          networkBytes += chunk.length;
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }
      throw const SourceInputException('redirect_limit');
    }

    _active++;
    final watch = Stopwatch()..start();
    try {
      return await fetch().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          close();
          throw const SourceInputException('subtitle_timeout');
        },
      );
    } catch (error, stack) {
      throw _failure(error, stack);
    } finally {
      requestMs += watch.elapsedMilliseconds;
      _active--;
      close();
    }
  }

  Future<void> prepare() async {
    _event('strm_input', {
      'outcome': 'started',
      'headerCount': request.headers.length,
    });
    try {
      _prefix = await _range(0, 262144);
      format = progressiveFormat(_prefix!);
      if (format == null) {
        throw const SourceInputException('unsupported_container');
      }
      _event('strm_input', {
        'outcome': 'succeeded',
        'container': format,
        'lengthKnown': _size != null,
      });
    } catch (error) {
      final failure = error is SourceInputException && error.failure != null
          ? error
          : _failure(error);
      _event('strm_input', {
        'outcome': failure.reason == 'cancelled' ? 'cancelled' : 'failed',
      });
      close();
      throw failure;
    }
  }

  final _pending = <int, _HttpTransfer>{};
  final _transfers = <_HttpTransfer>{};
  final _idleClients = <HttpClient>[];
  int? _lastReadEnd;
  bool _parallelEnabled = true;

  /// Stop obsolete background work without invalidating verified cached bytes
  /// or aborting a native read that libmpv is currently waiting for.
  void cancelPendingPrefetch({int? preserveOffset}) {
    _readAheadPolicy.reset();
    _cancelPendingPrefetch(preserveOffset: preserveOffset);
  }

  void _cancelPendingPrefetch({int? preserveOffset}) {
    for (final transfer in _pending.values.toList()) {
      if (!transfer.demand &&
          !(preserveOffset != null && transfer.contains(preserveOffset))) {
        _pending.remove(transfer.offset);
        prefetchCancellations++;
        transfer.cancel();
      }
    }
  }

  Future<Uint8List> read(int offset, int count) {
    final result = _readTail.then((_) => _read(offset, count));
    _readTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Uint8List> _read(int offset, int count) async {
    if (_closed) throw const SourceInputException('cancelled');
    if (offset < 0 || count <= 0 || count > 262144 || offset >= size) {
      request.revokeNativeFallback();
      throw const SourceInputException('invalid_range');
    }
    if (_lastReadEnd != null && offset != _lastReadEnd) {
      cancelPendingPrefetch(preserveOffset: offset);
    }
    final prefix = _prefix;
    if (prefix != null && offset < prefix.length) {
      prefixHits++;
      final end = (offset + count).clamp(0, prefix.length);
      _lastReadEnd = end;
      return Uint8List.sublistView(prefix, offset, end);
    }
    for (final start in _readAhead.keys.toList().reversed) {
      final bytes = _readAhead[start]!;
      if (offset >= start && offset < start + bytes.length) {
        _readAhead.remove(start);
        _readAhead[start] = bytes;
        readAheadHits++;
        final relative = offset - start;
        final end = (relative + count).clamp(0, bytes.length);
        _lastReadEnd = start + end;
        request.startupProgress.recordBytes(offset, end - relative);
        _readAheadPolicy.consumed(end - relative);
        _fillWindow(start);
        return Uint8List.sublistView(bytes, relative, end);
      }
    }
    var transfer = _pending.values.where((t) => t.contains(offset)).firstOrNull;
    // Reserve a slot for the actual read before any speculative work.
    transfer ??= _schedule(
      offset,
      count: _parallelEnabled ? null : count,
      demand: true,
    );
    transfer.demand = true;
    requestNumber = transfer.requestNumber;
    _fillWindow(transfer.offset);
    if (transfer.count > count) {
      final completed = await transfer.result
          .then((_) => true)
          .timeout(demandReadAheadTimeout, onTimeout: () => false);
      if (!completed) {
        if (_closed) throw const SourceInputException('cancelled');
        // A large speculative body must not hold a small native read hostage.
        // The bridge waits 30s: leave room for one bounded 25s count-sized
        // retry, and stop competing prefetches on a slow connection. Mark the
        // abandoned demand as speculative so its cancellation is not a native
        // input failure. The retry retains the full response/validator checks.
        transfer.demand = false;
        _parallelEnabled = false;
        _readAheadPolicy.failed();
        _cancelPendingPrefetch();
        transfer = _schedule(offset, count: count, demand: true);
        requestNumber = transfer.requestNumber;
      }
    }
    final bytes = await _consume(transfer);
    if (_closed) throw const SourceInputException('cancelled');
    final relative = offset - transfer.offset;
    if (relative >= bytes.length) {
      throw const SourceInputException('truncated');
    }
    final end = (relative + count).clamp(0, bytes.length);
    _lastReadEnd = transfer.offset + end;
    request.startupProgress.recordBytes(offset, end - relative);
    _readAheadPolicy.consumed(end - relative);
    return Uint8List.sublistView(bytes, relative, end);
  }

  void _fillWindow(int start) {
    if (_closed || !_parallelEnabled) return;
    final limit = (start + rangeBytes * prefetchConcurrency).clamp(0, size);
    var offset = start;
    while (offset < limit) {
      // Walk actual coverage, not a fixed block grid: old and new tiers may
      // coexist after adaptation. Never overlap a completed or pending range.
      final cached = _readAhead.entries
          .where(
            (entry) =>
                offset >= entry.key && offset < entry.key + entry.value.length,
          )
          .firstOrNull;
      if (cached != null) {
        offset = cached.key + cached.value.length;
        continue;
      }
      final pending = _pending.values
          .where((t) => t.contains(offset))
          .firstOrNull;
      if (pending != null) {
        offset = pending.offset + pending.count;
        continue;
      }
      if (_pending.length >= prefetchConcurrency) break;
      // Don't turn a growing window's edge into a stream of tiny requests.
      // Wait for room for a full block, except for the actual end of file.
      if (offset + rangeBytes > limit && limit < size) break;
      var end = (offset + rangeBytes).clamp(0, limit);
      for (final next in [..._readAhead.keys, ..._pending.keys]) {
        if (next > offset && next < end) end = next;
      }
      final count = end - offset;
      // Protect the active window while allowing older ranges to be evicted.
      final protectedBytes = _readAhead.entries
          .where(
            (entry) =>
                entry.key + entry.value.length > start && entry.key < limit,
          )
          .fold(0, (bytes, entry) => bytes + entry.value.length);
      if ((_prefix?.length ?? 0) + protectedBytes + reservedBytes + count >
          cacheBudget) {
        break;
      }
      _schedule(
        offset,
        count: count,
        demand: false,
        protectedStart: start,
        protectedEnd: limit,
      );
      offset = end;
    }
  }

  _HttpTransfer _schedule(
    int offset, {
    int? count,
    required bool demand,
    int? protectedStart,
    int? protectedEnd,
  }) {
    if (_pending.length >= prefetchConcurrency) _cancelPendingPrefetch();
    var length = (count ?? rangeBytes).clamp(0, size - offset);
    // A demanded hole can be followed by a completed range of a different size.
    for (final next in [..._readAhead.keys, ..._pending.keys]) {
      if (next > offset && next < offset + length) length = next - offset;
    }
    if (demand &&
        reservedBytes + length + (_prefix?.length ?? 0) > cacheBudget) {
      _cancelPendingPrefetch();
    }
    final transfer = _newTransfer(
      offset,
      length,
      demand: demand,
      protectedStart: protectedStart,
      protectedEnd: protectedEnd,
    );
    _pending[offset] = transfer;
    transfer.result = _runTransfer(transfer, cache: true);
    return transfer;
  }

  _HttpTransfer _newTransfer(
    int offset,
    int count, {
    required bool demand,
    int? protectedStart,
    int? protectedEnd,
  }) {
    _trimCache(
      cacheBudget - reservedBytes - count,
      protectedStart: protectedStart,
      protectedEnd: protectedEnd,
    );
    final client = _idleClients.isEmpty
        ? HttpClient()
        : _idleClients.removeLast();
    final transfer = _HttpTransfer(this, client, offset, count, demand);
    transfer.policyGeneration = _readAheadPolicy.generation;
    client
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = 1
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = ((uri, host, port) =>
          _connect(uri, host, port, transfer));
    _transfers.add(transfer);
    return transfer;
  }

  void _trimCache(int budget, {int? protectedStart, int? protectedEnd}) {
    while (cachedBytes > budget && _readAhead.isNotEmpty) {
      final candidate = _readAhead.entries
          .where(
            (entry) =>
                protectedStart == null ||
                protectedEnd == null ||
                entry.key + entry.value.length <= protectedStart ||
                entry.key >= protectedEnd,
          )
          .firstOrNull;
      if (candidate == null) break;
      _readAheadBytes -= _readAhead.remove(candidate.key)!.length;
    }
  }

  Future<Uint8List> _range(int offset, int count) {
    final transfer = _newTransfer(offset, count, demand: true);
    transfer.result = _runTransfer(transfer, cache: false);
    return _consume(transfer);
  }

  Future<Uint8List> _consume(_HttpTransfer transfer) async {
    final result = await transfer.result;
    if (result.bytes != null) return result.bytes!;
    if (result.error case SourceInputException(failure: != null)) {
      throw result.error!;
    }
    throw _failure(result.error!, result.stack, transfer);
  }

  Future<_TransferResult> _runTransfer(
    _HttpTransfer transfer, {
    required bool cache,
  }) async {
    _active++;
    final clock = Stopwatch()..start();
    var reusable = false;
    var timedOut = false;
    try {
      final bytes = await _fetch(transfer.offset, transfer.count, transfer)
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              timedOut = true;
              transfer.cancel();
              throw SourceInputException('timeout', stage: transfer.stage);
            },
          );
      if (transfer.closed) throw const SourceInputException('cancelled');
      reusable = true;
      if (cache) {
        // Reserve room for all in-flight bodies as well as completed ranges.
        _trimCache(cacheBudget - reservedBytes + transfer.count - bytes.length);
        _readAheadBytes -= _readAhead.remove(transfer.offset)?.length ?? 0;
        _readAhead[transfer.offset] = bytes;
        _readAheadBytes += bytes.length;
      }
      if (cache) {
        _readAheadPolicy.completed(
          bytes: bytes.length,
          elapsed: clock.elapsed,
          sampleGeneration: transfer.policyGeneration,
        );
      }
      return _TransferResult(bytes: bytes);
    } catch (error, stack) {
      _recordPolicyFailure(
        error,
        stage: transfer.stage,
        status: transfer.responseStatus,
      );
      if (!transfer.closed || timedOut) _readAheadPolicy.failed();
      if (!transfer.demand && !_closed && (!transfer.cancelled || timedOut)) {
        // Background failures must not fail playback. Retry on demand using
        // the single-request path and retain all destination/validator checks.
        _parallelEnabled = false;
        prefetchFailures++;
        _cancelPendingPrefetch();
      }
      final mapped = transfer.cancelled && error is! SourceInputException
          ? const SourceInputException('cancelled')
          : error;
      return _TransferResult(
        error: transfer.demand ? _failure(mapped, stack, transfer) : mapped,
        stack: stack,
      );
    } finally {
      requestMs += clock.elapsedMilliseconds;
      _active--;
      if (identical(_pending[transfer.offset], transfer)) {
        _pending.remove(transfer.offset);
      }
      _transfers.remove(transfer);
      if (reusable &&
          !transfer.closed &&
          _idleClients.length < maxConcurrentRequests) {
        _idleClients.add(transfer.client);
      } else {
        transfer.client.close(force: true);
      }
      _summary(periodic: !_wasClosed);
    }
  }

  Future<Uint8List> _fetch(
    int offset,
    int count,
    _HttpTransfer transfer,
  ) async {
    var raw = request.rawUrl;
    final originalOrigin = Uri.parse(raw).origin;
    var credentialsAllowed = true;
    final visited = <String>{};
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (transfer.closed) throw const SourceInputException('cancelled');
      credentialsAllowed =
          credentialsAllowed && Uri.parse(raw).origin == originalOrigin;
      raw = request.redirectTarget(raw, credentialsAllowed: credentialsAllowed);
      request.validateTarget(raw);
      if (!visited.add(raw)) throw const SourceInputException('redirect_loop');
      final uri = OpaqueHttpUri(raw);
      transfer.requestNumber = request.trace.nextRequest();
      transfer.responseStatus = null;
      transfer.stage = 'connect';
      transfer.target = raw;
      transfer.outboundHeaders = {};
      TokenRedactor.registerCredentials(raw);
      transfer.detail('connect', {
        'outcome': 'started',
        'requestUrl': raw,
        'host': uri.host,
        'port': uri.port,
      }, sampled: true);
      final outbound = await transfer.client.getUrl(uri);
      outbound.followRedirects = false;
      outbound.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      outbound.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$offset-${offset + count - 1}',
      );
      if (_validator != null) {
        outbound.headers.set(HttpHeaders.ifRangeHeader, _validator!);
      }
      if (credentialsAllowed) {
        request.headers.forEach(
          (name, value) => outbound.headers.set(name, value),
        );
      }
      transfer.outboundHeaders = _headers(outbound.headers);
      transfer.detail('request_headers', {
        'requestUrl': raw,
        'headers': transfer.outboundHeaders,
      }, sampled: true);
      transfer.stage = 'range_response';
      httpRequests++;
      final response = await outbound.close();
      transfer.responseStatus = response.statusCode;
      transfer.detail('response_headers', {
        'requestUrl': raw,
        'http': response.statusCode,
        'headers': _headers(response.headers),
      }, sampled: response.statusCode == 206);
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        late final String next;
        var cross = false;
        try {
          if (location == null) {
            throw const SourceInputException('redirect_limit');
          }
          next = resolveRawLocation(raw, location);
          cross = Uri.parse(next).origin != uri.origin;
          if (cross) request.markCrossOriginRedirect();
          if (redirects == 5) {
            throw const SourceInputException('redirect_limit');
          }
        } catch (error) {
          _recordPolicyFailure(error, stage: 'redirect');
          rethrow;
        } finally {
          // Sticky evidence must precede this await: stop/timeout can decide
          // whether a native retry is safe while cancellation is unsettled.
          await response.listen((_) {}).cancel();
        }
        if (transfer.closed) throw const SourceInputException('cancelled');
        this.redirects++;
        transfer.stage = 'redirect';
        transfer.detail('redirect', {
          'fromUrl': raw,
          'location': location,
          'toUrl': next,
          'http': response.statusCode,
        });
        transfer.stageEvent('redirect', {
          'outcome': 'succeeded',
          'http': response.statusCode,
          'redirects': this.redirects,
          'crossOrigin': cross,
          'credentialsStripped': cross,
        });
        if (uri.scheme == 'https' && Uri.parse(next).scheme != 'https') {
          throw const SourceInputException('tls_downgrade');
        }
        raw = next;
        continue;
      }
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (response.statusCode != 206 ||
          range == null ||
          (encoding != null && encoding != 'identity')) {
        final failure = SourceInputException(
          response.statusCode == 401 || response.statusCode == 403
              ? 'source_denied'
              : 'range_unsupported',
          stage: 'range_response',
          httpStatus: response.statusCode,
        );
        _recordPolicyFailure(failure, stage: 'range_response');
        await response.listen((_) {}).cancel();
        throw failure;
      }
      final start = int.parse(range[1]!);
      final end = int.parse(range[2]!);
      final total = int.parse(range[3]!);
      if (start != offset ||
          end < start ||
          end >= offset + count ||
          total <= end ||
          (_size != null && _size != total)) {
        final failure = SourceInputException(
          'source_changed',
          httpStatus: response.statusCode,
        );
        _recordPolicyFailure(failure, stage: 'range_response');
        await response.listen((_) {}).cancel();
        throw failure;
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final validator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers.value(HttpHeaders.lastModifiedHeader);
      if (_validator != null && validator != _validator) {
        final failure = SourceInputException(
          'source_changed',
          httpStatus: response.statusCode,
        );
        _recordPolicyFailure(failure, stage: 'range_response');
        await response.listen((_) {}).cancel();
        throw failure;
      }
      _validator ??= validator;
      _size = total;
      transfer.stage = 'body_read';
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (transfer.closed || bytes.length + chunk.length > end - start + 1) {
          throw SourceInputException(
            transfer.closed ? 'cancelled' : 'body_limit',
          );
        }
        networkBytes += chunk.length;
        if (transfer.demand) {
          request.startupProgress.recordBytes(
            start + bytes.length,
            chunk.length,
          );
        }
        bytes.add(chunk);
      }
      if (bytes.length != end - start + 1) {
        throw SourceInputException(
          'truncated',
          stage: 'body_read',
          httpStatus: response.statusCode,
        );
      }
      ranges++;
      transfer.stageEvent('range_response', {
        'outcome': 'succeeded',
        'http': response.statusCode,
        'rangeValid': true,
        'lengthKnown': true,
      });
      return bytes.takeBytes();
    }
    throw const SourceInputException('redirect_limit');
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, [
    _HttpTransfer? operation,
  ]) async {
    final transfer = operation ?? _subtitleTransfer;
    if (operation == null) {
      transfer.requestNumber = requestNumber;
      transfer.target = _target;
    }
    if (transfer.closed || proxyHost != null) {
      throw const SourceInputException('cancelled');
    }
    transfer.stage = 'dns';
    transfer.detail('dns', {
      'outcome': 'started',
      'requestUrl': transfer.target,
      'host': uri.host,
      'port': uri.port,
    });
    late List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(uri.host);
    } catch (error, stack) {
      throw SourceInputException.from(
        error,
        stage: 'dns',
        cancelled: transfer.closed,
        stackTrace: stack,
      );
    }
    transfer.detail('dns', {
      'outcome': 'succeeded',
      'host': uri.host,
      'port': uri.port,
      'addresses': addresses.map((a) => a.address).toList(),
    });
    transfer.stageEvent('dns', {
      'outcome': 'succeeded',
      'candidates': addresses.length,
      'family': addresses.map((a) => a.type).toSet().length > 1
          ? 'mixed'
          : addresses.isNotEmpty &&
                addresses.first.type == InternetAddressType.IPv6
          ? 'ipv6'
          : 'ipv4',
    });
    if (transfer.closed || addresses.isEmpty) {
      throw SourceInputException(
        transfer.closed ? 'cancelled' : 'dns_failed',
        stage: 'dns',
      );
    }
    // Validate resolved addresses too: DNS must not bypass the literal checks.
    for (final address in addresses) {
      request.validateResolvedAddress(address);
    }
    transfer.stage = 'connect';
    final task = connectSourceAddresses(
      addresses,
      uri.port,
      onAttempt: (address) => transfer.detail('connect_attempt', {
        'requestUrl': transfer.target,
        'host': uri.host,
        'ip': address.address,
        'port': uri.port,
      }),
    );
    Socket? active;
    var cancelled = false;
    final future = task.socket.then<Socket>((socket) async {
      active = socket;
      if (transfer.closed || cancelled) {
        socket.destroy();
        throw const SourceInputException('cancelled');
      }
      transfer.stageEvent('connect', {
        'outcome': 'succeeded',
        'family': socket.remoteAddress.type == InternetAddressType.IPv6
            ? 'ipv6'
            : 'ipv4',
      });
      if (uri.scheme == 'https') {
        transfer.stage = 'tls';
        final secured = await SecureSocket.secure(socket, host: uri.host);
        transfer.stageEvent('tls', {'outcome': 'succeeded'});
        active = secured;
        if (transfer.closed || cancelled) {
          secured.destroy();
          throw const SourceInputException('cancelled');
        }
        return secured;
      }
      return socket;
    });
    return ConnectionTask.fromSocket(future, () {
      cancelled = true;
      task.cancel();
      active?.destroy();
    });
  }

  void close() {
    _wasClosed = true;
    _prefix = null;
    _readAhead.clear();
    _readAheadBytes = 0;
    for (final transfer in _transfers.toList()) {
      transfer.cancel();
    }
    _pending.clear();
    for (final client in _idleClients) {
      client.close(force: true);
    }
    _idleClients.clear();
    _client.close(force: true);
    _summary();
  }

  /// Restrict the demuxer too: playlists/concat can otherwise open subresources
  /// behind the stream callback. The engine forces this sniffed container.
  static String? progressiveFormat(Uint8List bytes) {
    bool at(int start, List<int> value) =>
        bytes.length >= start + value.length &&
        List.generate(
          value.length,
          (i) => bytes[start + i] == value[i],
        ).every((v) => v);
    if (at(4, [0x66, 0x74, 0x79, 0x70])) return 'mov';
    if (at(0, [0x1a, 0x45, 0xdf, 0xa3])) return 'matroska';
    if (at(0, [82, 73, 70, 70]) && at(8, [65, 86, 73, 32])) return 'avi';
    if (bytes.length > 376 &&
        bytes[0] == 0x47 &&
        bytes[188] == 0x47 &&
        bytes[376] == 0x47) {
      return 'mpegts';
    }
    return null;
  }
}

class _TransferResult {
  const _TransferResult({this.bytes, this.error, this.stack});
  final Uint8List? bytes;
  final Object? error;
  final StackTrace? stack;
}

class _HttpTransfer {
  _HttpTransfer(this.owner, this.client, this.offset, this.count, this.demand);
  final SourceHttpInput owner;
  final HttpClient client;
  final int offset, count;
  bool demand, cancelled = false;
  String stage = 'connect';
  int? responseStatus;
  int requestNumber = 0;
  int policyGeneration = 0;
  String? target;
  Map<String, Object?> outboundHeaders = {};
  late Future<_TransferResult> result;
  bool get closed => cancelled || owner._closed;
  bool contains(int position) =>
      position >= offset && position < offset + count;
  void cancel() {
    cancelled = true;
    client.close(force: true);
  }

  void detail(
    String stage,
    Map<String, Object?> fields, {
    bool sampled = false,
  }) => owner._detail(stage, fields, sampled: sampled, transfer: this);
  void stageEvent(String stage, Map<String, Object?> fields) =>
      owner._stageEvent(stage, fields, transfer: this);
}

/// HttpClient uses path/query for the wire request. Keep the opaque spelling
/// while delegating host/TLS semantics to the parsed validation copy.
class OpaqueHttpUri implements Uri {
  OpaqueHttpUri(this.raw) : parsed = Uri.parse(raw) {
    final authorityEnd = raw.indexOf(RegExp(r'[/?#]'), raw.indexOf('://') + 3);
    final target = authorityEnd < 0 ? '' : raw.substring(authorityEnd);
    final question = target.indexOf('?');
    path = question < 0 ? target : target.substring(0, question);
    query = question < 0 ? '' : target.substring(question + 1);
    hasQuery = question >= 0;
  }
  final String raw;
  final Uri parsed;
  @override
  late final String path;
  @override
  late final String query;
  @override
  late final bool hasQuery;
  @override
  String get scheme => parsed.scheme;
  @override
  String get host => parsed.host;
  @override
  int get port => parsed.port;
  @override
  String get origin => parsed.origin;
  @override
  String get authority => parsed.authority;
  @override
  String get userInfo => parsed.userInfo;
  @override
  bool get hasFragment => parsed.hasFragment;
  @override
  bool get hasAuthority => true;
  @override
  bool get hasPort => parsed.hasPort;
  @override
  bool get isAbsolute => true;
  @override
  String get fragment => parsed.fragment;
  @override
  Uri removeFragment() => this;
  @override
  bool isScheme(String value) => parsed.isScheme(value);
  @override
  String toString() => raw;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const SourceInputException('uri_operation');
}

String resolveRawLocation(String base, String location) {
  if (RegExp(r'^https?://').hasMatch(location)) return location;
  final current = OpaqueHttpUri(base);
  if (location.startsWith('//')) return '${current.scheme}:$location';
  final prefix = '${current.scheme}://${current.authority}';
  if (location.startsWith('?')) return '$prefix${current.path}$location';
  if (location.isEmpty ||
      location.contains('#') ||
      RegExp(r'^[^/]*:').hasMatch(location)) {
    throw const SourceInputException('redirect_location');
  }
  final split = location.indexOf('?');
  final path = split < 0 ? location : location.substring(0, split);
  final query = split < 0 ? '' : location.substring(split);
  final combined = path.startsWith('/')
      ? path
      : '${current.path.substring(0, current.path.lastIndexOf('/') + 1)}$path';
  final segments = <String>[];
  for (final segment in combined.split('/')) {
    if (segment == '..') {
      if (segments.length > 1) segments.removeLast();
    } else if (segment != '.') {
      segments.add(segment);
    }
  }
  return '$prefix/${segments.join('/').replaceFirst(RegExp(r'^/'), '')}$query';
}
