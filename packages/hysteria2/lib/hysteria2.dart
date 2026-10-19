import 'package:flutter/services.dart';

/// Android's process-wide Hysteria2 service. Leases belong to this Flutter engine.
class Hysteria2Platform {
  const Hysteria2Platform();

  static const MethodChannel _channel = MethodChannel('dev.emby/hysteria2');

  /// [kind] is download, playback, or configuration. Configuration is exclusive.
  Future<String> acquire({required String scope, required String kind}) async {
    return (await _channel.invokeMethod<String>('acquire', <String, Object?>{
      'scope': scope,
      'kind': kind,
    }))!;
  }

  /// Connects a lease, returning loopback HTTP CONNECT proxy credentials.
  ///
  /// Config contains host, port, auth, sni, and optional obfsPassword. TLS is
  /// always verified. An empty sni uses host. Identical configs share a core.
  Future<Map<String, Object?>> connect({
    required String leaseId,
    required Map<String, Object?> config,
  }) async {
    return Map<String, Object?>.from(
      (await _channel.invokeMapMethod<String, Object?>(
        'connect',
        <String, Object?>{'leaseId': leaseId, 'config': config},
      ))!,
    );
  }

  Future<void> release(String leaseId) => _channel.invokeMethod<void>(
    'release',
    <String, Object?>{'leaseId': leaseId},
  );

  /// Counts and state only; never returns configuration or credentials.
  Future<Map<String, Object?>> status() async => Map<String, Object?>.from(
    (await _channel.invokeMapMethod<String, Object?>('status'))!,
  );
}
