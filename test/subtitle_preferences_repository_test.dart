import 'dart:async';
import 'dart:convert';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/subtitle_preferences.dart';
import 'package:emby_my_client/playback/subtitle_preferences_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'preferences and per-source choices survive a fresh repository',
    () async {
      final storage = _Storage();
      final repo = SubtitlePreferencesRepository(storage: storage);
      final initial = await repo.load(_session());
      expect(initial.preferences.language, SubtitleLanguagePreference.chinese);
      await repo.setPreferences(
        _session(),
        const SubtitlePreferences(
          language: SubtitleLanguagePreference.traditionalChinese,
        ),
      );
      await _remember(repo);
      final restored = await SubtitlePreferencesRepository(
        storage: storage,
      ).load(_session());
      expect(
        restored.preferences.language,
        SubtitleLanguagePreference.traditionalChinese,
      );
      expect(
        restored.rememberedFor(itemId: 'movie', mediaSourceId: 'source')?.kind,
        RememberedSubtitleKind.disabled,
      );
      expect(
        restored.rememberedFor(itemId: 'other', mediaSourceId: 'source'),
        isNull,
      );
      expect(
        restored.rememberedFor(itemId: 'movie', mediaSourceId: 'other'),
        isNull,
      );
      expect(storage.values.toString(), isNot(contains('private-token')));
      expect(storage.values.toString(), isNot(contains('movie')));
      expect(storage.values.toString(), isNot(contains('private-user')));
    },
  );

  test(
    'account and server identities, including endpoint fallback, isolate records',
    () async {
      final repo = SubtitlePreferencesRepository(storage: _Storage());
      await repo.load(_session());
      await _remember(repo);
      for (final session in [
        _session(user: 'another-user'),
        _session(server: 'another-server'),
        _session(server: '', endpoint: 'https://first.example.test'),
        _session(server: '', endpoint: 'https://second.example.test'),
      ]) {
        expect((await repo.load(session)).rememberedCount, 0);
      }
    },
  );

  test('concurrent patches and memories preserve both data sets', () async {
    final repo = SubtitlePreferencesRepository(storage: _Storage());
    await repo.load(_session());
    await Future.wait([
      repo.setPreferences(
        _session(),
        const SubtitlePreferences(forced: SubtitleForcedPreference.prefer),
      ),
      for (var i = 0; i < 12; i++) _remember(repo, item: 'movie-$i'),
    ]);
    final snapshot = await repo.load(_session());
    expect(snapshot.rememberedCount, 12);
    expect(snapshot.preferences.forced, SubtitleForcedPreference.prefer);
    expect(snapshot.revision, 13);
  });

  test('deactivation invalidates a write blocked in read', () async {
    final storage = _Storage();
    final repo = SubtitlePreferencesRepository(storage: storage);
    await repo.load(_session());
    storage.readGate = Completer<void>();
    final writing = _remember(repo);
    final rejected = expectLater(
      writing,
      throwsA(isA<SubtitlePreferencesInvalidated>()),
    );
    await storage.readStarted.future;
    final deactivated = repo.deactivate(_session());
    storage.readGate!.complete();
    await rejected;
    await deactivated;
    expect(storage.values, isEmpty);
  });

  test(
    'clear wins after an in-flight write and rejects old generation after reload',
    () async {
      final storage = _Storage();
      final repo = SubtitlePreferencesRepository(storage: storage);
      final old = await repo.load(_session());
      storage.writeGate = Completer<void>();
      final writing = _remember(repo);
      final rejected = expectLater(
        writing,
        throwsA(isA<SubtitlePreferencesInvalidated>()),
      );
      await storage.writeStarted.future;
      final clearing = repo.deleteAccountPreferences(_session());
      storage.writeGate!.complete();
      await rejected;
      await clearing;
      expect(storage.values, isEmpty);
      final next = await repo.load(_session());
      expect(next.generation, greaterThan(old.generation));
      await expectLater(
        repo.remember(
          _session(),
          itemId: 'movie',
          mediaSourceId: 'source',
          choice: const SubtitleRememberedChoice.disabled(),
          expectedGeneration: old.generation,
        ),
        throwsA(isA<SubtitlePreferencesInvalidated>()),
      );
      await _remember(repo);
      expect((await repo.load(_session())).rememberedCount, 1);
    },
  );

  test(
    'read completion cannot reactivate an account deactivated during load',
    () async {
      final storage = _Storage()..readGate = Completer<void>();
      final repo = SubtitlePreferencesRepository(storage: storage);
      final loading = repo.load(_session());
      final rejected = expectLater(
        loading,
        throwsA(isA<SubtitlePreferencesInvalidated>()),
      );
      await storage.readStarted.future;
      final deactivated = repo.deactivate(_session());
      storage.readGate!.complete();
      await rejected;
      await deactivated;
      await expectLater(
        _remember(repo),
        throwsA(isA<SubtitlePreferencesInvalidated>()),
      );
    },
  );

  test(
    'corrupt records recover without discarding valid preference fields',
    () async {
      final storage = _Storage();
      final repo = SubtitlePreferencesRepository(storage: storage);
      await repo.load(_session());
      await _remember(repo);
      final key = storage.values.keys.single;
      storage.values[key] = '{broken';
      expect((await repo.load(_session())).rememberedCount, 0);
      storage.values[key] = jsonEncode({
        'version': 1,
        'preferences': {'language': 'traditionalChinese', 'forced': 'future'},
        'choices': {
          'invalid': {'kind': 'disabled'},
        },
      });
      final restored = await repo.load(_session());
      expect(
        restored.preferences.language,
        SubtitleLanguagePreference.traditionalChinese,
      );
      expect(restored.preferences.forced, SubtitleForcedPreference.avoid);
      expect(restored.rememberedCount, 0);
    },
  );

  test('history is bounded and a refreshed record survives eviction', () async {
    final repo = SubtitlePreferencesRepository(storage: _Storage());
    await repo.load(_session());
    for (
      var i = 0;
      i < SubtitlePreferencesRepository.maxRememberedChoices;
      i++
    ) {
      await _remember(repo, item: 'movie-$i');
    }
    await _remember(repo, item: 'movie-0');
    await _remember(repo, item: 'new');
    final snapshot = await repo.load(_session());
    expect(
      snapshot.rememberedCount,
      SubtitlePreferencesRepository.maxRememberedChoices,
    );
    expect(
      snapshot.rememberedFor(itemId: 'movie-0', mediaSourceId: 'source'),
      isNotNull,
    );
    expect(
      snapshot.rememberedFor(itemId: 'movie-1', mediaSourceId: 'source'),
      isNull,
    );
    await repo.forget(_session(), itemId: 'movie-0', mediaSourceId: 'source');
    expect(
      (await repo.load(_session())).rememberedCount,
      SubtitlePreferencesRepository.maxRememberedChoices - 1,
    );
  });

  test('disposed repositories reject further access', () async {
    final repo = SubtitlePreferencesRepository(storage: _Storage());
    await repo.load(_session());
    await repo.dispose();
    expect(
      () => repo.load(_session()),
      throwsA(isA<SubtitlePreferencesRepositoryDisposed>()),
    );
  });
}

Future<SubtitlePreferenceSnapshot> _remember(
  SubtitlePreferencesRepository repo, {
  String item = 'movie',
}) => repo.remember(
  _session(),
  itemId: item,
  mediaSourceId: 'source',
  choice: const SubtitleRememberedChoice.disabled(),
);

EmbySession _session({
  String server = 'server',
  String user = 'private-user',
  String endpoint = 'https://example.test',
}) => EmbySession(
  serverUrl: endpoint,
  serverName: 'Server',
  serverId: server,
  userId: user,
  username: 'Private username',
  accessToken: 'private-token',
  deviceId: 'device',
);

class _Storage implements PlaybackSettingsStorage {
  final values = <String, String>{};
  Completer<void>? readGate;
  Completer<void>? writeGate;
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();
  @override
  Future<String?> read(String key) async {
    final gate = readGate;
    if (gate != null && !gate.isCompleted) {
      if (!readStarted.isCompleted) readStarted.complete();
      await gate.future;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final gate = writeGate;
    if (gate != null && !gate.isCompleted) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await gate.future;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
