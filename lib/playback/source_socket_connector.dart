import 'dart:async';
import 'dart:io';

/// Races already-validated DNS addresses without resolving the host again.
/// The owning HttpClient supplies the overall connection deadline.
ConnectionTask<Socket> connectSourceAddresses(
  List<InternetAddress> addresses,
  int port, {
  Duration attemptDelay = const Duration(milliseconds: 250),
  void Function(InternetAddress)? onAttempt,
  Future<ConnectionTask<Socket>> Function(InternetAddress, int)? startConnect,
}) {
  if (addresses.isEmpty) {
    throw ArgumentError.value(addresses, 'addresses', 'Must not be empty');
  }
  if (attemptDelay <= Duration.zero) {
    throw ArgumentError.value(attemptDelay, 'attemptDelay', 'Must be positive');
  }
  final preferred = addresses
      .where((address) => address.type == addresses.first.type)
      .iterator;
  final alternate = addresses
      .where((address) => address.type != addresses.first.type)
      .iterator;
  final candidates = <InternetAddress>[];
  while (true) {
    final hasPreferred = preferred.moveNext();
    final hasAlternate = alternate.moveNext();
    if (!hasPreferred && !hasAlternate) break;
    if (hasPreferred) candidates.add(preferred.current);
    if (hasAlternate) candidates.add(alternate.current);
  }

  final result = Completer<Socket>();
  final active = <ConnectionTask<Socket>>{};
  final connect = startConnect ?? Socket.startConnect;
  Timer? timer;
  var next = 0;
  var pending = 0;
  var settled = false;

  void cancelPending() {
    timer?.cancel();
    timer = null;
    for (final task in active.toList()) {
      task.cancel();
    }
    active.clear();
  }

  void startNext() {
    if (settled || next == candidates.length) return;
    timer?.cancel();
    final address = candidates[next++];
    pending++;
    timer = next < candidates.length ? Timer(attemptDelay, startNext) : null;
    unawaited(() async {
      ConnectionTask<Socket>? task;
      try {
        onAttempt?.call(address);
        task = await connect(address, port);
        if (settled) {
          task.cancel();
        } else {
          active.add(task);
        }
        // Always observe late tasks, including cancellation failures and sockets
        // that completed just before another candidate won the race.
        final socket = await task.socket;
        active.remove(task);
        if (settled) {
          socket.destroy();
          return;
        }
        settled = true;
        cancelPending();
        result.complete(socket);
      } catch (error, stack) {
        active.remove(task);
        pending--;
        if (settled) return;
        if (next < candidates.length) {
          startNext();
        } else if (pending == 0) {
          settled = true;
          cancelPending();
          result.completeError(error, stack);
        }
      }
    }());
  }

  startNext();
  return ConnectionTask.fromSocket(result.future, () {
    if (settled) return;
    settled = true;
    cancelPending();
    result.completeError(const SocketException('Connection attempt cancelled'));
  });
}
