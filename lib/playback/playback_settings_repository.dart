import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/emby_models.dart';
import 'cache/playback_cache_settings.dart';
import 'playback_settings.dart';
import 'seek_preview_mode.dart';

abstract interface class PlaybackSettingsStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecurePlaybackSettingsStorage implements PlaybackSettingsStorage {
  SecurePlaybackSettingsStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class PlaybackSettingsSnapshot {
  const PlaybackSettingsSnapshot({
    required this.settings,
    required this.revision,
    required this.generation,
  });

  final PlaybackSettings settings;
  final int revision;
  final int generation;
}

class PlaybackSettingsPatch {
  const PlaybackSettingsPatch({
    this.maxStreamingBitrate,
    this.seekBackwardSeconds,
    this.seekForwardSeconds,
    this.horizontalSwipeSeekSpanSeconds,
    this.seekPreviewMode,
    this.playbackRate,
    this.videoFit,
    this.subtitleDelayMilliseconds,
    this.audioDelayMilliseconds,
    this.subtitleFontSize,
    this.subtitleColor,
    this.subtitleOutlineColor,
    this.subtitlePosition,
    this.cache,
  });

  final int? maxStreamingBitrate;
  final int? seekBackwardSeconds;
  final int? seekForwardSeconds;
  final int? horizontalSwipeSeekSpanSeconds;
  final SeekPreviewMode? seekPreviewMode;
  final double? playbackRate;
  final String? videoFit;
  final int? subtitleDelayMilliseconds;
  final int? audioDelayMilliseconds;
  final double? subtitleFontSize;
  final int? subtitleColor;
  final int? subtitleOutlineColor;
  final int? subtitlePosition;
  final PlaybackCacheSettings? cache;

  PlaybackSettings applyTo(PlaybackSettings current) => current.copyWith(
    maxStreamingBitrate: maxStreamingBitrate,
    seekBackwardSeconds: seekBackwardSeconds,
    seekForwardSeconds: seekForwardSeconds,
    horizontalSwipeSeekSpanSeconds: horizontalSwipeSeekSpanSeconds,
    seekPreviewMode: seekPreviewMode,
    playbackRate: playbackRate,
    videoFit: videoFit,
    subtitleDelayMilliseconds: subtitleDelayMilliseconds,
    audioDelayMilliseconds: audioDelayMilliseconds,
    subtitleFontSize: subtitleFontSize,
    subtitleColor: subtitleColor,
    subtitleOutlineColor: subtitleOutlineColor,
    subtitlePosition: subtitlePosition,
    cache: cache,
  );
}

class PlaybackSettingsPatchInvalidated implements Exception {
  const PlaybackSettingsPatchInvalidated();
}

class PlaybackSettingsRepositoryDisposed implements Exception {
  const PlaybackSettingsRepositoryDisposed();
}

class PlaybackSettingsRepository {
  PlaybackSettingsRepository({PlaybackSettingsStorage? storage})
    : _storage = storage ?? SecurePlaybackSettingsStorage();

  final PlaybackSettingsStorage _storage;
  final Map<String, _AccountSettingsQueue> _accounts = {};
  bool _disposed = false;

  Future<PlaybackSettingsSnapshot> load(EmbySession session) {
    final state = _stateFor(session);
    return _enqueue(state, () async {
      _throwIfDisposed();
      state.active = true;
      final settings = await _read(session);
      return PlaybackSettingsSnapshot(
        settings: settings,
        revision: state.revision,
        generation: state.generation,
      );
    });
  }

  Future<PlaybackSettingsSnapshot> patch(
    EmbySession session,
    PlaybackSettingsPatch patch,
  ) {
    final state = _stateFor(session);
    if (!state.active) {
      return Future<PlaybackSettingsSnapshot>.error(
        const PlaybackSettingsPatchInvalidated(),
      );
    }
    final submittedGeneration = state.generation;
    return _enqueue(state, () async {
      _throwIfPatchInvalid(state, submittedGeneration);
      final current = await _read(session);
      _throwIfPatchInvalid(state, submittedGeneration);
      final next = patch.applyTo(current);
      await _storage.write(_key(session), jsonEncode(next.toJson()));
      _throwIfPatchInvalid(state, submittedGeneration);
      state.revision++;
      return PlaybackSettingsSnapshot(
        settings: next,
        revision: state.revision,
        generation: state.generation,
      );
    });
  }

  Future<void> clear(EmbySession session) => _invalidateAndDelete(session);

  Future<void> deleteAccountSettings(EmbySession session) =>
      _invalidateAndDelete(session);

  Future<void> deactivate(EmbySession session) {
    final state = _stateFor(session);
    state.generation++;
    state.active = false;
    return _enqueue(state, () async {
      state.revision++;
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final state in _accounts.values) {
      state.generation++;
      state.active = false;
    }
    await Future.wait(
      _accounts.values.map((state) => state.tail.catchError((_) {})),
    );
  }

  Future<void> _invalidateAndDelete(EmbySession session) {
    final state = _stateFor(session);
    state.generation++;
    state.active = false;
    return _enqueue(state, () async {
      await _storage.delete(_key(session));
      state.revision++;
    });
  }

  Future<PlaybackSettings> _read(EmbySession session) async {
    final value = await _storage.read(_key(session));
    if (value == null || value.isEmpty) return const PlaybackSettings();
    try {
      return PlaybackSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
    } catch (_) {
      return const PlaybackSettings();
    }
  }

  _AccountSettingsQueue _stateFor(EmbySession session) {
    _throwIfDisposed();
    return _accounts.putIfAbsent(_key(session), _AccountSettingsQueue.new);
  }

  Future<T> _enqueue<T>(
    _AccountSettingsQueue state,
    FutureOr<T> Function() operation,
  ) {
    final completer = Completer<T>();
    final previous = state.tail;
    final next = previous.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    state.tail = next;
    return completer.future;
  }

  void _throwIfPatchInvalid(
    _AccountSettingsQueue state,
    int submittedGeneration,
  ) {
    _throwIfDisposed();
    if (!state.active || state.generation != submittedGeneration) {
      throw const PlaybackSettingsPatchInvalidated();
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw const PlaybackSettingsRepositoryDisposed();
  }

  static String _key(EmbySession session) =>
      'playback_settings_v1_${session.serverId}_${session.userId}';
}

class _AccountSettingsQueue {
  Future<void> tail = Future<void>.value();
  int revision = 0;
  int generation = 0;
  bool active = true;
}
