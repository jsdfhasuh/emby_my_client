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
    final results = await future;

    expect(results, hasLength(1));
    expect(results.single.name, 'Emby Home');
    expect(transport.sent, isNotEmpty);
    expect(utf8.decode(transport.sent.first.data), 'who is EmbyServer?');
    expect(transport.sent.first.port, 7359);
    expect(transport.closed, isTrue);
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

  @override
  void send(List<int> data, InternetAddress address, int port) {
    sent.add(_SentPacket(data, address, port));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _packets.close();
  }
}
