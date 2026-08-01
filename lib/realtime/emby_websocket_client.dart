import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/diagnostic_log.dart';
import '../models/emby_models.dart';
import 'emby_event.dart';

abstract interface class EmbySocket {
  Stream<dynamic> get messages;
  void add(String data);
  Future<void> close();
}

typedef EmbySocketConnector = Future<EmbySocket> Function(Uri uri);
typedef EmbyReconnectDelay = Duration Function(int attempt);
typedef EmbyKeepAliveInterval = Duration Function(int serverIntervalSeconds);
typedef EmbySocketConnectedCallback = FutureOr<void> Function();

class EmbyWebSocketClient {
  EmbyWebSocketClient(
    this.session, {
    EmbySocketConnector? connector,
    EmbyReconnectDelay? reconnectDelay,
    EmbyKeepAliveInterval? keepAliveInterval,
    EmbySocketConnectedCallback? onConnected,
    this.connectionTimeout = const Duration(seconds: 12),
    Random? random,
  }) : _connector = connector ?? _connectIoSocket,
       _random = random ?? Random(),
       _reconnectDelay = reconnectDelay,
       _onConnected = onConnected,
       _keepAliveInterval = keepAliveInterval ?? _defaultKeepAliveInterval;

  final EmbySession session;
  final EmbySocketConnector _connector;
  final EmbyReconnectDelay? _reconnectDelay;
  final EmbyKeepAliveInterval _keepAliveInterval;
  final EmbySocketConnectedCallback? _onConnected;
  final Duration connectionTimeout;
  final Random _random;
  final StreamController<EmbyEvent> _events =
      StreamController<EmbyEvent>.broadcast();

  EmbySocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;
  Timer? _stableConnectionTimer;
  bool _started = false;
  bool _foreground = true;
  bool _backgroundConnectionRequired = false;
  bool _connecting = false;
  bool _disposed = false;
  int _generation = 0;
  int _reconnectAttempt = 0;

  Stream<EmbyEvent> get events => _events.stream;
  bool get isConnected => _socket != null;

  Future<void> start() async {
    if (_disposed) return;
    _started = true;
    if ((!_foreground && !_backgroundConnectionRequired) ||
        _socket != null ||
        _connecting) {
      return;
    }
    await _connect(++_generation);
  }

