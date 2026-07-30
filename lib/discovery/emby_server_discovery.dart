import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/diagnostic_log.dart';
import '../models/discovered_server.dart';

class EmbyDiscoveryPacket {
  const EmbyDiscoveryPacket({required this.data, required this.address});

  final List<int> data;
  final InternetAddress address;
}

abstract interface class EmbyDiscoveryTransport {
  Stream<EmbyDiscoveryPacket> get packets;
  void send(List<int> data, InternetAddress address, int port);
  Future<void> close();
}

typedef EmbyDiscoveryTransportFactory =
    Future<EmbyDiscoveryTransport> Function();
typedef EmbyBroadcastAddressProvider = Future<List<InternetAddress>> Function();

class EmbyServerDiscovery {
  EmbyServerDiscovery({
    EmbyDiscoveryTransportFactory? transportFactory,
    EmbyBroadcastAddressProvider? broadcastAddressProvider,
    this.listenDuration = const Duration(milliseconds: 2500),
    this.rebroadcastInterval = const Duration(milliseconds: 800),
  }) : _transportFactory = transportFactory ?? _IoDiscoveryTransport.bind,
       _broadcastAddressProvider =
           broadcastAddressProvider ?? _defaultBroadcastAddresses;

  static const discoveryPort = 7359;
  static const discoveryMessage = 'who is EmbyServer?';

  final EmbyDiscoveryTransportFactory _transportFactory;
  final EmbyBroadcastAddressProvider _broadcastAddressProvider;
  final Duration listenDuration;
  final Duration rebroadcastInterval;

  Future<List<DiscoveredServer>> discover() async {
    EmbyDiscoveryTransport? transport;
    StreamSubscription<EmbyDiscoveryPacket>? subscription;
    Timer? rebroadcastTimer;
    final found = <DiscoveredServer>[];
    final seenIds = <String>{};
    final seenAddresses = <String>{};
    try {
      transport = await _transportFactory();
      final addresses = await _broadcastAddressProvider();
      final payload = utf8.encode(discoveryMessage);

      subscription = transport.packets.listen((packet) {
        final server = parseResponse(
          packet.data,
          sourceAddress: packet.address,
        );
        if (server == null) return;
        final id = server.id.toLowerCase();
        final address = server.address.toLowerCase();
        if (seenIds.contains(id) || seenAddresses.contains(address)) return;
        seenIds.add(id);
        seenAddresses.add(address);
        found.add(server);
      });

      void broadcast() {
        for (final address in addresses) {
          try {
            transport?.send(payload, address, discoveryPort);
          } catch (_) {
            // A failed interface broadcast must not stop other interfaces.
          }
        }
      }

      broadcast();
      if (rebroadcastInterval > Duration.zero) {
        rebroadcastTimer = Timer.periodic(
          rebroadcastInterval,
          (_) => broadcast(),
        );
      }
      await Future<void>.delayed(listenDuration);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'discovery',
        'Local Emby server discovery failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      rebroadcastTimer?.cancel();
      await subscription?.cancel();
      await transport?.close();
    }

    final results = found
      ..sort((left, right) => left.name.compareTo(right.name));
    DiagnosticLog.instance.info(
      'discovery',
      'Local discovery found ${results.length} Emby server(s)',
    );
    return results;
  }

  static DiscoveredServer? parseResponse(
    List<int> response, {
    InternetAddress? sourceAddress,
  }) {
    try {
      final decoded = jsonDecode(utf8.decode(response));
      if (decoded is! Map) return null;
      return DiscoveredServer.fromJson(
        Map<String, dynamic>.from(decoded),
        sourceAddress: sourceAddress,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<List<InternetAddress>> _defaultBroadcastAddresses() async {
    final addresses = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
    };
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final octets = address.address.split('.');
          if (octets.length != 4) continue;
          final broadcast = '${octets[0]}.${octets[1]}.${octets[2]}.255';
          addresses.putIfAbsent(broadcast, () => InternetAddress(broadcast));
        }
      }
    } catch (_) {
      // The global broadcast address remains available as a fallback.
    }
    return addresses.values.toList(growable: false);
  }
}

class _IoDiscoveryTransport implements EmbyDiscoveryTransport {
  _IoDiscoveryTransport(this._socket) {
    _subscription = _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = _socket.receive()) != null) {
        _packets.add(
          EmbyDiscoveryPacket(data: datagram!.data, address: datagram.address),
        );
      }
    });
  }

  final RawDatagramSocket _socket;
  final StreamController<EmbyDiscoveryPacket> _packets =
      StreamController<EmbyDiscoveryPacket>.broadcast();
  late final StreamSubscription<RawSocketEvent> _subscription;
  bool _closed = false;

  static Future<EmbyDiscoveryTransport> bind() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    return _IoDiscoveryTransport(socket);
  }

  @override
  Stream<EmbyDiscoveryPacket> get packets => _packets.stream;

  @override
  void send(List<int> data, InternetAddress address, int port) {
    if (!_closed) _socket.send(data, address, port);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _socket.close();
    await _packets.close();
  }
}
