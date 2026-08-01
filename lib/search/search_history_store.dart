import 'package:shared_preferences/shared_preferences.dart';

import '../core/server_scope.dart';

const searchHistoryLimit = 12;

List<String> updatedSearchHistory(
  Iterable<String> current,
  String query, {
  int limit = searchHistoryLimit,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty || limit <= 0) return const [];

  final result = <String>[trimmed];
  final seen = <String>{trimmed.toLowerCase()};
  for (final value in current) {
    final candidate = value.trim();
    if (candidate.isEmpty || !seen.add(candidate.toLowerCase())) continue;
    result.add(candidate);
    if (result.length >= limit) break;
  }
  return List.unmodifiable(result);
}

abstract interface class SearchHistoryStore {
  Future<List<String>> load(ServerScope scope);

  Future<void> add(ServerScope scope, String query);

  Future<void> clear(ServerScope scope);
}

class SharedPreferencesSearchHistoryStore implements SearchHistoryStore {
  SharedPreferencesSearchHistoryStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<List<String>> load(ServerScope scope) async {
    final stored = await _preferences.getStringList(_key(scope)) ?? const [];
    return _normalize(stored);
  }

  @override
  Future<void> add(ServerScope scope, String query) async {
    final next = updatedSearchHistory(await load(scope), query);
    if (next.isEmpty) return;
    await _preferences.setStringList(_key(scope), next);
  }

  @override
  Future<void> clear(ServerScope scope) => _preferences.remove(_key(scope));

  List<String> _normalize(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || !seen.add(trimmed.toLowerCase())) continue;
      result.add(trimmed);
      if (result.length >= searchHistoryLimit) break;
    }
    return List.unmodifiable(result);
  }

  String _key(ServerScope scope) => 'search.${scope.databaseKey}.recent.v1';
}

class MemorySearchHistoryStore implements SearchHistoryStore {
  final Map<ServerScope, List<String>> _values = {};

  @override
  Future<List<String>> load(ServerScope scope) async =>
      List.unmodifiable(_values[scope] ?? const []);

  @override
  Future<void> add(ServerScope scope, String query) async {
    _values[scope] = updatedSearchHistory(_values[scope] ?? const [], query);
  }

  @override
  Future<void> clear(ServerScope scope) async {
    _values.remove(scope);
  }
}
