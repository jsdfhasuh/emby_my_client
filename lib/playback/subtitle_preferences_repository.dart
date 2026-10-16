import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/server_scope.dart';
import '../models/emby_models.dart';
import 'playback_settings_repository.dart';
import 'subtitle_preferences.dart';

class SubtitlePreferencesInvalidated implements Exception {
  const SubtitlePreferencesInvalidated();
}

class SubtitlePreferencesRepositoryDisposed implements Exception {
  const SubtitlePreferencesRepositoryDisposed();
}

class SubtitlePreferenceSnapshot {
  SubtitlePreferenceSnapshot._({
    required this.preferences,
    required Map<String, SubtitleRememberedChoice> choices,
    required this.revision,
    required this.generation,
  }) : _choices = Map.unmodifiable(choices);

  final SubtitlePreferences preferences;
  final Map<String, SubtitleRememberedChoice> _choices;
  final int revision;
  final int generation;
  int get rememberedCount => _choices.length;

  SubtitleRememberedChoice? rememberedFor({
    required String itemId,
    required String mediaSourceId,
  }) => itemId.trim().isEmpty || mediaSourceId.trim().isEmpty
      ? null
      : _choices[_itemKey(itemId, mediaSourceId)];
}

/// One shared default instance ensures account cleanup and player writes use
/// the same generation barriers. Tests can inject in-memory storage.
class SubtitlePreferencesRepository {
  SubtitlePreferencesRepository({PlaybackSettingsStorage? storage})
    : _storage = storage ?? SecurePlaybackSettingsStorage();

  static final instance = SubtitlePreferencesRepository();
  static const maxRememberedChoices = 256;

  final PlaybackSettingsStorage _storage;
  final Map<String, _AccountQueue> _accounts = {};
  bool _disposed = false;

  Future<SubtitlePreferenceSnapshot> load(EmbySession session) {
    final key = _accountKey(session);
    final state = _stateFor(key);
    final generation = state.generation;
    return _enqueue(state, () async {
      _throwIfDisposed();
      final data = await _read(key);
      if (state.generation != generation) {
        throw const SubtitlePreferencesInvalidated();
      }
      _throwIfDisposed();
      state.active = true;
      return _snapshot(data, state);
    });
  }

  Future<SubtitlePreferenceSnapshot> setPreferences(
    EmbySession session,
    SubtitlePreferences preferences, {
    int? expectedGeneration,
  }) => _mutate(session, expectedGeneration, (data) {
    data.preferences = preferences;
  });

  Future<SubtitlePreferenceSnapshot> remember(
    EmbySession session, {
    required String itemId,
    required String mediaSourceId,
    required SubtitleRememberedChoice choice,
    int? expectedGeneration,
  }) {
    _validateItem(itemId, mediaSourceId);
    return _mutate(session, expectedGeneration, (data) {
      final key = _itemKey(itemId, mediaSourceId);
      // Updating a choice also moves it to the end of the bounded history.
      data.choices.remove(key);
      data.choices[key] = choice;
      while (data.choices.length > maxRememberedChoices) {
        data.choices.remove(data.choices.keys.first);
      }
    });
  }

  Future<SubtitlePreferenceSnapshot> forget(
    EmbySession session, {
    required String itemId,
    required String mediaSourceId,
    int? expectedGeneration,
  }) {
    _validateItem(itemId, mediaSourceId);
    return _mutate(session, expectedGeneration, (data) {
      data.choices.remove(_itemKey(itemId, mediaSourceId));
    });
  }

  Future<void> deactivate(EmbySession session) {
    final state = _stateFor(_accountKey(session));
    state.generation++;
    state.active = false;
    return _enqueue(state, () {
      state.revision++;
    });
  }

  Future<void> clear(EmbySession session) {
    final key = _accountKey(session);
    final state = _stateFor(key);
    state.generation++;
    state.active = false;
    return _enqueue(state, () async {
      await _storage.delete(key);
      state.revision++;
    });
  }

