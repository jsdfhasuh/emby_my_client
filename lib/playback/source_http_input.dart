import 'dart:async';
import 'dart:convert';
import '../core/token_redactor.dart';
import 'dart:io';
import 'dart:typed_data';

import 'playback_resource_request.dart';
import 'source_input_failure.dart';
import 'strm_direct_play_policy.dart';
export 'source_input_failure.dart';

/// Progressive input only. HTTP is never delegated to libmpv/FFmpeg. Each
/// bounded Range request (including a seek) repeats destination/auth policy.
class SourceHttpInput {
  SourceHttpInput(this.request, {required this.embyServer, int? openAttempt})
    : openAttempt = openAttempt ?? request.trace.currentAttempt {
    _client
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = _connect;
  }

  final PlaybackResourceRequest request;
  final Uri embyServer;
  final int openAttempt;
  final Stopwatch _clock = Stopwatch()..start();
  String _stage = 'connect';
  int? _responseStatus;
  int requestNumber = 0;
  int nativeReads = 0, httpRequests = 0, redirects = 0, ranges = 0;
  int networkBytes = 0, deliveredBytes = 0, prefixHits = 0, requestMs = 0;
  int failures = 0, cancellations = 0, duplicates = 0;
  int _active = 0, _windowAt = 0, _windowBytes = 0;
  bool _summaryWritten = false, _firstRead = false, _nativeMeasured = false;
  final Set<String> _stagesWritten = {};
  final Map<String, SourceInputFailure> _failureKinds = {};
  SourceInputFailure? lastFailure;

  void _event(String event, Map<String, Object?> fields) =>
      request.trace.emit(event, {
        'openAttempt': openAttempt,
        'request': requestNumber,
        'stale': request.trace.finished || !request.sessionActive,
        ...fields,
      });
  void _stageEvent(String stage, Map<String, Object?> fields) {
    // At most one successful event per stage per input, not one per Range.
    if (_stagesWritten.add(
      '$stage:${fields['crossOrigin']}:${fields['credentialsStripped']}',
    )) {
      _event('strm_http', {'stage': stage, ...fields});
    }
  }

  String? _target;
  Map<String, Object?> _outboundHeaders = {};
  final Map<String, (String, int)> _detailsWritten = {};
  void _detail(
    String stage,
    Map<String, Object?> fields, {
    bool sampled = false,
  }) {
    final key = jsonEncode(fields);
    final prior = _detailsWritten[stage];
    if (sampled &&
        prior != null &&
        prior.$1 == _target &&
        _clock.elapsedMilliseconds - prior.$2 < 5000) {
      return;
    }
    _detailsWritten[stage] = (
      sampled ? _target ?? key : key,
      _clock.elapsedMilliseconds,
    );
    request.trace.detail(
      stage,
      fields,
      openAttempt: openAttempt,
      request: requestNumber,
    );
  }

  Map<String, Object?> _headers(HttpHeaders headers) {
    final result = <String, Object?>{};
    headers.forEach((key, values) => result[key] = values);
    return result;
  }

