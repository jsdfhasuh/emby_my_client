import 'dart:convert';

import '../models/emby_models.dart';

class ServerScope {
  const ServerScope({required this.serverId, required this.userId})
    : assert(serverId != ''),
      assert(userId != '');

  factory ServerScope.fromSession(EmbySession session) {
    final serverId = session.serverId.trim();
    final userId = session.userId.trim();
    if (userId.isEmpty) {
      throw const FormatException('Emby session user ID is empty');
    }
    return ServerScope(
      serverId: serverId.isEmpty
          ? 'endpoint:${_encode(session.serverUrl)}'
          : serverId,
      userId: userId,
    );
  }

  final String serverId;
  final String userId;

  String get databaseKey => '${_encode(serverId)}.${_encode(userId)}';

  String get logLabel => _hash('$serverId\u0000$userId');

  Map<String, String> toJson() => {'serverId': serverId, 'userId': userId};

  factory ServerScope.fromJson(Map<String, dynamic> json) {
    final serverId = json['serverId']?.toString().trim() ?? '';
    final userId = json['userId']?.toString().trim() ?? '';
    if (serverId.isEmpty || userId.isEmpty) {
      throw const FormatException('Invalid server scope');
    }
    return ServerScope(serverId: serverId, userId: userId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerScope &&
          other.serverId == serverId &&
          other.userId == userId;

  @override
  int get hashCode => Object.hash(serverId, userId);

  @override
  String toString() => 'ServerScope($logLabel)';
}

String _encode(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

String _hash(String value) {
  var result = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    result ^= codeUnit;
    result = (result * 0x01000193) & 0xffffffff;
  }
  return result.toRadixString(16).padLeft(8, '0');
}
