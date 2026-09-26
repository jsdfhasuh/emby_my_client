import 'dart:async';
import 'dart:convert';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/realtime/emby_event.dart';
import 'package:emby_my_client/realtime/emby_websocket_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Emby event parsing', () {
    test('parses library and user data changes', () {
      final library =
          EmbyEvent.parse(
                jsonEncode({
                  'MessageType': 'LibraryChanged',
                  'Data': {
                    'ItemsAdded': ['added'],
                    'ItemsUpdated': ['updated'],
                    'ItemsRemoved': ['removed'],
                  },
                }),
              )
              as EmbyLibraryChanged;
      final userData =
          EmbyEvent.parse(
                jsonEncode({
                  'MessageType': 'UserDataChanged',
                  'Data': {
                    'UserId': 'user-1',
                    'UserDataList': [
                      {'ItemId': 'item-1'},
                      {'ItemId': 'item-2'},
                    ],
                  },
                }),
              )
              as EmbyUserDataChanged;

      expect(library.affectedItemIds, {'added', 'updated', 'removed'});
      expect(userData.userId, 'user-1');
      expect(userData.itemIds, ['item-1', 'item-2']);
    });

    test('parses a targeted Playstate seek command', () {
      final event =
          EmbyEvent.parse(
                jsonEncode({
                  'MessageType': 'Playstate',
                  'Data': {
                    'Command': 'Seek',
                    'SeekPositionTicks': '123000000',
                    'ItemId': 'item-1',
                    'PlaySessionId': 'play-session-1',
                  },
                }),
              )
              as EmbyPlaystateCommand;

      expect(event.command, 'Seek');
      expect(event.seekPositionTicks, 123000000);
      expect(event.itemId, 'item-1');
      expect(event.playSessionId, 'play-session-1');
    });

    test('ignores malformed and unsupported messages', () {
      expect(EmbyEvent.parse('not-json'), isNull);
      expect(
        EmbyEvent.parse('{"MessageType":"Unsupported","Data":{}}'),
        isNull,
      );
    });
  });

  group('Emby WebSocket lifecycle', () {
    test(
      'server B ignores late A callbacks for an identical item ID',
      () async {
        final socketA = _ManualCallbackSocket();
        final socketB = _ManualCallbackSocket();
        final clientA = EmbyWebSocketClient(
          _session,
          connector: (_) async => socketA,
        );
        final clientB = EmbyWebSocketClient(
          const EmbySession(
            serverUrl: 'https://b.example.test',
            serverName: 'B',
            serverId: 'server-b',
            userId: 'user-1',
            username: 'tester',
            accessToken: 'fixture-b',
            deviceId: 'device-1',
          ),
          connector: (_) async => socketB,
        );
        addTearDown(socketA.disposeStream);
        addTearDown(socketB.disposeStream);
        addTearDown(clientB.dispose);
        final receivedA = <EmbyEvent>[];
        final receivedB = <EmbyEvent>[];
        clientA.events.listen(receivedA.add);
        clientB.events.listen(receivedB.add);
        await clientA.start();
        await clientA.dispose();
        await clientB.start();
        final message = jsonEncode({
          'MessageType': 'UserDataChanged',
          'Data': {
            'UserId': 'user-1',
            'UserDataList': [
              {'ItemId': 'same-item'},
            ],
          },
        });
        socketA.emit(message);
        socketA.emitDone();
        socketB.emit(message);
        await Future<void>.delayed(Duration.zero);
        expect(receivedA, isEmpty);
        expect(receivedB, hasLength(1));
        expect((receivedB.single as EmbyUserDataChanged).itemIds, [
          'same-item',
        ]);
        expect(clientB.isConnected, isTrue);
        expect(socketB.closed, isFalse);
      },
    );

    test('connects with the Emby endpoint and honors ForceKeepAlive', () async {
      final socket = _FakeSocket();
      Uri? connectedUri;
      final client = EmbyWebSocketClient(
        _session,
        connector: (uri) async {
          connectedUri = uri;
          return socket;
        },
        keepAliveInterval: (_) => const Duration(milliseconds: 10),
      );

      await client.start();
      socket.emit(jsonEncode({'MessageType': 'ForceKeepAlive', 'Data': 60}));
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(connectedUri?.scheme, 'wss');
      expect(connectedUri?.path, '/emby/embywebsocket');
      expect(connectedUri?.queryParameters['api_key'], _session.accessToken);
      expect(connectedUri?.queryParameters['deviceId'], _session.deviceId);
      expect(socket.sent, contains('{"MessageType":"KeepAlive"}'));

      await client.dispose();
    });

    test('forwards typed events and suspends outside foreground', () async {
      final sockets = <_FakeSocket>[];
      final events = <EmbyEvent>[];
      final client = EmbyWebSocketClient(
        _session,
        connector: (_) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
      );
      final subscription = client.events.listen(events.add);

      await client.start();
      sockets.single.emit(
        jsonEncode({
          'MessageType': 'UserDataChanged',
          'Data': {
            'UserId': 'user-1',
            'UserDataList': [
              {'ItemId': 'item-1'},
            ],
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await client.setForeground(false);

      expect(events.single, isA<EmbyUserDataChanged>());
      expect(client.isConnected, isFalse);
      expect(sockets.single.closed, isTrue);

      await client.setForeground(true);
      expect(sockets, hasLength(2));
      expect(client.isConnected, isTrue);

      await subscription.cancel();
      await client.dispose();
    });

    test('keeps a connection while background playback requires it', () async {
      final socket = _FakeSocket();
      final events = <EmbyEvent>[];
      var connections = 0;
      final client = EmbyWebSocketClient(
        _session,
        connector: (_) async {
          connections++;
          return socket;
        },
      );
      final subscription = client.events.listen(events.add);

      await client.start();
      await client.setBackgroundConnectionRequired(true);
      await client.setForeground(false);
      socket.emit(
        jsonEncode({
          'MessageType': 'UserDataChanged',
          'Data': {
            'UserId': 'user-1',
            'UserDataList': [
              {'ItemId': 'item-1'},
            ],
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.isConnected, isTrue);
      expect(connections, 1);
      expect(socket.closed, isFalse);
      expect(events, hasLength(1));

      await client.setBackgroundConnectionRequired(false);
      expect(client.isConnected, isFalse);

      await subscription.cancel();
      await client.dispose();
    });

    test('reconnects after a bounded injected delay', () async {
      var attempts = 0;
      final socket = _FakeSocket();
      final client = EmbyWebSocketClient(
        _session,
        connector: (_) async {
          attempts++;
          if (attempts == 1) throw const SocketExceptionForTest();
          return socket;
        },
        reconnectDelay: (_) => Duration.zero,
      );

      await client.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(attempts, 2);
      expect(client.isConnected, isTrue);

      await client.dispose();
    });

    test('closes a socket that resolves after connection timeout', () async {
      final pendingSocket = Completer<EmbySocket>();
      final lateSocket = _FakeSocket();
      var attempts = 0;
      final client = EmbyWebSocketClient(
        _session,
        connector: (_) {
          attempts++;
          return pendingSocket.future;
        },
        connectionTimeout: const Duration(milliseconds: 5),
        reconnectDelay: (_) => const Duration(days: 1),
      );
      addTearDown(client.dispose);

      await client.start();
      pendingSocket.complete(lateSocket);
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 1);
      expect(client.isConnected, isFalse);
      expect(lateSocket.closed, isTrue);
    });

    test('ignores callbacks from a replaced socket', () async {
      final staleSocket = _ManualCallbackSocket();
      final replacementSocket = _FakeSocket();
      final replacementRequested = Completer<void>();
      final events = <EmbyEvent>[];
      var attempts = 0;
      final client = EmbyWebSocketClient(
        _session,
        connector: (_) async {
          attempts++;
          if (attempts == 1) return staleSocket;
          if (!replacementRequested.isCompleted) {
            replacementRequested.complete();
          }
          return replacementSocket;
        },
        reconnectDelay: (_) => Duration.zero,
      );
      final eventSubscription = client.events.listen(events.add);
      addTearDown(() async {
        await eventSubscription.cancel();
        await client.dispose();
        await staleSocket.disposeStream();
      });

      await client.start();
      staleSocket.emitDone();
      await replacementRequested.future;
      await Future<void>.delayed(Duration.zero);
      expect(client.isConnected, isTrue);

      staleSocket.emit(
        jsonEncode({
          'MessageType': 'UserDataChanged',
          'Data': {
            'UserId': 'stale-user',
            'UserDataList': [
              {'ItemId': 'stale-item'},
            ],
          },
        }),
      );
      staleSocket.emitDone();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, isEmpty);
      expect(attempts, 2);
      expect(client.isConnected, isTrue);
      expect(replacementSocket.closed, isFalse);
    });

    test('runs the connected callback again after reconnecting', () async {
      final sockets = <_FakeSocket>[];
      var connectedCallbacks = 0;
      final client = EmbyWebSocketClient(
        _session,
        connector: (_) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
        reconnectDelay: (_) => Duration.zero,
        onConnected: () => connectedCallbacks++,
      );

      await client.start();
      await sockets.single.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sockets, hasLength(2));
      expect(connectedCallbacks, 2);

      await client.dispose();
    });
  });
}

class _FakeSocket implements EmbySocket {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<dynamic> get messages => _controller.stream;

  void emit(String data) => _controller.add(data);

  Future<void> disconnect() => close();

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _controller.close();
  }
}

class _ManualCallbackSocket implements EmbySocket {
  final _ManualCallbackStream _stream = _ManualCallbackStream();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<dynamic> get messages => _stream;

  void emit(String data) => _stream.emit(data);

  void emitDone() => _stream.emitDone();

  Future<void> disposeStream() => _stream.dispose();

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _ManualCallbackStream extends Stream<dynamic> {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast(sync: true);
  void Function()? _doneHandler;

  void emit(dynamic data) => _controller.add(data);

  void emitDone() => _doneHandler?.call();

  Future<void> dispose() => _controller.close();

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _doneHandler = onDone;
    return _NonCancellingSubscription<dynamic>(
      _controller.stream.listen(
        onData,
        onError: onError,
        cancelOnError: cancelOnError,
      ),
    );
  }
}

class _NonCancellingSubscription<T> implements StreamSubscription<T> {
  const _NonCancellingSubscription(this._delegate);

  final StreamSubscription<T> _delegate;

  @override
  Future<void> cancel() async {}

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture<E>(futureValue);

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();
}

class SocketExceptionForTest implements Exception {
  const SocketExceptionForTest();
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test/emby',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
