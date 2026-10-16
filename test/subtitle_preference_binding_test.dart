import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_preference_binding.dart';
import 'package:emby_my_client/playback/subtitle_preferences.dart';
import 'package:emby_my_client/playback/subtitle_preferences_repository.dart';
import 'package:emby_my_client/playback/subtitle_target.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'manually confirming the already-applied server default is remembered',
    () async {
      final f = await _Fixture.create(serverDefault: true);
      addTearDown(f.close);
      f.resolver.defaultSubtitleIndex = 2;
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      expect(
        f.controller.state.desiredSubtitleSelection.source,
        SubtitleSelectionSource.serverDefault,
      );
      expect(f.controller.state.appliedSubtitleStreamIndex, 2);
      await f.controller.selectSubtitleStream(2);
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      expect(
        f.binding.snapshot!
            .rememberedFor(itemId: 'item', mediaSourceId: 'source')
            ?.kind,
        RememberedSubtitleKind.server,
      );
    },
  );

  test(
    'switching source does not carry the previous source disabled choice',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.controller.state.appliedSubtitleStreamIndex == 2);
      await f.controller.selectSubtitleStream(null);
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      await f.controller.selectMediaSource('source-b');
      await _wait(
        () =>
            f.controller.state.plan?.mediaSourceId == 'source-b' &&
            f.controller.state.appliedSubtitleStreamIndex == 2,
      );
      expect(
        f.binding.snapshot!
            .rememberedFor(itemId: 'item', mediaSourceId: 'source')
            ?.kind,
        RememberedSubtitleKind.disabled,
      );
      expect(
        f.binding.snapshot!.rememberedFor(
          itemId: 'item',
          mediaSourceId: 'source-b',
        ),
        isNull,
      );
    },
  );

  test(
    'Chinese preference applies only after source resolves and reaches ready',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      f.resolver.gate = Completer<void>();
      final starting = f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      expect(f.engine.subtitleSelections, isEmpty);
      f.resolver.gate!.complete();
      await starting;
      await _wait(() => f.controller.state.appliedSubtitleStreamIndex == 2);
      expect(f.controller.state.phase, PlaybackPhase.ready);
      expect(f.engine.subtitleSelections.last, '42');
      expect(
        (await f.repo.load(_session)).rememberedCount,
        0,
        reason: 'automatic preferences must not become manual memories',
      );
    },
  );

  test(
    'saved native metadata waits for late tracks and rebinds changed native ID',
    () async {
      final repo = SubtitlePreferencesRepository(storage: _Storage());
      await repo.load(_session);
      final binding = SubtitleInputBinding(
        itemId: 'item',
        itemSession: Object(),
        engine: _Engine(),
        generation: 1,
        inputEpoch: 1,
      );
      final old = NativeSubtitleTrack(
        const EngineTrack(id: 'old-id', language: 'zho', codec: 'subrip'),
        binding,
      );
      final saved = SubtitleChoiceCatalog.fromPlayback(
        plan: _plan(streams: const []),
        nativeTracks: [old],
      ).capture(SubtitleSelection.nativeTrack(old));
      await repo.remember(
        _session,
        itemId: 'item',
        mediaSourceId: 'source',
        choice: saved!,
      );
      final f = await _Fixture.create(
        repo: repo,
        streams: const [],
        initialNative: false,
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      expect(f.controller.state.appliedNativeSubtitleId, isNull);
      f.engine.subtitles.add(const [
        EngineTrack(id: 'new-id', language: 'chi', codec: 'srt'),
      ]);
      await _wait(() => f.controller.state.appliedNativeSubtitleId == 'new-id');
      expect(f.engine.subtitleSelections.last, 'new-id');
      f.engine.openNative = const [
        EngineTrack(id: 'newer-id', language: 'zho', codec: 'subrip'),
      ];
      await f.controller.reconfigure();
      await _wait(
        () => f.controller.state.appliedNativeSubtitleId == 'newer-id',
      );
      expect(f.engine.subtitleSelections.last, 'newer-id');
    },
  );

  test(
    'same source reopen restores a native fingerprint with its new ID',
    () async {
      final f = await _Fixture.create(streams: const [], serverDefault: true);
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      await f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      final previousEpoch = f.controller.subtitleInputEpoch;
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
      ];
      await f.controller.reconfigure();
      await _wait(() => f.controller.state.appliedNativeSubtitleId == '77');
      expect(f.controller.subtitleInputEpoch, isNot(previousEpoch));
      expect(f.engine.subtitleSelections.last, '77');
    },
  );

  test(
    'confirmed native choice survives reopen before persistence finishes',
    () async {
      final storage = _Storage();
      final f = await _Fixture.create(
        repo: SubtitlePreferencesRepository(storage: storage),
        streams: const [],
        serverDefault: true,
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final gate = storage.writeGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      expect(f.binding.snapshot!.rememberedCount, 0);
      f.engine.openNative = const [
        EngineTrack(id: '88', language: 'chi', codec: 'srt'),
      ];
      await f.controller.reconfigure();
      await _wait(() => f.controller.state.appliedNativeSubtitleId == '88');
      gate.complete();
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
    },
  );

  test(
    'forgetting a choice clears its volatile fingerprint before reopen',
    () async {
      final f = await _Fixture.create(streams: const [], serverDefault: true);
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      await f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      await f.binding.forgetCurrentChoice();
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
      ];
      await f.controller.reconfigure();
      await Future<void>.delayed(Duration.zero);
      expect(f.controller.state.appliedNativeSubtitleId, isNull);
      expect(f.binding.snapshot!.rememberedCount, 0);
    },
  );

  test(
    'pending manual server choice is saved after its input reopens',
    () async {
      final f = await _Fixture.create(
        serverDefault: true,
        streams: const [
          {
            'Index': 2,
            'Type': 'Subtitle',
            'Language': 'zho',
            'Codec': 'srt',
            'IsForced': false,
            'IsExternal': false,
            'DeliveryMethod': 'Encode',
          },
        ],
      );
      addTearDown(f.close);
      f.resolver.method = PlayMethod.transcode;
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final previousEpoch = f.controller.subtitleInputEpoch;
      await f.controller.selectSubtitleStream(2);
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      expect(f.controller.subtitleInputEpoch, isNot(previousEpoch));
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.appliedServer,
      );
      expect(
        f.binding.snapshot!
            .rememberedFor(itemId: 'item', mediaSourceId: 'source')
            ?.kind,
        RememberedSubtitleKind.server,
      );
    },
  );

  test(
    'manual choice made while preferences load wins and is remembered',
    () async {
      final storage = _Storage()..gate = Completer<void>();
      final repo = SubtitlePreferencesRepository(storage: storage);
      final f = await _Fixture.create(repo: repo);
      addTearDown(f.close);
      await f.controller.start();
      await f.controller.selectSubtitleStream(null);
      storage.gate!.complete();
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.disabled,
      );
      expect(f.engine.subtitleSelections.whereType<String>(), isEmpty);
      expect(
        f.binding.snapshot!
            .rememberedFor(itemId: 'item', mediaSourceId: 'source')
            ?.kind,
        RememberedSubtitleKind.disabled,
      );
    },
  );

  test('failed manual application does not overwrite a saved choice', () async {
    final f = await _Fixture.create(serverDefault: true);
    addTearDown(f.close);
    await f.controller.start();
    await _wait(() => f.binding.snapshot != null);
    await f.controller.selectSubtitleStream(null);
    await _wait(() => f.binding.snapshot?.rememberedCount == 1);
    f.engine.failSubtitle = true;
    await f.controller.selectSubtitleStream(2);
    expect(
      f.controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.failed,
    );
    await Future<void>.delayed(Duration.zero);
    final saved = (await f.repo.load(
      _session,
    )).rememberedFor(itemId: 'item', mediaSourceId: 'source');
    expect(saved?.kind, RememberedSubtitleKind.disabled);
  });

  test('saved choice is isolated by source and item', () async {
    final repo = SubtitlePreferencesRepository(storage: _Storage());
    await repo.load(_session);
    await repo.remember(
      _session,
      itemId: 'other-item',
      mediaSourceId: 'source',
      choice: const SubtitleRememberedChoice.disabled(),
    );
    await repo.remember(
      _session,
      itemId: 'item',
      mediaSourceId: 'other-source',
      choice: const SubtitleRememberedChoice.disabled(),
    );
    final f = await _Fixture.create(repo: repo);
    addTearDown(f.close);
    await f.controller.start();
    await _wait(() => f.controller.state.appliedSubtitleStreamIndex == 2);
    expect(
      f.controller.state.subtitleSelectionStatus,
      SubtitleSelectionStatus.appliedEmbedded,
    );
  });

  test('shutdown cancels a pending restore before storage returns', () async {
    final storage = _Storage()..gate = Completer<void>();
    final f = await _Fixture.create(
      repo: SubtitlePreferencesRepository(storage: storage),
    );
    await f.controller.start();
    await f.controller.shutdown();
    final calls = f.engine.subtitleSelections.length;
    storage.gate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(f.engine.subtitleSelections.length, calls);
    expect(f.binding.snapshot, isNull);
    f.controller.dispose();
  });

  test(
    'account deletion invalidates binding save and cannot resurrect history',
    () async {
      final f = await _Fixture.create(serverDefault: true);
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      await f.repo.deleteAccountPreferences(_session);
      await f.controller.selectSubtitleStream(null);
      await _wait(() => f.binding.saveError != null);
      expect((await f.repo.load(_session)).rememberedCount, 0);
    },
  );
}

