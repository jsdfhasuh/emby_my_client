import 'dart:convert';
import 'dart:typed_data';

sealed class EmbyEvent {
  const EmbyEvent();

  static EmbyEvent? parse(dynamic raw) {
    try {
      final text = switch (raw) {
        String value => value,
        Uint8List value => utf8.decode(value),
        List<int> value => utf8.decode(value),
        _ => raw.toString(),
      };
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      return fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static EmbyEvent? fromJson(Map<String, dynamic> json) {
    final type = json['MessageType']?.toString().toLowerCase();
    final data = _map(json['Data']);
    return switch (type) {
      'librarychanged' => EmbyLibraryChanged(
        itemsAdded: _stringList(data['ItemsAdded']),
        itemsUpdated: _stringList(data['ItemsUpdated']),
        itemsRemoved: _stringList(data['ItemsRemoved']),
      ),
      'userdatachanged' => _userDataChanged(data),
      'playstate' => _playstate(data),
      _ => null,
    };
  }

  static EmbyUserDataChanged? _userDataChanged(Map<String, dynamic> data) {
    final userId = data['UserId']?.toString();
    if (userId == null || userId.isEmpty) return null;
    final itemIds = <String>{
      if (data['ItemId'] != null) data['ItemId'].toString(),
      for (final entry in data['UserDataList'] as List<dynamic>? ?? const [])
        if (entry is Map && entry['ItemId'] != null) entry['ItemId'].toString(),
    };
    return EmbyUserDataChanged(userId: userId, itemIds: itemIds.toList());
  }

  static EmbyPlaystateCommand? _playstate(Map<String, dynamic> data) {
    final command = data['Command']?.toString();
    if (command == null || command.isEmpty) return null;
    return EmbyPlaystateCommand(
      command: command,
      seekPositionTicks: _intValue(data['SeekPositionTicks']),
      itemId: data['ItemId']?.toString(),
      playSessionId: data['PlaySessionId']?.toString(),
    );
  }
}

class EmbyLibraryChanged extends EmbyEvent {
  const EmbyLibraryChanged({
    this.itemsAdded = const [],
    this.itemsUpdated = const [],
    this.itemsRemoved = const [],
  });

  final List<String> itemsAdded;
  final List<String> itemsUpdated;
  final List<String> itemsRemoved;

  Set<String> get affectedItemIds => {
    ...itemsAdded,
    ...itemsUpdated,
    ...itemsRemoved,
  };
}

class EmbyUserDataChanged extends EmbyEvent {
  const EmbyUserDataChanged({required this.userId, this.itemIds = const []});

  final String userId;
  final List<String> itemIds;
}

class EmbyPlaystateCommand extends EmbyEvent {
  const EmbyPlaystateCommand({
    required this.command,
    this.seekPositionTicks,
    this.itemId,
    this.playSessionId,
  });

  final String command;
  final int? seekPositionTicks;
  final String? itemId;
  final String? playSessionId;
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<String> _stringList(dynamic value) => value is List
    ? value.map((entry) => entry.toString()).toList(growable: false)
    : const [];

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
