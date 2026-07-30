import 'dart:async';

import '../core/server_scope.dart';

typedef ClientDisposer<T> = FutureOr<void> Function(T client);

class ClientRegistry<T> {
  ClientRegistry({required ClientDisposer<T> disposeClient})
    : _disposeClient = disposeClient;

  final ClientDisposer<T> _disposeClient;
  final Map<ServerScope, T> _clients = {};
  bool _disposed = false;

  Iterable<ServerScope> get scopes => List.unmodifiable(_clients.keys);

  bool contains(ServerScope scope) => _clients.containsKey(scope);

  T? clientFor(ServerScope scope) => _clients[scope];

  T requireClient(ServerScope scope) {
    final client = _clients[scope];
    if (client == null) {
      throw StateError('No client registered for $scope');
    }
    return client;
  }

  void register(ServerScope scope, T client) {
    _ensureActive();
    if (_clients.containsKey(scope)) {
      throw StateError('A client is already registered for $scope');
    }
    _clients[scope] = client;
  }

  Future<void> replace(ServerScope scope, T client) async {
    _ensureActive();
    final previous = _clients.remove(scope);
    if (previous != null && !identical(previous, client)) {
      await Future<void>.sync(() => _disposeClient(previous));
    }
    _clients[scope] = client;
  }

  Future<void> unregister(ServerScope scope) async {
    final client = _clients.remove(scope);
    if (client != null) {
      await Future<void>.sync(() => _disposeClient(client));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final clients = _clients.values.toList(growable: false);
    _clients.clear();
    for (final client in clients) {
      await Future<void>.sync(() => _disposeClient(client));
    }
  }

  void _ensureActive() {
    if (_disposed) throw StateError('ClientRegistry has been disposed');
  }
}