class _Fixture {
  _Fixture(
    this.controller,
    this.engine,
    this.resolver,
    this.repo,
    this.binding,
  );
  final PlaybackController controller;
  final _Engine engine;
  final _Resolver resolver;
  final SubtitlePreferencesRepository repo;
  final SubtitlePreferenceBinding binding;

  static Future<_Fixture> create({
    SubtitlePreferencesRepository? repo,
    List<Map<String, dynamic>> streams = _streams,
    bool initialNative = true,
    bool serverDefault = false,
  }) async {
    repo ??= SubtitlePreferencesRepository(storage: _Storage());
    if (serverDefault) {
      await repo.load(_session);
      await repo.setPreferences(
        _session,
        const SubtitlePreferences(
          language: SubtitleLanguagePreference.serverDefault,
        ),
      );
    }
    final engine = _Engine()..initialNative = initialNative;
    final resolver = _Resolver(streams);
    final controller = PlaybackController(
      item: const EmbyItem(
        id: 'item',
        name: 'Synthetic fixture',
        type: 'Movie',
        imageTags: {},
        backdropImageTags: [],
        genres: [],
        userData: EmbyUserData(),
      ),
      engine: engine,
      resolver: resolver,
      reporter: _Reporter(),
      playbackHeaders: const {},
      trackWaitTimeout: const Duration(milliseconds: 20),
    );
    final binding = SubtitlePreferenceBinding(
      controller: controller,
      session: _session,
      repository: repo,
    );
    return _Fixture(controller, engine, resolver, repo, binding);
  }

  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
  }
}

