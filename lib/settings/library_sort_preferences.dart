import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/server_scope.dart';
import '../library/library_browse_state.dart';

const defaultLibrarySortPreference = LibrarySortPreference(
  sortBy: LibrarySortBy.name,
  sortOrder: LibrarySortOrder.ascending,
);

class LibrarySortPreference {
  const LibrarySortPreference({required this.sortBy, required this.sortOrder});

  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;

  bool get isDefault => this == defaultLibrarySortPreference;

  Map<String, String> toJson() => {
    'sortBy': sortBy.name,
    'sortOrder': sortOrder.name,
  };

  static LibrarySortPreference? fromJson(Object? value) {
    if (value is! Map) return null;
    final sortBy = _sortByFromName(value['sortBy']);
    final sortOrder = _sortOrderFromName(value['sortOrder']);
    if (sortBy == null || sortOrder == null) return null;
    return LibrarySortPreference(sortBy: sortBy, sortOrder: sortOrder);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibrarySortPreference &&
          sortBy == other.sortBy &&
          sortOrder == other.sortOrder;

  @override
  int get hashCode => Object.hash(sortBy, sortOrder);
}

LibrarySortBy? _sortByFromName(Object? value) {
  if (value is! String) return null;
  for (final candidate in LibrarySortBy.values) {
    if (candidate.name == value) return candidate;
  }
  return null;
}

LibrarySortOrder? _sortOrderFromName(Object? value) {
  if (value is! String) return null;
  for (final candidate in LibrarySortOrder.values) {
    if (candidate.name == value) return candidate;
  }
  return null;
}

abstract interface class LibrarySortPreferenceStore {
  Future<LibrarySortPreference?> load(ServerScope scope, String libraryId);

  Future<void> save(
    ServerScope scope,
    String libraryId,
    LibrarySortPreference preference,
  );

  Future<void> clearLibrary(ServerScope scope, String libraryId);

  Future<void> clear(ServerScope scope);
}

class _ScopedOperationQueue {
  final Map<ServerScope, Future<void>> _tails = {};

  Future<T> enqueue<T>(ServerScope scope, Future<T> Function() operation) {
    final previous = _tails[scope] ?? Future<void>.value();
    final result = previous.then<T>(
      (_) => operation(),
      onError: (_) => operation(),
    );
    final tail = result.then<void>((_) {}, onError: (_) {});
    _tails[scope] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[scope], tail)) _tails.remove(scope);
      }),
    );
    return result;
  }
}

class SharedPreferencesLibrarySortPreferenceStore
    implements LibrarySortPreferenceStore {
  SharedPreferencesLibrarySortPreferenceStore({
    SharedPreferencesAsync? preferences,
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  final _ScopedOperationQueue _queue = _ScopedOperationQueue();

  @override
  Future<LibrarySortPreference?> load(ServerScope scope, String libraryId) {
    final normalizedId = libraryId.trim();
    if (normalizedId.isEmpty) return Future.value(null);
    return _queue.enqueue(scope, () async {
      final values = await _read(scope);
      return values[normalizedId];
    });
  }

  @override
  Future<void> save(
    ServerScope scope,
    String libraryId,
    LibrarySortPreference preference,
  ) {
    final normalizedId = libraryId.trim();
    if (normalizedId.isEmpty) {
      return Future<void>.error(
        ArgumentError.value(libraryId, 'libraryId', 'must not be empty'),
      );
    }
    return _queue.enqueue(scope, () async {
      final values = await _read(scope);
      if (preference.isDefault) {
        values.remove(normalizedId);
      } else {
        values[normalizedId] = preference;
      }
      await _write(scope, values);
    });
  }

  @override
  Future<void> clearLibrary(ServerScope scope, String libraryId) {
    final normalizedId = libraryId.trim();
    if (normalizedId.isEmpty) return Future.value();
    return _queue.enqueue(scope, () async {
      final values = await _read(scope);
      if (!values.containsKey(normalizedId)) return;
      values.remove(normalizedId);
      await _write(scope, values);
    });
  }

  @override
  Future<void> clear(ServerScope scope) => _queue.enqueue(scope, () async {
    await _preferences.remove(_key(scope));
  });

  Future<Map<String, LibrarySortPreference>> _read(ServerScope scope) async {
    final encoded = await _preferences.getString(_key(scope));
    if (encoded == null || encoded.isEmpty) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      return {};
    }
    if (decoded is! Map) return {};
    final values = <String, LibrarySortPreference>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) continue;
      final preference = LibrarySortPreference.fromJson(entry.value);
      if (preference == null || preference.isDefault) continue;
      values[entry.key as String] = preference;
    }
    return values;
  }

  Future<void> _write(
    ServerScope scope,
    Map<String, LibrarySortPreference> values,
  ) async {
    if (values.isEmpty) {
      await _preferences.remove(_key(scope));
      return;
    }
    final encoded = jsonEncode({
      for (final entry in values.entries) entry.key: entry.value.toJson(),
    });
    await _preferences.setString(_key(scope), encoded);
  }

  String _key(ServerScope scope) =>
      'library.${scope.databaseKey}.sort_preferences.v1';
}

class MemoryLibrarySortPreferenceStore implements LibrarySortPreferenceStore {
  final Map<ServerScope, Map<String, LibrarySortPreference>> _values = {};
  final _ScopedOperationQueue _queue = _ScopedOperationQueue();

  @override
  Future<LibrarySortPreference?> load(ServerScope scope, String libraryId) {
    final normalizedId = libraryId.trim();
    if (normalizedId.isEmpty) return Future.value(null);
    return _queue.enqueue(scope, () async => _values[scope]?[normalizedId]);
  }

  @override
  Future<void> save(
    ServerScope scope,
    String libraryId,
    LibrarySortPreference preference,
  ) {
    final normalizedId = libraryId.trim();
    if (normalizedId.isEmpty) {
      return Future<void>.error(
        ArgumentError.value(libraryId, 'libraryId', 'must not be empty'),
      );
    }
    return _queue.enqueue(scope, () async {
      final values = _values.putIfAbsent(scope, () => {});
      if (preference.isDefault) {
        values.remove(normalizedId);
      } else {
        values[normalizedId] = preference;
      }
      if (values.isEmpty) _values.remove(scope);
    });
  }

  @override
  Future<void> clearLibrary(ServerScope scope, String libraryId) {
    final normalizedId = libraryId.trim();
    if (normalizedId.isEmpty) return Future.value();
    return _queue.enqueue(scope, () async {
      final values = _values[scope];
      values?.remove(normalizedId);
      if (values?.isEmpty ?? false) _values.remove(scope);
    });
  }

  @override
  Future<void> clear(ServerScope scope) => _queue.enqueue(scope, () async {
    _values.remove(scope);
  });
}
