import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_preference_binding.dart';
import 'package:emby_my_client/playback/subtitle_preferences.dart';
import 'package:emby_my_client/playback/subtitle_preferences_repository.dart';
import 'package:emby_my_client/playback/subtitle_target.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';
import 'source_http_input_test.dart' show fixtureRequest;

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
      await _wait(
        () => f.controller.state.appliedNativeSubtitleId == '77',
        reason:
            'fresh native 77 after reopen: ${f.controller.state.subtitleSelectionStatus}',
      );
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
    'pending native choice survives memory-pressure reopen with a fresh ID',
    () async {
      final f = await _Fixture.create(
        streams: const [],
        serverDefault: true,
        controlledInput: true,
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final oldTarget = f.controller.nativeSubtitleChoices.single;
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectNativeSubtitle(oldTarget);
      await _wait(() => f.engine.selectionStarted);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.applying,
      );
      expect(f.binding.snapshot!.rememberedCount, 0);
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
      ];
      final previousEpoch = f.controller.subtitleInputEpoch;
      final reopening = f.controller.handleMemoryPressure();
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      gate.complete();
      await selecting;
      await reopening;
      await _wait(() => f.controller.state.appliedNativeSubtitleId == '77');
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      expect(
        f.controller.subtitleInputEpoch,
        isNot(oldTarget.binding.inputEpoch),
      );
      final current =
          f.controller.state.desiredSubtitleSelection.target
              as NativeSubtitleTrack;
      expect(current.binding.inputEpoch, f.controller.subtitleInputEpoch);
      expect(f.engine.subtitleSelections.where((id) => id == '42').length, 1);
      final writes = f.engine.subtitleSelections.length;
      await f.controller.selectNativeSubtitle(oldTarget);
      expect(f.engine.subtitleSelections.length, writes);
      expect(f.controller.state.appliedNativeSubtitleId, '77');
    },
  );

  test(
    'pending safety restore waits for late unique native metadata',
    () async {
      final f = await _Fixture.create(
        streams: const [],
        serverDefault: true,
        controlledInput: true,
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.engine.selectionStarted);
      f.engine.openNative = const [];
      final previousEpoch = f.controller.subtitleInputEpoch;
      final reopening = f.controller.handleMemoryPressure();
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      gate.complete();
      await selecting;
      await reopening;
      expect(f.controller.state.appliedNativeSubtitleId, isNull);
      expect(f.binding.snapshot!.rememberedCount, 0);
      f.engine.subtitles.add(const [
        EngineTrack(id: '88', language: 'zho', codec: 'subrip'),
      ]);
      await _wait(
        () => f.controller.state.appliedNativeSubtitleId == '88',
        reason: 'late native 88 after reopen',
      );
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
    },
  );

  for (final ambiguous in [false, true]) {
    test(
      'pending safety restore rejects ${ambiguous ? "ambiguous" : "missing"} tracks',
      () async {
        final f = await _Fixture.create(
          streams: const [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'Title': 'B',
              'Language': 'eng',
              'Codec': 'ass',
              'IsExternal': false,
            },
          ],
          serverDefault: true,
          controlledInput: true,
        );
        f.resolver.defaultSubtitleIndex = 2;
        f.engine.openNative = const [
          EngineTrack(id: '42', title: 'A', language: 'chi', codec: 'srt'),
          EngineTrack(id: '9', title: 'B', language: 'eng', codec: 'ass'),
        ];
        addTearDown(f.close);
        await f.controller.start();
        await _wait(() => f.binding.snapshot != null);
        final gate = f.engine.selectionGate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final selecting = f.controller.selectNativeSubtitle(
          f.controller.nativeSubtitleChoices.first,
        );
        await _wait(() => f.engine.selectionStarted);
        f.engine.openNative = ambiguous
            ? const [
                EngineTrack(
                  id: '77',
                  title: 'A',
                  language: 'chi',
                  codec: 'srt',
                ),
                EngineTrack(
                  id: '88',
                  title: 'A',
                  language: 'zho',
                  codec: 'subrip',
                ),
                EngineTrack(
                  id: '42',
                  title: 'B',
                  language: 'eng',
                  codec: 'ass',
                ),
              ]
            : const [
                EngineTrack(
                  id: '42',
                  title: 'B',
                  language: 'eng',
                  codec: 'ass',
                ),
              ];
        final previousEpoch = f.controller.subtitleInputEpoch;
        final reopening = f.controller.handleMemoryPressure();
        await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
        gate.complete();
        await selecting;
        await reopening;
        await _wait(
          () =>
              f.binding.resolution?.status ==
              (ambiguous
                  ? SubtitlePreferenceStatus.ambiguous
                  : SubtitlePreferenceStatus.unavailable),
        );
        expect(f.controller.state.phase, PlaybackPhase.ready);
        expect(
          f.controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.failed,
        );
        expect(f.controller.state.subtitleSelectionError, isNotEmpty);
        expect(f.controller.state.appliedNativeSubtitleId, isNull);
        expect(
          f.engine.activeSubtitleId,
          isNull,
          reason: 'the unrelated server default B must remain off',
        );
        expect(f.engine.subtitleSelections.where((id) => id == '42').length, 1);
        expect(f.binding.snapshot!.rememberedCount, 0);
      },
    );
  }

  test(
    'new manual selection during safety reopen wins over pending intent',
    () async {
      final f = await _Fixture.create(
        streams: const [],
        serverDefault: true,
        controlledInput: true,
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final old = f.controller.nativeSubtitleChoices.single;
      final selecting = f.controller.selectNativeSubtitle(old);
      await _wait(() => f.engine.selectionStarted);
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
        EngineTrack(id: '99', language: 'eng', codec: 'ass'),
      ];
      Future<void>? newer;
      var requested = false;
      void selectLatest() {
        if (!requested &&
            f.controller.state.phase == PlaybackPhase.ready &&
            f.engine.opens == 2) {
          requested = true;
          newer = f.controller.selectNativeSubtitle(
            f.controller.nativeSubtitleChoices.last,
          );
        }
      }

      f.controller.addListener(selectLatest);
      addTearDown(() => f.controller.removeListener(selectLatest));
      final previousEpoch = f.controller.subtitleInputEpoch;
      final reopening = f.controller.handleMemoryPressure();
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      gate.complete();
      await selecting;
      await reopening;
      await newer;
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      expect(requested, isTrue);
      expect(f.controller.state.appliedNativeSubtitleId, '99');
      expect(f.engine.subtitleSelections.whereType<String>(), ['42', '99']);
      await f.controller.selectNativeSubtitle(old);
      expect(f.controller.state.appliedNativeSubtitleId, '99');
    },
  );

  test(
    'shutdown cancels pending safety intent before old native completion',
    () async {
      final f = await _Fixture.create(
        streams: const [],
        serverDefault: true,
        controlledInput: true,
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.engine.selectionStarted);
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
      ];
      final previousEpoch = f.controller.subtitleInputEpoch;
      final reopening = f.controller.handleMemoryPressure();
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      final closing = f.controller.shutdown();
      gate.complete();
      await selecting;
      await reopening;
      await closing;
      expect(f.engine.subtitleSelections, isNot(contains('77')));
      expect((await f.repo.load(_session)).rememberedCount, 0);
    },
  );

  test(
    'unconfirmed intent is not carried by an unrelated source switch',
    () async {
      final f = await _Fixture.create(streams: const [], serverDefault: true);
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.engine.selectionStarted);
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
      ];
      final previousEpoch = f.controller.subtitleInputEpoch;
      final switching = f.controller.selectMediaSource('source-b');
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      gate.complete();
      await selecting;
      await switching;
      expect(f.controller.state.plan!.mediaSourceId, 'source-b');
      expect(f.controller.state.appliedNativeSubtitleId, isNull);
      expect(f.engine.subtitleSelections, isNot(contains('77')));
      expect(f.binding.snapshot!.rememberedCount, 0);
    },
  );

  test(
    'pending native safety intent survives preferences still loading',
    () async {
      final storage = _Storage()..gate = Completer<void>();
      final f = await _Fixture.create(
        streams: const [],
        controlledInput: true,
        repo: SubtitlePreferencesRepository(storage: storage),
      );
      addTearDown(f.close);
      addTearDown(() {
        if (!storage.gate!.isCompleted) storage.gate!.complete();
      });
      await f.controller.start();
      expect(f.binding.snapshot, isNull);
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.engine.selectionStarted);
      f.engine.openNative = const [
        EngineTrack(id: '77', language: 'chi', codec: 'srt'),
      ];
      final previousEpoch = f.controller.subtitleInputEpoch;
      final reopening = f.controller.handleMemoryPressure();
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      gate.complete();
      await selecting;
      await reopening;
      expect(f.engine.activeSubtitleId, isNull);
      storage.gate!.complete();
      await _wait(() => f.controller.state.appliedNativeSubtitleId == '77');
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
    },
  );

  test(
    'pending native without identifying metadata stays explicitly unavailable',
    () async {
      final f = await _Fixture.create(
        streams: const [],
        serverDefault: true,
        controlledInput: true,
      );
      addTearDown(f.close);
      f.engine.openNative = const [EngineTrack(id: '42', codec: 'ass')];
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final gate = f.engine.selectionGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectNativeSubtitle(
        f.controller.nativeSubtitleChoices.single,
      );
      await _wait(() => f.engine.selectionStarted);
      f.engine.openNative = const [EngineTrack(id: '77', codec: 'ass')];
      final previousEpoch = f.controller.subtitleInputEpoch;
      final reopening = f.controller.handleMemoryPressure();
      await _wait(() => f.controller.subtitleInputEpoch != previousEpoch);
      gate.complete();
      await selecting;
      await reopening;
      expect(f.controller.state.phase, PlaybackPhase.ready);
      expect(
        f.controller.state.subtitleSelectionStatus,
        SubtitleSelectionStatus.failed,
      );
      expect(f.engine.activeSubtitleId, isNull);
      expect(f.binding.snapshot!.rememberedCount, 0);
    },
  );

  test(
    'pending local intent rebinds only through its owning completed safety token',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-safety-local-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final subtitle = File('${directory.path}/subtitle.srt');
      await subtitle.writeAsString(
        '1\n00:00:00,000 --> 00:00:12,000\nSYNTHETIC_LOCAL\n',
      );
      final f = await _Fixture.create(
        serverDefault: true,
        offline: true,
        streams: [
          {
            'Index': 2,
            'Type': 'Subtitle',
            'Title': 'Local A',
            'Language': 'zho',
            'Codec': 'srt',
            'IsExternal': true,
            'DeliveryMethod': 'External',
            'DeliveryUrl': subtitle.uri.toString(),
          },
        ],
      );
      addTearDown(f.close);
      await f.controller.start();
      await _wait(() => f.binding.snapshot != null);
      final old = f.controller.localSubtitleChoices.single;
      final gate = f.engine.externalGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final selecting = f.controller.selectLocalSubtitle(old);
      await _wait(() => f.engine.externalLoads.isNotEmpty);
      // Offline playback does not request cache-pressure recovery. Exercise the
      // binding transaction directly; the native test above covers its real caller.
      final token = f.binding.capturePendingSafetyIntent();
      expect(token, isNotNull);
      final reopening = f.controller.reconfigure();
      await _wait(
        () => f.controller.subtitleInputEpoch != old.binding.inputEpoch,
      );
      gate.complete();
      await selecting;
      await reopening;
      f.binding.finishSafetyReopen(token, completed: true);
      await _wait(
        () =>
            f.controller.state.subtitleSelectionStatus ==
            SubtitleSelectionStatus.appliedExternal,
      );
      final fresh =
          f.controller.state.desiredSubtitleSelection.target
              as LocalExternalAsset;
      expect(fresh.binding.inputEpoch, f.controller.subtitleInputEpoch);
      expect(fresh.binding.inputEpoch, isNot(old.binding.inputEpoch));
      await _wait(() => f.binding.snapshot?.rememberedCount == 1);
      final loads = f.engine.externalLoads.length;
      await f.controller.selectLocalSubtitle(old);
      expect(f.engine.externalLoads.length, loads);
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
    bool controlledInput = false,
    bool offline = false,
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
    final resolver = _Resolver(streams)
      ..sourceRequest = controlledInput
          ? fixtureRequest('https://fixture.example.test/video')
          : null;
    resolver.offline = offline;
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
  PlaybackResourceRequest? sourceRequest,
  List<Map<String, dynamic>> streams = _streams,
}) => PlaybackPlan(
  uri: Uri.parse('https://fixture.example.test/video'),
  mediaSourceId: source,
  sourceRequest: sourceRequest,
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
  PlaybackResourceRequest? sourceRequest;
  bool offline = false;
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
    return _plan(
      source: mediaSourceId ?? 'source',
      streams: streams,
      sourceRequest: sourceRequest,
    ).copyWith(
      method: method,
      transportKind: offline
          ? PlaybackTransportKind.offlineLocal
          : PlaybackTransportKind.unknown,
      subtitleStreamIndex: subtitleDisabled
          ? null
          : subtitleStreamIndex ?? defaultSubtitleIndex,
      subtitleDisabled: subtitleDisabled,
    );
  }
}

class _Engine extends RoutePlaybackEngine
    implements SourceDirectPlaybackEngine {
  Completer<void>? selectionGate;
  bool selectionStarted = false;
  String? activeSubtitleId;
  Completer<void>? externalGate;
  final externalLoads = <Uri>[];
  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {
    externalLoads.add(uri);
    final gate = externalGate;
    externalGate = null;
    await gate?.future;
  }

  @override
  Future<void> selectSubtitleTrack(String? trackId) async {
    await super.selectSubtitleTrack(trackId);
    if (trackId != null && selectionGate != null) {
      final gate = selectionGate!;
      selectionGate = null;
      selectionStarted = true;
      await gate.future;
    }
    activeSubtitleId = trackId;
  }

  @override
  Future<void> openSource(
    PlaybackResourceRequest request, {
    required bool play,
  }) => open(Uri.parse('embyinput://fixture'), headers: const {}, play: play);

  int opens = 0;
  bool initialNative = true;
  List<EngineTrack>? openNative;
  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    opens++;
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

Future<void> _wait(
  bool Function() ready, {
  String reason = 'subtitle preference state',
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for $reason');
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
