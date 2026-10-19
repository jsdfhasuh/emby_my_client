import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../core/diagnostic_log.dart';
import 'download_connection.dart';
import 'download_transport.dart' show DownloadResponse;

class DownloadProxy {
  const DownloadProxy({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });
  final String host;
  final int port;
  final String username;
  final String password;
  @override
  String toString() => 'DownloadProxy';
}

class DownloadHttpStatusException implements Exception {
  const DownloadHttpStatusException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Download HTTP $statusCode';
}

/// Download-only transport. It never changes HttpOverrides or player networking.
class DownloadHttpClient {
  DownloadHttpClient({
    required this.server,
    required Map<String, String> headers,
    this.proxy,
    this.connectTimeout = const Duration(seconds: 12),
    this.receiveTimeout = const Duration(seconds: 25),
    HttpClient? client,
    SecurityContext? securityContext,
    this.taskId,
  }) : _headers = Map.unmodifiable(headers),
       _securityContext = securityContext,
       _client = client ?? HttpClient(context: securityContext) {
    _client
      ..autoUncompress = false
      ..connectionTimeout = connectTimeout
      ..findProxy = ((_) => 'DIRECT');
    if (proxy != null) {
      _client.connectionFactory = _connectTunnel;
    }
  }

  final Uri server;
  final DownloadProxy? proxy;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Map<String, String> _headers;
  final HttpClient _client;
  final SecurityContext? _securityContext;
  final Set<HttpClient> _tunnelClients = {};
  final String? taskId;
  int _attemptNumber = 0;
  bool _closed = false;

  Future<ConnectionTask<Socket>> _connectTunnel(
    Uri uri,
    String? host,
    int? port,
  ) async {
    final endpoint = proxy!;
    Socket? wire;
    var cancelled = false;
    final connector = HttpClient()
      ..connectionTimeout = connectTimeout
      ..findProxy = ((_) => 'PROXY ${endpoint.host}:${endpoint.port}');
    connector.connectionFactory = (_, _, _) async {
      final task = await Socket.startConnect(endpoint.host, endpoint.port);
      return ConnectionTask.fromSocket(
        task.socket.then((socket) {
          wire = socket;
          if (cancelled) socket.destroy();
          return socket;
        }),
        task.cancel,
      );
    };
    _tunnelClients.add(connector);
    Future<Socket> connect() async {
      try {
        // A separate CONNECT client owns proxy authentication. The origin
        // client has no proxy credentials, even if an origin responds 407.
        final request = await connector.openUrl(
          'CONNECT',
          Uri(scheme: 'http', host: uri.host, port: uri.port),
        );
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.proxyAuthorizationHeader,
          'Basic ${base64Encode(utf8.encode('${endpoint.username}:${endpoint.password}'))}',
        );
        final response = await request.close().timeout(connectTimeout);
        if (response.statusCode != HttpStatus.ok) {
          await response
              .listen((_) {}, onError: (Object _, StackTrace _) {})
              .cancel();
          throw const DownloadConnectionException('tunnelUnavailable');
        }
        final detached = await response.detachSocket();
        Socket socket = detached;
        if (uri.scheme == 'https') {
          final secured = SecureSocket.secure(
            wire!,
            host: uri.host,
            context: _securityContext,
          );
          unawaited(
            secured.then<void>((lateSocket) {
              if (cancelled || _closed) lateSocket.destroy();
            }, onError: (Object _, StackTrace _) {}),
          );
          socket = await secured.timeout(
            connectTimeout,
            onTimeout: () {
              cancelled = true;
              throw TimeoutException('Download TLS connection timeout');
            },
          );
        }
        wire = socket;
        if (cancelled || _closed) {
          socket.destroy();
          throw const DownloadConnectionException('connectionClosed');
        }
        return socket;
      } catch (_) {
        cancelled = true;
        wire?.destroy();
        rethrow;
      } finally {
        _tunnelClients.remove(connector);
        connector.close(force: true);
      }
    }

