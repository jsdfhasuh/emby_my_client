import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/models/discovered_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes discovered addresses and replaces loopback hosts', () {
    final server = DiscoveredServer.fromJson({
      'Id': 'server-1',
      'Name': 'Living Room',
      'Address': 'HTTP://127.0.0.1:8096/',
    }, sourceAddress: InternetAddress('192.168.1.20'));

    expect(server?.name, 'Living Room');
    expect(server?.address, 'http://192.168.1.20:8096');
    expect(
      DiscoveredServer.normalizeAddress('http://192.168.1.20:80/'),
      'http://192.168.1.20',
    );
    expect(DiscoveredServer.normalizeAddress('ftp://192.168.1.20'), isNull);
  });

  test('parses discovery responses and rejects malformed packets', () {
    final server = EmbyServerDiscovery.parseResponse(
      utf8.encode(
        jsonEncode({
          'Id': 'server-1',
          'Name': 'Emby Home',
          'Address': '192.168.1.20:8096',
        }),
      ),
    );

    expect(server?.id, 'server-1');
    expect(server?.address, 'http://192.168.1.20:8096');
    expect(EmbyServerDiscovery.parseResponse(utf8.encode('invalid')), isNull);
  });

  test('broadcasts on port 7359 and deduplicates server responses', () async {
    final transport = _FakeTransport();
    final discovery = EmbyServerDiscovery(
      transportFactory: () async => transport,
      broadcastAddressProvider: () async => [
        InternetAddress('255.255.255.255'),
      ],
      listenDuration: const Duration(milliseconds: 40),
      rebroadcastInterval: const Duration(milliseconds: 10),
    );

    final future = discovery.discover();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    transport.emit({
      'Id': 'server-1',
      'Name': 'Emby Home',
      'Address': 'http://192.168.1.20:8096/',
    });
    transport.emit({
      'Id': 'SERVER-1',
      'Name': 'Duplicate',
      'Address': 'http://192.168.1.20:8096',
    });
    transport.emit({
      'Id': 'server-2',
      'Name': 'Same endpoint',
      'Address': 'HTTP://192.168.1.20:8096/',
    });
    final result = await future;

    expect(result.status, EmbyDiscoveryStatus.found);
    expect(result.servers, hasLength(1));
    expect(result.servers.single.name, 'Emby Home');
    expect(transport.sent, isNotEmpty);
    expect(utf8.decode(transport.sent.first.data), 'who is EmbyServer?');
    expect(transport.sent.first.port, 7359);
    expect(transport.closed, isTrue);
  });

  test('successful broadcast with no valid response is notFound', () async {
    final transport = _FakeTransport();
    final result = await EmbyServerDiscovery(
      transportFactory: () async => transport,
      broadcastAddressProvider: () async => [
        InternetAddress('255.255.255.255'),
      ],
      listenDuration: const Duration(milliseconds: 5),
      rebroadcastInterval: Duration.zero,
    ).discover();

    expect(result.status, EmbyDiscoveryStatus.notFound);
    expect(result.failureKind, isNull);
    expect(transport.closeCount, 1);
  });

  test('transport failure is unavailable with transport reason', () async {
    final result = await EmbyServerDiscovery(
      transportFactory: () async => throw StateError('bind failed'),
      listenDuration: const Duration(milliseconds: 5),
    ).discover();

    expect(result.status, EmbyDiscoveryStatus.unavailable);
    expect(result.failureKind, EmbyDiscoveryFailureKind.transport);
  });

  test('one failed broadcast does not hide a successful target', () async {
    final transport = _FakeTransport()..failingAddresses.add('192.168.1.1');
    final result = await EmbyServerDiscovery(
      transportFactory: () async => transport,
      broadcastAddressProvider: () async => [
        InternetAddress('192.168.1.1'),
        InternetAddress('192.168.1.255'),
      ],
      listenDuration: const Duration(milliseconds: 5),
      rebroadcastInterval: Duration.zero,
    ).discover();

    expect(result.status, EmbyDiscoveryStatus.notFound);
    expect(result.failureKind, isNull);
    expect(transport.sendAttempts, 2);
    expect(transport.sent, hasLength(1));
  });

  test('all failed broadcasts are unavailable with broadcast reason', () async {
    final transport = _FakeTransport()
      ..failingAddresses.addAll(['192.168.1.1', '192.168.1.255']);
    final result = await EmbyServerDiscovery(
      transportFactory: () async => transport,
      broadcastAddressProvider: () async => [
        InternetAddress('192.168.1.1'),
        InternetAddress('192.168.1.255'),
      ],
      listenDuration: const Duration(milliseconds: 5),
      rebroadcastInterval: Duration.zero,
    ).discover();

    expect(result.status, EmbyDiscoveryStatus.unavailable);
    expect(result.failureKind, EmbyDiscoveryFailureKind.broadcast);
    expect(transport.closeCount, 1);
  });

  test(
    'receive failure without a server is unavailable with receive reason',
    () async {
      final transport = _FakeTransport();
      final future = EmbyServerDiscovery(
        transportFactory: () async => transport,
        broadcastAddressProvider: () async => [
          InternetAddress('255.255.255.255'),
        ],
        listenDuration: const Duration(seconds: 1),
        rebroadcastInterval: Duration.zero,
      ).discover();
      await Future<void>.delayed(Duration.zero);
      transport.emitError(StateError('receive failed'));

      final result = await future;
      expect(result.status, EmbyDiscoveryStatus.unavailable);
      expect(result.failureKind, EmbyDiscoveryFailureKind.receive);
    },
  );

  test('a server found before receive failure remains found', () async {
    final transport = _FakeTransport();
    final future = EmbyServerDiscovery(
      transportFactory: () async => transport,
      broadcastAddressProvider: () async => [
        InternetAddress('255.255.255.255'),
      ],
      listenDuration: const Duration(seconds: 1),
      rebroadcastInterval: Duration.zero,
    ).discover();
    await Future<void>.delayed(Duration.zero);
    transport.emit({
      'Id': 'server-1',
      'Name': 'Zeta',
      'Address': 'http://192.168.1.20:8096',
    });
    transport.emit({
      'Id': 'server-2',
      'Name': 'alpha',
      'Address': 'http://192.168.1.21:8096',
    });
    transport.emitError(StateError('late receive failure'));

    final result = await future;
    expect(result.status, EmbyDiscoveryStatus.found);
    expect(result.failureKind, isNull);
    expect(result.servers.map((server) => server.name), ['alpha', 'Zeta']);
  });

  test('cancellation is idempotent', () {
    final cancellation = EmbyDiscoveryCancellation();

    cancellation.cancel();
    cancellation.cancel();

    expect(cancellation.isCancelled, isTrue);
  });

  test('cancellation before bind completes prevents sending', () async {
    final bind = Completer<EmbyDiscoveryTransport>();
    final transport = _FakeTransport();
    final cancellation = EmbyDiscoveryCancellation();
    final future = EmbyServerDiscovery(
      transportFactory: () => bind.future,
      broadcastAddressProvider: () async => [
        InternetAddress('255.255.255.255'),
      ],
      listenDuration: const Duration(seconds: 1),
    ).discover(cancellation: cancellation);

    cancellation.cancel();
    bind.complete(transport);

    final result = await future;
    expect(result.status, EmbyDiscoveryStatus.cancelled);
    expect(transport.sendAttempts, 0);
    expect(transport.closeCount, 1);
  });

  test(
    'cancellation after bind promptly closes transport and stops timer',
    () async {
      final transport = _FakeTransport();
      final cancellation = EmbyDiscoveryCancellation();
      final future = EmbyServerDiscovery(
        transportFactory: () async => transport,
        broadcastAddressProvider: () async => [
          InternetAddress('255.255.255.255'),
        ],
        listenDuration: const Duration(seconds: 1),
        rebroadcastInterval: const Duration(milliseconds: 1),
      ).discover(cancellation: cancellation);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancellation.cancel();

      final result = await future;
      final sendsAfterCancellation = transport.sendAttempts;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(result.status, EmbyDiscoveryStatus.cancelled);
      expect(transport.sendAttempts, sendsAfterCancellation);
      expect(transport.closeCount, 1);
    },
  );

  test('cancellation ignores late packets and returns empty servers', () async {
    final transport = _FakeTransport();
    final cancellation = EmbyDiscoveryCancellation();
    final future = EmbyServerDiscovery(
      transportFactory: () async => transport,
      broadcastAddressProvider: () async => [
        InternetAddress('255.255.255.255'),
      ],
      listenDuration: const Duration(seconds: 1),
      rebroadcastInterval: Duration.zero,
    ).discover(cancellation: cancellation);
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    transport.emit({
      'Id': 'late-server',
      'Name': 'Late Server',
      'Address': 'http://192.168.1.20:8096',
    });

    final result = await future;
    expect(result.status, EmbyDiscoveryStatus.cancelled);
    expect(result.servers, isEmpty);
    expect(transport.closeCount, 1);
  });
}

class _SentPacket {
  const _SentPacket(this.data, this.address, this.port);

  final List<int> data;
  final InternetAddress address;
  final int port;
}

class _FakeTransport implements EmbyDiscoveryTransport {
  final StreamController<EmbyDiscoveryPacket> _packets =
      StreamController<EmbyDiscoveryPacket>.broadcast();
  final List<_SentPacket> sent = [];
  final Set<String> failingAddresses = <String>{};
  int sendAttempts = 0;
  int closeCount = 0;
  bool closed = false;

  @override
  Stream<EmbyDiscoveryPacket> get packets => _packets.stream;

  void emit(Map<String, dynamic> response) {
    _packets.add(
      EmbyDiscoveryPacket(
        data: utf8.encode(jsonEncode(response)),
        address: InternetAddress('192.168.1.20'),
      ),
    );
  }

  void emitError(Object error) {
    _packets.addError(error);
  }

  @override
  void send(List<int> data, InternetAddress address, int port) {
    sendAttempts++;
    if (failingAddresses.contains(address.address)) {
      throw StateError('send failed');
    }
    sent.add(_SentPacket(data, address, port));
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (closed) return;
    closed = true;
    await _packets.close();
  }
}
