import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/server_capabilities.dart';
import '../core/server_scope.dart';
import 'local_database.dart';

class ServerCapabilitiesRepository {
  const ServerCapabilitiesRepository(this._database);

  final LocalDatabase _database;

  Future<ServerCapabilities?> load(ServerScope scope) async {
    final rows = await _database.read(
      (database) => database.query(
        'server_capabilities',
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
        limit: 1,
      ),
    );
    if (rows.isEmpty) return null;
    return _decode(scope, rows.single);
  }

  Future<void> save(ServerCapabilities capabilities) async {
    final supported = <String>[];
    final unsupported = <String>[];
    final evidence = <String, dynamic>{};

    for (final entry in capabilities.evidence.entries) {
      evidence[entry.key.name] = entry.value.toJson();
      switch (entry.value.support) {
        case CapabilitySupport.supported:
          supported.add(entry.key.name);
          break;
        case CapabilitySupport.unsupported:
          unsupported.add(entry.key.name);
          break;
        case CapabilitySupport.unknown:
          break;
      }
    }
    supported.sort();
    unsupported.sort();

    await _database.transaction(
      (database) => database.insert('server_capabilities', {
        'server_id': capabilities.scope.serverId,
        'user_id': capabilities.scope.userId,
        'product_name': capabilities.productName,
        'server_version': capabilities.serverVersion,
        'supported_features': jsonEncode(supported),
        'unsupported_features': jsonEncode(unsupported),
        'evidence_json': jsonEncode(evidence),
        'updated_at_ms': capabilities.updatedAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );
  }

  Future<void> remove(ServerScope scope) async {
    await _database.transaction(
      (database) => database.delete(
        'server_capabilities',
        where: 'server_id = ? AND user_id = ?',
        whereArgs: [scope.serverId, scope.userId],
      ),
    );
  }

  ServerCapabilities _decode(ServerScope scope, Map<String, Object?> row) {
    final updatedAt = DateTime.fromMillisecondsSinceEpoch(
      row['updated_at_ms'] as int? ?? 0,
      isUtc: true,
    );
    final evidence = <ServerFeature, ServerCapabilityEvidence>{};
    final rawEvidence = _decodeMap(row['evidence_json']);
    for (final entry in rawEvidence.entries) {
      final feature = _featureNamed(entry.key);
      final value = ServerCapabilityEvidence.fromJson(entry.value);
      if (feature != null && value != null) evidence[feature] = value;
    }

    _addLegacyEvidence(
      evidence,
      row['supported_features'],
      CapabilitySupport.supported,
      updatedAt,
    );
    _addLegacyEvidence(
      evidence,
      row['unsupported_features'],
      CapabilitySupport.unsupported,
      updatedAt,
    );

    return ServerCapabilities(
      scope: scope,
      productName: row['product_name'] as String?,
      serverVersion: row['server_version'] as String?,
      updatedAt: updatedAt,
      evidence: evidence,
    );
  }

  void _addLegacyEvidence(
    Map<ServerFeature, ServerCapabilityEvidence> evidence,
    Object? encoded,
    CapabilitySupport support,
    DateTime observedAt,
  ) {
    for (final name in _decodeStringList(encoded)) {
      final feature = _featureNamed(name);
      if (feature == null || evidence.containsKey(feature)) continue;
      evidence[feature] = ServerCapabilityEvidence(
        support: support,
        source: 'legacy-capability-record',
        observedAt: observedAt,
      );
    }
  }
}

Map<String, dynamic> _decodeMap(Object? value) {
  if (value is! String || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
  } catch (_) {
    return const {};
  }
}

List<String> _decodeStringList(Object? value) {
  if (value is! String || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    return decoded is List
        ? decoded.map((item) => item.toString()).toList(growable: false)
        : const [];
  } catch (_) {
    return const [];
  }
}

ServerFeature? _featureNamed(String name) =>
    ServerFeature.values.where((feature) => feature.name == name).firstOrNull;