    return ConnectionTask.fromSocket(connect(), () {
      cancelled = true;
      connector.close(force: true);
      wire?.destroy();
    });
  }

  Future<DownloadResponse> open(
    Uri uri, {
    required CancelToken cancelToken,
    int offset = 0,
    String? etag,
    bool followRedirects = true,
  }) async {
    if (_closed) throw const DownloadConnectionException('connectionClosed');
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    if (!_httpDestination(uri)) {
      throw const DownloadConnectionException('redirectRejected');
    }
    final id = List.generate(
      8,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final clock = Stopwatch()..start();
    final attemptNumber = ++_attemptNumber;
    var current = uri;
    var credentialsAllowed = current.origin == server.origin;
    final visited = <String>{};
    for (var jumps = 0; jumps <= 5; jumps++) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (!const {'http', 'https'}.contains(current.scheme) ||
          current.host.isEmpty ||
          current.userInfo.isNotEmpty ||
          !visited.add(current.toString())) {
        throw const DownloadConnectionException('redirectRejected');
      }
      final attempt = _DownloadAttempt(
        id: id,
        uri: current,
        mode: proxy == null ? 'direct' : 'hysteria2',
        offset: offset,
        clock: clock,
        cancelToken: cancelToken,
        taskId: taskId,
        attemptNumber: attemptNumber,
      );
      try {
        final pending = _client.getUrl(current);
        // HttpClient does not expose a cancellable DNS/TCP Future. Abort any
        // late request before it can send headers, and observe its completion.
        unawaited(
          pending.then<void>((request) {
            if (attempt.closed) request.abort(const _DownloadAborted());
          }, onError: (Object _, StackTrace _) {}),
        );
        final request = await Future.any<HttpClientRequest>([
          pending,
          attempt.cancelled.future.then<HttpClientRequest>(
            (_) => throw cancelToken.cancelError ?? const _DownloadAborted(),
          ),
        ]).timeout(connectTimeout);
        attempt.request = request;
        if (attempt.closed) {
          throw cancelToken.cancelError ?? const _DownloadAborted();
        }
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (offset > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) {
            request.headers.set(HttpHeaders.ifRangeHeader, etag);
          }
        }
        if (credentialsAllowed) _headers.forEach(request.headers.set);
        // dart:io can copy cached proxy credentials onto the inner HTTPS
        // request after CONNECT. They belong only to the loopback proxy.
        if (current.scheme == 'https') {
          request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
        }
        final response = await request.close().timeout(receiveTimeout);
        attempt.response = response;
        attempt.status = response.statusCode;
        attempt.headersMs = clock.elapsedMilliseconds;
        attempt.peer = response.connectionInfo?.remoteAddress.address;
        final headers = <String, String>{};
        response.headers.forEach(
          (name, values) => headers[name.toLowerCase()] = values.join(','),
        );
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode) &&
            followRedirects) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await attempt.close('redirect');
          if (location == null || jumps == 5) {
            throw const DownloadConnectionException('redirectRejected');
          }
          final next = current.resolve(location);
          if (!_httpDestination(next)) {
            throw const DownloadConnectionException('redirectRejected');
          }
          if (current.scheme == 'https' && next.scheme != 'https') {
            throw const DownloadConnectionException('tlsDowngrade');
          }
          final cross = next.origin != current.origin;
          _log({
            'event': 'download_redirect',
            'requestId': id,
            'hop': jumps + 1,
            'status': response.statusCode,
            'from': _safeUrl(current),
            'to': _safeUrl(next),
            'crossOrigin': cross,
          });
          credentialsAllowed =
              credentialsAllowed && next.origin == server.origin;
          current = next;
          continue;
        }
        if (!const {200, 206, 416}.contains(response.statusCode) &&
            !(!followRedirects &&
                const {
                  301,
                  302,
                  303,
                  307,
                  308,
                }.contains(response.statusCode))) {
          await attempt.close('http_error');
          throw DownloadHttpStatusException(response.statusCode);
        }
        return DownloadResponse(
          statusCode: response.statusCode,
          headers: headers,
          stream: attempt.body(receiveTimeout),
          onClose: () => attempt.close('response_closed'),
        );
      } catch (error) {
        await attempt.close(
          cancelToken.isCancelled ? 'task_cancelled' : 'request_failed',
        );
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        if (proxy != null &&
            (error is SocketException || error is HttpException)) {
          throw const DownloadConnectionException('tunnelUnavailable');
        }
        if (error is HttpException) {
          throw const HttpException('Download transport failed');
        }
        if (error is FormatException) {
          throw const DownloadConnectionException('redirectRejected');
        }
        rethrow;
      }
    }
    throw const DownloadConnectionException('redirectRejected');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
    for (final connector in _tunnelClients.toList()) {
      connector.close(force: true);
    }
    _tunnelClients.clear();
  }
}

class _DownloadAborted implements Exception {
  const _DownloadAborted();
}