const _streams = <Map<String, dynamic>>[
  {
    'Index': 2,
    'Type': 'Subtitle',
    'Language': 'zho',
    'Codec': 'srt',
    'IsForced': false,
    'IsExternal': false,
  },
];
PlaybackPlan _plan({
  String source = 'source',
  List<Map<String, dynamic>> streams = _streams,
}) => PlaybackPlan(
  uri: Uri.parse('https://fixture.example.test/video'),
  mediaSourceId: source,
  playSessionId: null,
  method: PlayMethod.directPlay,
  usesServerAuthentication: false,
  mediaStreams: streams,
  transcodingReasons: const [],
  availableMediaSources: const [],
);

class _Resolver implements PlaybackStreamResolver {
  _Resolver(this.streams);
  final List<Map<String, dynamic>> streams;
  Completer<void>? gate;
  int? defaultSubtitleIndex;
  PlayMethod method = PlayMethod.directPlay;
  @override
  bool get canForceTranscode => false;
  @override
  Uri resolveExternalUrl(String rawUrl) => Uri.parse(rawUrl);
  @override
  Future<PlaybackPlan> resolve(
    EmbyItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int maxStreamingBitrate = 120000000,
    bool forceTranscode = false,
  }) async {
    await gate?.future;
    return _plan(source: mediaSourceId ?? 'source', streams: streams).copyWith(
      method: method,
      subtitleStreamIndex: subtitleDisabled
          ? null
          : subtitleStreamIndex ?? defaultSubtitleIndex,
      subtitleDisabled: subtitleDisabled,
    );
  }
}

class _Engine extends RoutePlaybackEngine {
  bool initialNative = true;
  List<EngineTrack>? openNative;
  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    await super.open(uri, headers: headers, play: play);
    if (!initialNative) subtitles.add(const []);
    if (openNative != null) subtitles.add(openNative!);
  }
}

class _Reporter implements PlaybackReporter {
  @override
  void activate(PlaybackPlan plan) {}
  @override
  void updatePlan(PlaybackPlan plan) {}
  @override
  Future<void> reportStart(Duration position, {required bool isPaused}) async {}
  @override
  Future<void> reportProgress({
    required Duration position,
    required bool isPaused,
  }) async {}
  @override
  Future<void> stop(Duration position) async {}
  @override
  Future<void> cleanup(PlaybackPlan plan) async {}
}

class _Storage implements PlaybackSettingsStorage {
  final values = <String, String>{};
  Completer<void>? gate;
  Completer<void>? writeGate;
  @override
  Future<String?> read(String key) async {
    await gate?.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await writeGate?.future;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<void> _wait(bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for subtitle preference state');
}

const _session = EmbySession(
  serverUrl: 'https://fixture.example.test',
  serverName: 'Fixture',
  serverId: 'server',
  userId: 'user',
  username: 'Fixture',
  accessToken: 'synthetic-token',
  deviceId: 'device',
);