  Future<void> setForeground(bool foreground) async {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground && _backgroundConnectionRequired) return;
    if (foreground && _socket != null) return;
    final generation = ++_generation;
    if (!foreground) {
      await _releaseSocket();
      return;
    }
    if (_started) await _connect(generation);
  }

  Future<void> setBackgroundConnectionRequired(bool required) async {
    if (_disposed || _backgroundConnectionRequired == required) return;
    _backgroundConnectionRequired = required;
    if (_foreground) return;
    final generation = ++_generation;
    if (!required) {
      await _releaseSocket();
    } else if (_started) {
      await _connect(generation);
    }
  }

  Future<void> stop() async {
    _started = false;
    _reconnectAttempt = 0;
    _generation++;
    await _releaseSocket();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _events.close();
  }

  Future<void> _connect(int generation) async {
    if (!_canConnect(generation) || _connecting) return;
    _connecting = true;
    try {
      final socket = await _connector(_socketUri()).timeout(connectionTimeout);
      if (!_canConnect(generation)) {
        await socket.close();
        return;
      }
      await _releaseSocket(keepReconnectTimer: true);
      _socket = socket;
      _subscription = socket.messages.listen(
        (raw) => _handleRawMessage(raw, generation),
        onError: (Object error, StackTrace stackTrace) {
          DiagnosticLog.instance.error(
            'realtime',
            'Emby WebSocket stream error',
            error: error,
          );
          _handleDisconnected(generation);
        },
        onDone: () => _handleDisconnected(generation),
        cancelOnError: true,
      );
      _stableConnectionTimer?.cancel();
      _stableConnectionTimer = Timer(const Duration(seconds: 15), () {
        if (_canConnect(generation) && _socket == socket) {
          _reconnectAttempt = 0;
        }
      });
      DiagnosticLog.instance.info('realtime', 'Emby WebSocket connected');
      final onConnected = _onConnected;
      if (onConnected != null) {
        unawaited(
          Future<void>.sync(onConnected).catchError((Object error) {
            DiagnosticLog.instance.error(
              'realtime',
              'Failed to handle WebSocket connection',
              error: error,
            );
          }),
        );
      }
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'realtime',
        'Emby WebSocket connection failed',
        error: error,
        stackTrace: stackTrace,
      );
      _scheduleReconnect(generation);
    } finally {
      _connecting = false;
    }
  }

  void _handleRawMessage(dynamic raw, int generation) {
    if (!_canConnect(generation)) return;
    final decoded = _decodeMap(raw);
    if (decoded == null) {
      DiagnosticLog.instance.warning(
        'realtime',
        'Ignored malformed Emby WebSocket message',
      );
      return;
    }
    _reconnectAttempt = 0;
    if (decoded['MessageType']?.toString().toLowerCase() == 'forcekeepalive') {
      _startKeepAlive(_intValue(decoded['Data']) ?? 60);
      return;
    }
    final event = EmbyEvent.fromJson(decoded);
    if (event != null && !_events.isClosed) _events.add(event);
  }

  void _startKeepAlive(int serverIntervalSeconds) {
    _keepAliveTimer?.cancel();
    final period = _keepAliveInterval(serverIntervalSeconds);
    if (period <= Duration.zero) return;
    _keepAliveTimer = Timer.periodic(period, (_) {
      final socket = _socket;
      if (socket == null) return;
      try {
        socket.add('{"MessageType":"KeepAlive"}');
      } catch (error) {
        DiagnosticLog.instance.error(
          'realtime',
          'Failed to send WebSocket KeepAlive',
          error: error,
        );
        _handleDisconnected(_generation);
      }
    });
  }

  void _handleDisconnected(int generation) {
    if (generation != _generation) return;
    unawaited(_releaseSocket(keepReconnectTimer: true));
    _scheduleReconnect(generation);
  }

  void _scheduleReconnect(int generation) {
    if (!_canConnect(generation) || _reconnectTimer?.isActive == true) return;
    final attempt = _reconnectAttempt++;
    final delay =
        _reconnectDelay?.call(attempt) ?? _defaultReconnectDelay(attempt);
    DiagnosticLog.instance.info(
      'realtime',
      'Scheduling WebSocket reconnect attempt=${attempt + 1} '
          'delayMs=${delay.inMilliseconds}',
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connect(generation));
    });
  }

  Future<void> _releaseSocket({bool keepReconnectTimer = false}) async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _stableConnectionTimer?.cancel();
    _stableConnectionTimer = null;
    if (!keepReconnectTimer) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    await subscription?.cancel();
    await socket?.close();
  }

  bool _canConnect(int generation) =>
      !_disposed &&
      _started &&
      (_foreground || _backgroundConnectionRequired) &&
      generation == _generation;

  Duration _defaultReconnectDelay(int attempt) {
    final cappedAttempt = min(attempt, 5);
    final baseMilliseconds = min(30000, 1000 * (1 << cappedAttempt));
    final jitter = _random.nextInt(baseMilliseconds ~/ 2 + 1);
    return Duration(milliseconds: baseMilliseconds + jitter);
  }

  Uri _socketUri() {
    final base = Uri.parse(session.serverUrl);
    final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '$basePath/embywebsocket',
      queryParameters: {
        'api_key': session.accessToken,
        'deviceId': session.deviceId,
      },
      fragment: null,
    );
  }

  static Duration _defaultKeepAliveInterval(int serverIntervalSeconds) =>
      Duration(seconds: max(1, serverIntervalSeconds ~/ 2));

  static Future<EmbySocket> _connectIoSocket(Uri uri) async =>
      _IoEmbySocket(await WebSocket.connect(uri.toString()));
}

class _IoEmbySocket implements EmbySocket {
  const _IoEmbySocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void add(String data) => _socket.add(data);

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

Map<String, dynamic>? _decodeMap(dynamic raw) {
  try {
    final text = raw is List<int> ? utf8.decode(raw) : raw.toString();
    final value = jsonDecode(text);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  } catch (_) {
    return null;
  }
}

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
