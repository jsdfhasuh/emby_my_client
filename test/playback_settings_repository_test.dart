import 'dart:async';
import 'dart:convert';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/playback_settings.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    '100 concurrent field patches use one serialized account queue',
    () async {
      final storage = _MemoryStorage();
      final repository = PlaybackSettingsRepository(storage: storage);

      final operations = <Future<PlaybackSettingsSnapshot>>[];
      for (var index = 0; index < 100; index++) {
        operations.add(
          repository.patch(
            _firstSession,
            PlaybackSettingsPatch(playbackRate: 1 + index / 100),
          ),
        );
      }
      await Future.wait(operations);

      final snapshot = await repository.load(_firstSession);
      expect(snapshot.settings.playbackRate, 1.99);
      expect(snapshot.revision, 100);
      expect(storage.maxConcurrentOperations, 1);
    },
  );

  test('stale snapshots cannot overwrite newer fields', () async {
    final repository = PlaybackSettingsRepository(storage: _MemoryStorage());
    final stale = (await repository.load(_firstSession)).settings;

    await repository.patch(
      _firstSession,
      const PlaybackSettingsPatch(videoFit: 'cover'),
    );
    await repository.patch(
      _firstSession,
      PlaybackSettingsPatch(playbackRate: stale.playbackRate + 0.5),
    );

    final result = (await repository.load(_firstSession)).settings;
    expect(result.videoFit, 'cover');
    expect(result.playbackRate, 1.5);
  });

  test('a stale player rate patch preserves a newer cache patch', () async {
    final repository = PlaybackSettingsRepository(storage: _MemoryStorage());
    final stalePlayerSettings = (await repository.load(_firstSession)).settings;
    const cache = PlaybackCacheSettings(
      mode: PlaybackCacheMode.custom,
      customForwardSeconds: 300,
    );

    await repository.patch(
      _firstSession,
      const PlaybackSettingsPatch(cache: cache),
    );
    await repository.patch(
      _firstSession,
      PlaybackSettingsPatch(
        playbackRate: stalePlayerSettings.playbackRate + 0.25,
      ),
    );

    final result = (await repository.load(_firstSession)).settings;
    expect(result.playbackRate, 1.25);
    expect(result.cache.mode, PlaybackCacheMode.custom);
    expect(result.cache.customForwardSeconds, 300);
  });

  test('clear invalidates a patch blocked in storage read', () async {
    final storage = _MemoryStorage()
      ..seed(_firstSession, const PlaybackSettings());
    final repository = PlaybackSettingsRepository(storage: storage);
    final readGate = Completer<void>();
    storage.blockNextRead(readGate.future);

    final patch = repository.patch(
      _firstSession,
      const PlaybackSettingsPatch(playbackRate: 2),
    );
    await storage.readStarted.future;
    final clear = repository.clear(_firstSession);
    readGate.complete();

    await expectLater(patch, throwsA(isA<PlaybackSettingsPatchInvalidated>()));
    await clear;
    expect(storage.values, isEmpty);
    await expectLater(
      repository.patch(
        _firstSession,
        const PlaybackSettingsPatch(playbackRate: 1.5),
      ),
      throwsA(isA<PlaybackSettingsPatchInvalidated>()),
    );
  });

  test(
    'delete invalidates a patch already in storage write and prevents resurrection',
    () async {
      final storage = _MemoryStorage();
      final repository = PlaybackSettingsRepository(storage: storage);
      await repository.patch(
        _firstSession,
        const PlaybackSettingsPatch(videoFit: 'fill'),
      );
      final writeGate = Completer<void>();
      storage.blockNextWrite(writeGate.future);

      final patch = repository.patch(
        _firstSession,
        const PlaybackSettingsPatch(playbackRate: 2),
      );
      await storage.writeStarted.future;
      final delete = repository.deleteAccountSettings(_firstSession);
      writeGate.complete();

      await expectLater(
        patch,
        throwsA(isA<PlaybackSettingsPatchInvalidated>()),
      );
      await delete;
      expect(storage.values, isEmpty);
      expect(
        (await repository.load(_firstSession)).settings,
        const PlaybackSettings(),
      );
    },
  );

  test('load after clear explicitly reactivates the account queue', () async {
    final storage = _MemoryStorage();
    final repository = PlaybackSettingsRepository(storage: storage);

    await repository.clear(_firstSession);
    final defaults = await repository.load(_firstSession);
    expect(defaults.settings, isA<PlaybackSettings>());
    await repository.patch(
      _firstSession,
      const PlaybackSettingsPatch(playbackRate: 1.25),
    );

    expect((await repository.load(_firstSession)).settings.playbackRate, 1.25);
  });

  test(
    'delete-account and deactivate use the same generation barrier',
    () async {
      final storage = _MemoryStorage();
      final repository = PlaybackSettingsRepository(storage: storage);
      await repository.patch(
        _firstSession,
        const PlaybackSettingsPatch(videoFit: 'fill'),
      );

      await repository.deactivate(_firstSession);
      await expectLater(
        repository.patch(
          _firstSession,
          const PlaybackSettingsPatch(videoFit: 'cover'),
        ),
        throwsA(isA<PlaybackSettingsPatchInvalidated>()),
      );
      await repository.load(_firstSession);
      await repository.deleteAccountSettings(_firstSession);

      expect(storage.values, isEmpty);
    },
  );

  test('different accounts do not share queues or values', () async {
    final storage = _MemoryStorage();
    final repository = PlaybackSettingsRepository(storage: storage);

    await Future.wait([
      repository.patch(
        _firstSession,
        const PlaybackSettingsPatch(playbackRate: 1.25),
      ),
      repository.patch(
        _secondSession,
        const PlaybackSettingsPatch(playbackRate: 2),
      ),
    ]);

    expect((await repository.load(_firstSession)).settings.playbackRate, 1.25);
    expect((await repository.load(_secondSession)).settings.playbackRate, 2);
  });

  test('dispose invalidates pending work and rejects later access', () async {
    final storage = _MemoryStorage()
      ..seed(_firstSession, const PlaybackSettings());
    final repository = PlaybackSettingsRepository(storage: storage);
    final readGate = Completer<void>();
    storage.blockNextRead(readGate.future);

    final patch = repository.patch(
      _firstSession,
      const PlaybackSettingsPatch(playbackRate: 2),
    );
    await storage.readStarted.future;
    final dispose = repository.dispose();
    readGate.complete();

    await expectLater(
      patch,
      throwsA(isA<PlaybackSettingsRepositoryDisposed>()),
    );
    await dispose;
    expect(
      () => repository.load(_firstSession),
      throwsA(isA<PlaybackSettingsRepositoryDisposed>()),
    );
  });
}

