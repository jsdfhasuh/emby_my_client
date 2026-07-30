import 'dart:collection';

import '../models/emby_models.dart';
import 'server_scope.dart';

enum ServerFeature { remoteControl, mediaDownloads, liveTv, syncPlay }

enum CapabilitySupport { unknown, supported, unsupported }

class ServerCapabilityEvidence {
  const ServerCapabilityEvidence({
    required this.support,
    required this.source,
    required this.observedAt,
  });

  final CapabilitySupport support;
  final String source;
  final DateTime observedAt;

  Map<String, dynamic> toJson() => {
    'support': support.name,
    'source': source,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };

  static ServerCapabilityEvidence? fromJson(dynamic value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final support = CapabilitySupport.values
        .where((candidate) => candidate.name == json['support']?.toString())
        .firstOrNull;
    final source = json['source']?.toString().trim() ?? '';
    final observedAt = DateTime.tryParse(json['observedAt']?.toString() ?? '');
    if (support == null || source.isEmpty || observedAt == null) return null;
    return ServerCapabilityEvidence(
      support: support,
      source: source,
      observedAt: observedAt.toUtc(),
    );
  }
}

class ServerCapabilities {
  ServerCapabilities({
    required this.scope,
    required this.updatedAt,
    this.productName,
    this.serverVersion,
    Map<ServerFeature, ServerCapabilityEvidence> evidence = const {},
  }) : evidence = UnmodifiableMapView(Map.of(evidence));

  factory ServerCapabilities.fromSession(
    EmbySession session, {
    DateTime? observedAt,
  }) => ServerCapabilities(
    scope: ServerScope.fromSession(session),
    productName: session.productName,
    serverVersion: session.serverVersion,
    updatedAt: (observedAt ?? DateTime.now()).toUtc(),
  );

  final ServerScope scope;
  final String? productName;
  final String? serverVersion;
  final DateTime updatedAt;
  final Map<ServerFeature, ServerCapabilityEvidence> evidence;

  CapabilitySupport statusOf(ServerFeature feature) =>
      evidence[feature]?.support ?? CapabilitySupport.unknown;

  ServerCapabilities observe(
    ServerFeature feature,
    CapabilitySupport support, {
    required String source,
    DateTime? observedAt,
  }) {
    if (support == CapabilitySupport.unknown) {
      throw ArgumentError.value(support, 'support', 'must be an observation');
    }
    final timestamp = (observedAt ?? DateTime.now()).toUtc();
    return ServerCapabilities(
      scope: scope,
      productName: productName,
      serverVersion: serverVersion,
      updatedAt: timestamp,
      evidence: {
        ...evidence,
        feature: ServerCapabilityEvidence(
          support: support,
          source: source,
          observedAt: timestamp,
        ),
      },
    );
  }

  ServerCapabilities withServerMetadata({
    String? productName,
    String? serverVersion,
    DateTime? observedAt,
  }) => ServerCapabilities(
    scope: scope,
    productName: _nonEmpty(productName) ?? this.productName,
    serverVersion: _nonEmpty(serverVersion) ?? this.serverVersion,
    updatedAt: (observedAt ?? DateTime.now()).toUtc(),
    evidence: evidence,
  );
}

String? _nonEmpty(String? value) {
  final result = value?.trim();
  return result == null || result.isEmpty ? null : result;
}