  SourceInputException _failure(Object error, [StackTrace? stack]) {
    final mapped = SourceInputException.from(
      error is PlaybackResolveException
          ? const SourceInputException('destination')
          : error,
      stage: _stage,
      stackTrace: stack,
      cancelled: _closed && error is! SourceInputException,
    );
    final failure = SourceInputException(
      mapped.code,
      stage: mapped.safeStage,
      httpStatus: mapped.safeHttp ?? _responseStatus,
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
      _detail(_stage, {
        'outcome': 'failed',
        'requestUrl': _target,
        'requestHeaders': _outboundHeaders,
        'elapsedMs': _clock.elapsedMilliseconds,
      });
      lastFailure = SourceInputFailure(
        error: failure,
        trace: request.trace,
        openAttempt: openAttempt,
        request: requestNumber,
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
  bool _wasClosed = false;
  bool get _closed => _wasClosed || !request.sessionActive;
  int? _size;
  String? _validator;
  Uint8List? _prefix;
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
        PlaybackResourceRequest.validateDestination(
          raw,
          embyServer: embyServer,
        );
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
          await response.listen((_) {}).cancel();
          if (location == null || jumps == 5) {
            throw const SourceInputException('redirect_limit');
          }
          redirects++;
          _stage = 'redirect';
          final next = resolveRawLocation(raw, location);
          _detail('redirect', {
            'fromUrl': raw,
            'location': location,
            'toUrl': next,
            'http': response.statusCode,
          });
          final cross = Uri.parse(next).origin != uri.origin;
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
          await response.listen((_) {}).cancel();
          throw SourceInputException(
            response.statusCode == 401 || response.statusCode == 403
                ? 'source_denied'
                : response.contentLength > 10 * 1024 * 1024
                ? 'subtitle_budget'
                : 'unknown',
            stage: 'subtitle_download',
            httpStatus: response.statusCode,
          );
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

  Future<Uint8List> read(int offset, int count) async {
    if (_closed) throw const SourceInputException('cancelled');
    if (offset < 0 || count <= 0 || count > 262144 || offset >= size) {
      throw const SourceInputException('invalid_range');
    }
    final prefix = _prefix;
    if (prefix != null && offset < prefix.length) {
      prefixHits++;
      final end = (offset + count).clamp(0, prefix.length);
      return Uint8List.sublistView(prefix, offset, end);
    }
    return _range(offset, count);
  }

  Future<Uint8List> _range(int offset, int count) async {
    _active++;
    final clock = Stopwatch()..start();
    try {
      return await _fetch(offset, count).timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          close();
          throw SourceInputException('timeout', stage: _stage);
        },
      );
    } catch (error, stack) {
      throw _failure(error, stack);
    } finally {
      requestMs += clock.elapsedMilliseconds;
      _active--;
      _summary(periodic: !_wasClosed);
    }
  }

  Future<Uint8List> _fetch(int offset, int count) async {
    var raw = request.rawUrl;
    final originalOrigin = Uri.parse(raw).origin;
    var credentialsAllowed = true;
    final visited = <String>{};
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (_closed) throw const SourceInputException('cancelled');
      PlaybackResourceRequest.validateDestination(raw, embyServer: embyServer);
      if (!visited.add(raw)) throw const SourceInputException('redirect_loop');
      final uri = OpaqueHttpUri(raw);
      credentialsAllowed = credentialsAllowed && uri.origin == originalOrigin;
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
      }, sampled: response.statusCode == 206);
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        // Cancel, don't drain an unbounded redirect body.
        await response.listen((_) {}).cancel();
        if (location == null || redirects == 5) {
          throw const SourceInputException('redirect_limit');
        }
        this.redirects++;
        _stage = 'redirect';
        final next = resolveRawLocation(raw, location);
        _detail('redirect', {
          'fromUrl': raw,
          'location': location,
          'toUrl': next,
          'http': response.statusCode,
        });
        final cross = Uri.parse(next).origin != uri.origin;
        _stageEvent('redirect', {
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
        await response.listen((_) {}).cancel();
        throw SourceInputException(
          response.statusCode == 401 || response.statusCode == 403
              ? 'source_denied'
              : 'range_unsupported',
          stage: 'range_response',
          httpStatus: response.statusCode,
        );
      }
      final start = int.parse(range[1]!);
      final end = int.parse(range[2]!);
      final total = int.parse(range[3]!);
      if (start != offset ||
          end < start ||
          end >= offset + count ||
          total <= end ||
          (_size != null && _size != total)) {
        await response.listen((_) {}).cancel();
        throw SourceInputException(
          'source_changed',
          httpStatus: response.statusCode,
        );
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final validator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers.value(HttpHeaders.lastModifiedHeader);
      if (_validator != null && validator != _validator) {
        await response.listen((_) {}).cancel();
        throw SourceInputException(
          'source_changed',
          httpStatus: response.statusCode,
        );
      }
      _validator ??= validator;
      _size = total;
      _stage = 'body_read';
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (_closed || bytes.length + chunk.length > end - start + 1) {
          throw SourceInputException(_closed ? 'cancelled' : 'body_limit');
        }
        networkBytes += chunk.length;
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
      _stageEvent('range_response', {
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
    int? proxyPort,
  ) async {
    if (_closed || proxyHost != null) {
      throw const SourceInputException('cancelled');
    }
    _stage = 'dns';
    _detail('dns', {
      'outcome': 'started',
      'requestUrl': _target,
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
        cancelled: _closed,
        stackTrace: stack,
      );
    }
    _detail('dns', {
      'outcome': 'succeeded',
      'host': uri.host,
      'port': uri.port,
      'addresses': addresses.map((a) => a.address).toList(),
    });
    _stageEvent('dns', {
      'outcome': 'succeeded',
      'candidates': addresses.length,
      'family': addresses.map((a) => a.type).toSet().length > 1
          ? 'mixed'
          : addresses.isNotEmpty &&
                addresses.first.type == InternetAddressType.IPv6
          ? 'ipv6'
          : 'ipv4',
    });
    if (_closed || addresses.isEmpty) {
      throw SourceInputException(
        _closed ? 'cancelled' : 'dns_failed',
        stage: 'dns',
      );
    }
    // Validate resolved addresses too: DNS must not bypass the literal checks.
    for (final address in addresses) {
      final host = address.type == InternetAddressType.IPv6
          ? '[${address.address}]'
          : address.address;
      PlaybackResourceRequest.validateDestination(
        'http://$host/',
        embyServer: embyServer,
      );
    }
    _stage = 'connect';
    _detail('connect_attempt', {
      'requestUrl': _target,
      'host': uri.host,
      'ip': addresses.first.address,
      'port': uri.port,
    });
    final task = await Socket.startConnect(addresses.first, uri.port);
    Socket? active;
    var cancelled = false;
    final future = task.socket.then<Socket>((socket) async {
      _stageEvent('connect', {'outcome': 'succeeded'});
      active = socket;
      if (_closed || cancelled) {
        socket.destroy();
        throw const SourceInputException('cancelled');
      }
      if (uri.scheme == 'https') {
        _stage = 'tls';
        final secured = await SecureSocket.secure(socket, host: uri.host);
        _stageEvent('tls', {'outcome': 'succeeded'});
        active = secured;
        if (_closed || cancelled) {
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