class _MemoryStorage implements PlaybackSettingsStorage {
  final Map<String, String> values = {};
  Future<void>? _nextReadGate;
  Future<void>? _nextWriteGate;
  Completer<void> readStarted = Completer<void>();
  Completer<void> writeStarted = Completer<void>();
  int _activeOperations = 0;
  int maxConcurrentOperations = 0;

  void seed(EmbySession session, PlaybackSettings settings) {
    values[_key(session)] = jsonEncode(settings.toJson());
  }

  void blockNextRead(Future<void> gate) {
    _nextReadGate = gate;
    readStarted = Completer<void>();
  }

  void blockNextWrite(Future<void> gate) {
    _nextWriteGate = gate;
    writeStarted = Completer<void>();
  }

  @override
  Future<String?> read(String key) => _track(() async {
    final gate = _nextReadGate;
    if (gate != null) {
      _nextReadGate = null;
      if (!readStarted.isCompleted) readStarted.complete();
      await gate;
    }
    return values[key];
  });

  @override
  Future<void> write(String key, String value) => _track(() async {
    final gate = _nextWriteGate;
    if (gate != null) {
      _nextWriteGate = null;
      if (!writeStarted.isCompleted) writeStarted.complete();
      await gate;
    }
    values[key] = value;
  });

  @override
  Future<void> delete(String key) => _track(() async {
    values.remove(key);
  });

  Future<T> _track<T>(Future<T> Function() operation) async {
    _activeOperations++;
    if (_activeOperations > maxConcurrentOperations) {
      maxConcurrentOperations = _activeOperations;
    }
    try {
      return await operation();
    } finally {
      _activeOperations--;
    }
  }

  static String _key(EmbySession session) =>
      'playback_settings_v1_${session.serverId}_${session.userId}';
}

const _firstSession = EmbySession(
  serverUrl: 'https://first.example.test',
  serverName: 'First',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'first',
  accessToken: 'token-1',
  deviceId: 'device-1',
);

const _secondSession = EmbySession(
  serverUrl: 'https://second.example.test',
  serverName: 'Second',
  serverId: 'server-2',
  userId: 'user-2',
  username: 'second',
  accessToken: 'token-2',
  deviceId: 'device-2',
);