class _DownloadAttempt {
  _DownloadAttempt({
    required this.id,
    required this.uri,
    required this.mode,
    required this.offset,
    required this.clock,
    required this.cancelToken,
    this.taskId,
    required this.attemptNumber,
  }) {
    unawaited(cancelToken.whenCancel.then((_) => close('task_cancelled')));
  }
  final String id;
  final Uri uri;
  final String mode;
  final int offset;
  final Stopwatch clock;
  final CancelToken cancelToken;
  final String? taskId;
  final int attemptNumber;
  final cancelled = Completer<void>();
  HttpClientRequest? request;
  HttpClientResponse? response;
  StreamSubscription<List<int>>? subscription;
  StreamController<List<int>>? controller;
  Future<void>? _closing;
  bool closed = false;
  bool completed = false;
  bool listened = false;
  int bytes = 0;
  int? firstByteMs;
  int? status;
  int? headersMs;
  String? peer;

  Stream<List<int>> body(Duration timeout) {
    final sink = StreamController<List<int>>(sync: true);
    controller = sink;
    sink.onListen = () {
      listened = true;
      if (closed) {
        sink.addError(cancelToken.cancelError ?? const _DownloadAborted());
        unawaited(sink.close());
        return;
      }
      subscription = response!
          .timeout(
            timeout,
            onTimeout: (events) {
              events.addError(
                TimeoutException('Download receive idle timeout'),
              );
              request?.abort(const _DownloadAborted());
            },
          )
          .listen(
            (chunk) {
              firstByteMs ??= clock.elapsedMilliseconds;
              bytes += chunk.length;
              sink.add(chunk);
            },
            onError: (Object error, StackTrace stack) {
              sink.addError(cancelToken.cancelError ?? error, stack);
            },
            onDone: () {
              completed = true;
              _summary('completed');
              unawaited(sink.close());
            },
            cancelOnError: false,
          );
    };
    sink.onPause = () => subscription?.pause();
    sink.onResume = () => subscription?.resume();
    sink.onCancel = () => close(completed ? 'completed' : 'body_cancelled');
    return sink.stream;
  }

  bool _logged = false;
  void _summary(String reason) {
    if (_logged) return;
    _logged = true;
    _log({
      'event': 'download_request',
      'requestId': id,
      'taskId': taskId,
      'attempt': attemptNumber,
      'mode': mode,
      'url': _safeUrl(uri),
      'range': offset > 0 ? 'bytes=$offset-' : 'none',
      'status': status,
      'bytes': bytes,
      'headersMs': headersMs,
      'firstByteMs': firstByteMs,
      'elapsedMs': clock.elapsedMilliseconds,
      'dnsMs': 'unavailable',
      'connectMs': 'unavailable',
      'tlsMs': 'unavailable',
      'peerIp': peer,
      'peerKind': mode == 'direct' ? 'server' : 'local_proxy',
      'reason': reason,
      'cancelReason': cancelToken.isCancelled
          ? _cancelReason(cancelToken)
          : null,
    });
  }

  Future<void> close(String reason) => _closing ??= _close(reason);
  Future<void> _close(String reason) async {
    closed = true;
    if (!cancelled.isCompleted) cancelled.complete();
    if (!completed) request?.abort(const _DownloadAborted());
    final active = subscription;
    if (active != null) {
      await active.cancel();
    } else if (!listened && response != null) {
      await response!
          .listen((_) {}, onError: (Object _, StackTrace _) {})
          .cancel();
    }
    final sink = controller;
    if (sink != null && sink.hasListener && !sink.isClosed && !completed) {
      sink.addError(cancelToken.cancelError ?? const _DownloadAborted());
      unawaited(sink.close());
    }
    _summary(completed ? 'completed' : reason);
  }
}

String _safeUrl(Uri uri) =>
    '${uri.scheme}://${uri.host.contains(':') ? '[${uri.host}]' : uri.host}'
    ':${uri.port}${uri.path}';
void _log(Map<String, Object?> fields) =>
    DiagnosticLog.instance.info('download', jsonEncode(fields));

bool _httpDestination(Uri uri) =>
    const {'http', 'https'}.contains(uri.scheme) &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

String _cancelReason(CancelToken token) {
  final reason = token.cancelError?.error;
  return const {
        'pause',
        'delete',
        'shutdown',
        'wifiRequired',
        'networkUnavailable',
        'cancelSubtitleRepair',
        'assetCancelled',
      }.contains(reason)
      ? reason as String
      : 'cancelled';
}
