import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/playback/source_socket_connector.dart';
import 'package:flutter_test/flutter_test.dart';

final _ipv6 = InternetAddress('2001:db8::1');
final _ipv4 = InternetAddress('192.0.2.1');
const _delay = Duration(milliseconds: 10);

void main() {
  for (final addresses in [
    [_ipv6, _ipv4],
    [_ipv4, _ipv6],
  ]) {
    test(
      'stalled ${addresses.first.type.name} falls back to other family',
      () async {
        final attempts = <InternetAddress>[];
        final stalled = _Attempt();
        final winner = _Socket();
        final task = connectSourceAddresses(
          addresses,
          8000,
          attemptDelay: _delay,
          onAttempt: attempts.add,
          startConnect: (address, port) async {
            expect(port, 8000);
            return address == addresses.first
                ? stalled.task
                : _Attempt.connected(winner).task;
          },
        );
        expect(
          await task.socket.timeout(const Duration(seconds: 2)),
          same(winner),
        );
        expect(attempts, addresses);
        expect(stalled.cancelCount, 1);
        expect(winner.destroyCount, 0);
      },
    );
  }

  test(
    'immediate failure advances without waiting for the stagger timer',
    () async {
      final winner = _Socket();
      final task = connectSourceAddresses(
        [_ipv6, _ipv4],
        8000,
        attemptDelay: const Duration(minutes: 1),
        startConnect: (address, _) async => address == _ipv6
            ? _Attempt.failed(const SocketException('refused')).task
            : _Attempt.connected(winner).task,
      );
      expect(
        await task.socket.timeout(const Duration(seconds: 2)),
        same(winner),
      );
    },
  );

  test('task creation failure also advances to the next address', () async {
    final winner = _Socket();
    final task = connectSourceAddresses(
      [_ipv6, _ipv4],
      8000,
      startConnect: (address, _) {
        if (address == _ipv6) throw const SocketException('unreachable');
        return Future.value(_Attempt.connected(winner).task);
      },
    );
    expect(await task.socket, same(winner));
  });

  test(
    'interleaves families and tries all addresses before reporting failure',
    () async {
      final v6b = InternetAddress('2001:db8::2');
      final v4b = InternetAddress('192.0.2.2');
      final attempts = <InternetAddress>[];
      final task = connectSourceAddresses(
        [_ipv6, v6b, _ipv4, v4b],
        8000,
        onAttempt: attempts.add,
        startConnect: (address, _) async =>
            _Attempt.failed(SocketException(address.address)).task,
      );
      await expectLater(
        task.socket,
        throwsA(
          isA<SocketException>().having(
            (error) => error.message,
            'last failure',
            v4b.address,
          ),
        ),
      );
      expect(attempts, [_ipv6, _ipv4, v6b, v4b]);
    },
  );

  test('single-family answers fall back within that family', () async {
    final next = InternetAddress('192.0.2.2');
    final winner = _Socket();
    final task = connectSourceAddresses(
      [_ipv4, next],
      8000,
      startConnect: (address, _) async => address == _ipv4
          ? _Attempt.failed(const SocketException('refused')).task
          : _Attempt.connected(winner).task,
    );
    expect(await task.socket, same(winner));
  });

  test(
    'fast success cancels scheduled attempts without cancelling the winner',
    () async {
      final attempts = <InternetAddress>[];
      final winner = _Attempt.connected(_Socket());
      final task = connectSourceAddresses(
        [_ipv6, _ipv4],
        8000,
        attemptDelay: _delay,
        onAttempt: attempts.add,
        startConnect: (_, _) async => winner.task,
      );
      await task.socket;
      task.cancel();
      await Future<void>.delayed(_delay * 3);
      expect(attempts, [_ipv6]);
      expect(winner.cancelCount, 0);
    },
  );

  test(
    'a failed second candidate does not discard a pending first candidate',
    () async {
      final first = _Attempt();
      final secondStarted = Completer<void>();
      final winner = _Socket();
      final task = connectSourceAddresses(
        [_ipv6, _ipv4],
        8000,
        attemptDelay: _delay,
        startConnect: (address, _) async {
          if (address == _ipv6) return first.task;
          secondStarted.complete();
          return _Attempt.failed(const SocketException('refused')).task;
        },
      );
      await secondStarted.future;
      await Future<void>.delayed(Duration.zero);
      first.result.complete(winner);
      expect(await task.socket, same(winner));
    },
  );

  test(
    'late loser socket is destroyed even if cancellation raced with success',
    () async {
      final loser = _Attempt(ignoreCancel: true);
      final winner = _Socket();
      final task = connectSourceAddresses(
        [_ipv6, _ipv4],
        8000,
        attemptDelay: _delay,
        startConnect: (address, _) async =>
            address == _ipv6 ? loser.task : _Attempt.connected(winner).task,
      );
      expect(await task.socket, same(winner));
      final lateSocket = _Socket();
      loser.result.complete(lateSocket);
      await Future<void>.delayed(Duration.zero);
      expect(loser.cancelCount, 1);
      expect(lateSocket.destroyCount, 1);
      expect(winner.destroyCount, 0);
    },
  );

  test(
    'cancel stops active and scheduled attempts and is idempotent',
    () async {
      final attempts = <InternetAddress>[];
      final first = _Attempt();
      final task = connectSourceAddresses(
        [_ipv6, _ipv4],
        8000,
        attemptDelay: _delay,
        onAttempt: attempts.add,
        startConnect: (_, _) async => first.task,
      );
      final failure = expectLater(task.socket, throwsA(isA<SocketException>()));
      await Future<void>.delayed(Duration.zero);
      task.cancel();
      task.cancel();
      await failure;
      await Future<void>.delayed(_delay * 3);
      expect(first.cancelCount, 1);
      expect(attempts, [_ipv6]);
    },
  );

  test('cancel observes tasks whose creation has not finished yet', () async {
    final creating = Completer<ConnectionTask<Socket>>();
    final task = connectSourceAddresses(
      [_ipv6],
      8000,
      startConnect: (_, _) => creating.future,
    );
    final failure = expectLater(task.socket, throwsA(isA<SocketException>()));
    task.cancel();
    await failure;
    final late = _Attempt();
    creating.complete(late.task);
    await Future<void>.delayed(Duration.zero);
    expect(late.cancelCount, 1);
  });

  test('HttpClient overall timeout cancels every active candidate', () async {
    final attempts = <_Attempt>[];
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 80)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, _, _) async => connectSourceAddresses(
        [_ipv6, _ipv4],
        uri.port,
        attemptDelay: _delay,
        startConnect: (_, _) async {
          final attempt = _Attempt();
          attempts.add(attempt);
          return attempt.task;
        },
      );
    addTearDown(() => client.close(force: true));
    await expectLater(
      client.getUrl(Uri.parse('http://media.invalid:8000/video.mp4')),
      throwsA(isA<SocketException>()),
    );
    expect(attempts, hasLength(2));
    expect(attempts.map((attempt) => attempt.cancelCount), everyElement(1));
  });
}

class _Attempt {
  _Attempt({this.ignoreCancel = false});

  _Attempt.connected(Socket socket) : ignoreCancel = false {
    result.complete(socket);
  }

  _Attempt.failed(Object error) : ignoreCancel = false {
    Timer.run(() {
      if (!result.isCompleted) result.completeError(error);
    });
  }

  final bool ignoreCancel;
  final result = Completer<Socket>();
  int cancelCount = 0;
  late final task = ConnectionTask.fromSocket(result.future, () {
    cancelCount++;
    if (!ignoreCancel && !result.isCompleted) {
      result.completeError(const SocketException('cancelled'));
    }
  });
}

class _Socket implements Socket {
  int destroyCount = 0;

  @override
  void destroy() => destroyCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