  Future<void> deleteAccountPreferences(EmbySession session) => clear(session);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final state in _accounts.values) {
      state.generation++;
      state.active = false;
    }
    await Future.wait(_accounts.values.map((state) => state.tail));
  }

  Future<SubtitlePreferenceSnapshot> _mutate(
    EmbySession session,
    int? expectedGeneration,
    void Function(_PreferencesData) change,
  ) {
    final key = _accountKey(session);
    final state = _stateFor(key);
    final generation = expectedGeneration ?? state.generation;
    if (!state.active || state.generation != generation) {
      return Future.error(const SubtitlePreferencesInvalidated());
    }
    return _enqueue(state, () async {
      _checkGeneration(state, generation);
      final data = await _read(key);
      _checkGeneration(state, generation);
      change(data);
      await _storage.write(key, jsonEncode(data.toJson()));
      _checkGeneration(state, generation);
      state.revision++;
      return _snapshot(data, state);
    });
  }

  Future<_PreferencesData> _read(String key) async {
    final raw = await _storage.read(key);
    if (raw == null || raw.isEmpty) return _PreferencesData();
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) {
        return _PreferencesData();
      }
      final choices = <String, SubtitleRememberedChoice>{};
      final saved = value['choices'];
      if (saved is Map) {
        for (final entry in saved.entries) {
          final choice = SubtitleRememberedChoice.fromJson(entry.value);
          if (entry.key is String &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String) &&
              choice != null) {
            choices[entry.key as String] = choice;
          }
        }
        while (choices.length > maxRememberedChoices) {
          choices.remove(choices.keys.first);
        }
      }
      return _PreferencesData(
        preferences: SubtitlePreferences.fromJson(value['preferences']),
        choices: choices,
      );
    } on FormatException {
      return _PreferencesData();
    }
  }

  _AccountQueue _stateFor(String key) {
    _throwIfDisposed();
    return _accounts.putIfAbsent(key, _AccountQueue.new);
  }

  void _checkGeneration(_AccountQueue state, int generation) {
    _throwIfDisposed();
    if (!state.active || state.generation != generation) {
      throw const SubtitlePreferencesInvalidated();
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw const SubtitlePreferencesRepositoryDisposed();
  }

  Future<T> _enqueue<T>(_AccountQueue state, FutureOr<T> Function() action) {
    final completer = Completer<T>();
    state.tail = state.tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  static SubtitlePreferenceSnapshot _snapshot(
    _PreferencesData data,
    _AccountQueue state,
  ) => SubtitlePreferenceSnapshot._(
    preferences: data.preferences,
    choices: data.choices,
    revision: state.revision,
    generation: state.generation,
  );

  static String _accountKey(EmbySession session) =>
      'subtitle_preferences_v1_${ServerScope.fromSession(session).cacheNamespace}';
}

class _AccountQueue {
  Future<void> tail = Future<void>.value();
  int generation = 0;
  int revision = 0;
  bool active = false;
}

class _PreferencesData {
  _PreferencesData({
    this.preferences = const SubtitlePreferences(),
    Map<String, SubtitleRememberedChoice>? choices,
  }) : choices = choices ?? {};

  SubtitlePreferences preferences;
  final Map<String, SubtitleRememberedChoice> choices;

  Map<String, Object> toJson() => {
    'version': 1,
    'preferences': preferences.toJson(),
    'choices': choices.map((key, value) => MapEntry(key, value.toJson())),
  };
}

String _itemKey(String itemId, String mediaSourceId) =>
    sha256.convert(utf8.encode(jsonEncode([itemId, mediaSourceId]))).toString();

void _validateItem(String itemId, String mediaSourceId) {
  if (itemId.trim().isEmpty || mediaSourceId.trim().isEmpty) {
    throw ArgumentError(
      'Subtitle preferences require item and source identity',
    );
  }
}
