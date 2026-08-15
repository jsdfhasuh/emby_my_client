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

enum EmbyDiscoveryStatus { found, notFound, unavailable, cancelled }

enum EmbyDiscoveryFailureKind { transport, broadcast, receive, unknown }

class EmbyDiscoveryResult {
  const EmbyDiscoveryResult({
    required this.status,
    this.servers = const [],
    this.failureKind,
  });

  final EmbyDiscoveryStatus status;
  final List<DiscoveredServer> servers;
  final EmbyDiscoveryFailureKind? failureKind;
}

class EmbyDiscoveryCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }
}

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

  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async {
    final operationCancellation = cancellation ?? EmbyDiscoveryCancellation();
    EmbyDiscoveryTransport? transport;
    StreamSubscription<EmbyDiscoveryPacket>? subscription;
    Timer? rebroadcastTimer;
    final found = <DiscoveredServer>[];
    final seenIds = <String>{};
    final seenAddresses = <String>{};
    EmbyDiscoveryResult? result;
    var receiveFailed = false;
    var attemptedBroadcastCount = 0;
    var successfulBroadcastCount = 0;

    try {
      if (operationCancellation.isCancelled) {
        result = const EmbyDiscoveryResult(
          status: EmbyDiscoveryStatus.cancelled,
        );
      } else {
        try {
          transport = await _transportFactory();
        } catch (error, stackTrace) {
          DiagnosticLog.instance.error(
            'discovery',
            'Local Emby discovery transport could not start',
            error: error,
            stackTrace: stackTrace,
          );
          result = operationCancellation.isCancelled
              ? const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.cancelled)
              : const EmbyDiscoveryResult(
                  status: EmbyDiscoveryStatus.unavailable,
                  failureKind: EmbyDiscoveryFailureKind.transport,
                );
        }

        List<InternetAddress>? addresses;
        if (result == null && operationCancellation.isCancelled) {
          result = const EmbyDiscoveryResult(
            status: EmbyDiscoveryStatus.cancelled,
          );
        }
        if (result == null) {
          try {
            addresses = await _broadcastAddressProvider();
          } catch (error, stackTrace) {
            DiagnosticLog.instance.error(
              'discovery',
              'Local Emby discovery broadcast targets could not be listed',
              error: error,
              stackTrace: stackTrace,
            );
            result = operationCancellation.isCancelled
                ? const EmbyDiscoveryResult(
                    status: EmbyDiscoveryStatus.cancelled,
                  )
                : const EmbyDiscoveryResult(
                    status: EmbyDiscoveryStatus.unavailable,
                    failureKind: EmbyDiscoveryFailureKind.unknown,
                  );
          }
        }

        if (result == null && operationCancellation.isCancelled) {
          result = const EmbyDiscoveryResult(
            status: EmbyDiscoveryStatus.cancelled,
          );
        }

        if (result == null) {
          final payload = utf8.encode(discoveryMessage);
          subscription = transport!.packets.listen(
            (packet) {
              if (operationCancellation.isCancelled) return;
              final server = parseResponse(
                packet.data,
                sourceAddress: packet.address,
              );
              if (server == null) return;
              final id = server.id.toLowerCase();
              final address = server.address.toLowerCase();
              if (seenIds.contains(id) || seenAddresses.contains(address)) {
                return;
              }
              seenIds.add(id);
              seenAddresses.add(address);
              found.add(server);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (receiveFailed) return;
              receiveFailed = true;
              DiagnosticLog.instance.error(
                'discovery',
                'Local Emby discovery receive stream failed',
                error: error,
                stackTrace: stackTrace,
              );
            },
          );

          void broadcast() {
            if (operationCancellation.isCancelled) return;
            for (final address in addresses!) {
              if (operationCancellation.isCancelled) return;
              attemptedBroadcastCount++;
              try {
                transport!.send(payload, address, discoveryPort);
                successfulBroadcastCount++;
              } catch (error, stackTrace) {
                DiagnosticLog.instance.error(
                  'discovery',
                  'Local Emby discovery broadcast target failed',
                  error: error,
                  stackTrace: stackTrace,
                );
              }
            }
          }

          broadcast();
          if (operationCancellation.isCancelled) {
            result = const EmbyDiscoveryResult(
              status: EmbyDiscoveryStatus.cancelled,
            );
          } else if (successfulBroadcastCount == 0) {
            result = const EmbyDiscoveryResult(
              status: EmbyDiscoveryStatus.unavailable,
              failureKind: EmbyDiscoveryFailureKind.broadcast,
            );
          } else {
            if (rebroadcastInterval > Duration.zero) {
              rebroadcastTimer = Timer.periodic(
                rebroadcastInterval,
                (_) => broadcast(),
              );
            }
            await Future.any<void>([
              Future<void>.delayed(listenDuration),
              operationCancellation.whenCancelled,
            ]);

            if (operationCancellation.isCancelled) {
              result = const EmbyDiscoveryResult(
                status: EmbyDiscoveryStatus.cancelled,
              );
            } else if (receiveFailed && found.isEmpty) {
              result = const EmbyDiscoveryResult(
                status: EmbyDiscoveryStatus.unavailable,
                failureKind: EmbyDiscoveryFailureKind.receive,
              );
            } else {
              final results = _sortedServers(found);
              result = EmbyDiscoveryResult(
                status: results.isEmpty
                    ? EmbyDiscoveryStatus.notFound
                    : EmbyDiscoveryStatus.found,
                servers: results,
              );
            }
          }
        }
      }
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'discovery',
        'Local Emby server discovery failed',
        error: error,
        stackTrace: stackTrace,
      );
      result = operationCancellation.isCancelled
          ? const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.cancelled)
          : found.isEmpty
          ? const EmbyDiscoveryResult(
              status: EmbyDiscoveryStatus.unavailable,
              failureKind: EmbyDiscoveryFailureKind.unknown,
            )
          : EmbyDiscoveryResult(
              status: EmbyDiscoveryStatus.found,
              servers: _sortedServers(found),
            );
    } finally {
      rebroadcastTimer?.cancel();
      try {
        await subscription?.cancel();
      } catch (error, stackTrace) {
        DiagnosticLog.instance.error(
          'discovery',
          'Local Emby discovery subscription cleanup failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      try {
        await transport?.close();
      } catch (error, stackTrace) {
        DiagnosticLog.instance.error(
          'discovery',
          'Local Emby discovery transport cleanup failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    final finalResult = result;
    DiagnosticLog.instance.info(
      'discovery',
      'Local discovery completed status=${finalResult.status.name} '
          'servers=${finalResult.servers.length} '
          'attempted=$attemptedBroadcastCount successful=$successfulBroadcastCount',
    );
    return finalResult;
  }

  static List<DiscoveredServer> _sortedServers(List<DiscoveredServer> servers) {
    final results = List<DiscoveredServer>.of(servers);
    results.sort((left, right) {
      final name = left.name.toLowerCase().compareTo(right.name.toLowerCase());
      if (name != 0) return name;
      final id = left.id.toLowerCase().compareTo(right.id.toLowerCase());
      if (id != 0) return id;
      return left.address.toLowerCase().compareTo(right.address.toLowerCase());
    });
    return List<DiscoveredServer>.unmodifiable(results);
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
    _subscription = _socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = _socket.receive()) != null) {
          _packets.add(
            EmbyDiscoveryPacket(
              data: datagram!.data,
              address: datagram.address,
            ),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_closed) return;
        _packets.addError(error, stackTrace);
      },
    );
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
