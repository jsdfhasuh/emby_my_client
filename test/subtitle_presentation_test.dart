import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/source_input_failure.dart';
import 'package:emby_my_client/playback/subtitle_presentation.dart';
import 'package:emby_my_client/playback/subtitle_problem.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final codec in [
    'hdmv_pgs_subtitle',
    'pgs',
    'dvd_subtitle',
    'dvb_subtitle',
    'xsub',
  ]) {
    test('$codec enables delay and position but disables font and color', () {
      final value = SubtitlePresentation.fromState(_state(codec: codec));
      expect(value.delay, isTrue);
      expect(value.position, isTrue);
      expect(value.textStyle, isFalse);
    });
  }
  for (final codec in [
    'ass',
    'ssa',
    'srt',
    'subrip',
    'vtt',
    'webvtt',
    'mov_text',
    'text',
  ]) {
    test('$codec enables all text presentation controls', () {
      final value = SubtitlePresentation.fromState(_state(codec: codec));
      expect(value.delay && value.position && value.textStyle, isTrue);
    });
  }
  test(
    'actual native PGS evidence wins over unrelated server text metadata',
    () {
      final state = _state(codec: 'srt').copyWith(
        appliedNativeSubtitleId: '7',
        subtitleTracks: const [
          EngineTrack(id: '7', codec: 'hdmv_pgs_subtitle'),
        ],
      );
      expect(SubtitlePresentation.activeCodec(state), 'hdmv_pgs_subtitle');
      expect(SubtitlePresentation.fromState(state).textStyle, isFalse);
    },
  );
  test(
    'confirmed decoded codec overrides stale plan and native track metadata',
    () {
      final state = _state(codec: 'srt').copyWith(
        actualSubtitleCodec: 'hdmv_pgs_subtitle',
        appliedNativeSubtitleId: '7',
        subtitleTracks: const [EngineTrack(id: '7', codec: 'srt')],
      );
      expect(SubtitlePresentation.activeCodec(state), 'hdmv_pgs_subtitle');
      expect(SubtitlePresentation.fromState(state).textStyle, isFalse);
      final progressed = state.copyWith(position: const Duration(seconds: 12));
      expect(progressed.actualSubtitleCodec, 'hdmv_pgs_subtitle');
      expect(SubtitlePresentation.fromState(progressed).position, isTrue);
    },
  );
  test(
    'track replacement cannot carry old decoded codec into its capability',
    () {
      final oldPgs = _state(
        codec: 'srt',
      ).copyWith(actualSubtitleCodec: 'hdmv_pgs_subtitle');
      final applying = oldPgs.copyWith(
        subtitleSelectionStatus: SubtitleSelectionStatus.applying,
      );
      expect(applying.actualSubtitleCodec, isNull);
      final newText = applying.copyWith(
        subtitleSelectionStatus: SubtitleSelectionStatus.appliedEmbedded,
        actualSubtitleCodec: 'subrip',
      );
      expect(SubtitlePresentation.activeCodec(newText), 'subrip');
      expect(SubtitlePresentation.fromState(newText).textStyle, isTrue);
    },
  );
  test(
    'direct-play embedded PGS is not restyled using a server download Format hint',
    () {
      final state = _state(
        codec: 'hdmv_pgs_subtitle',
        format: 'srt',
        delivery: 'Embed',
      );
      expect(SubtitlePresentation.activeCodec(state), 'hdmv_pgs_subtitle');
      expect(SubtitlePresentation.fromState(state).textStyle, isFalse);
    },
  );
  test('converted embedded text uses the declared delivered format', () {
    final state = _state(
      codec: 'hdmv_pgs_subtitle',
      format: 'webvtt',
      delivery: 'Embed',
      method: PlayMethod.directStream,
    );
    expect(SubtitlePresentation.activeCodec(state), 'webvtt');
    expect(SubtitlePresentation.fromState(state).textStyle, isTrue);
  });
  test('downloaded external text uses its delivered format', () {
    final state = _state(
      codec: 'hdmv_pgs_subtitle',
      format: 'srt',
      delivery: 'External',
      external: true,
    );
    expect(SubtitlePresentation.activeCodec(state), 'srt');
    expect(SubtitlePresentation.fromState(state).textStyle, isTrue);
  });
  test('burned subtitles disable delay, position, size and color', () {
    final value = SubtitlePresentation.fromState(
      _state(codec: 'ass').copyWith(
        appliedSubtitleKind: AppliedSubtitleKind.server,
        subtitleSelectionStatus: SubtitleSelectionStatus.appliedServer,
      ),
    );
    expect(value.delay, isFalse);
    expect(value.position, isFalse);
    expect(value.textStyle, isFalse);
    expect(value.explanation, contains('烧录'));
  });
  for (final status in [
    SubtitleSelectionStatus.notApplied,
    SubtitleSelectionStatus.applying,
    SubtitleSelectionStatus.waitingForTracks,
    SubtitleSelectionStatus.failed,
    SubtitleSelectionStatus.disabled,
    SubtitleSelectionStatus.appliedNone,
  ]) {
    test('unconfirmed $status never advertises usable style controls', () {
      final state = _state(codec: 'ass')
          .copyWith(actualSubtitleCodec: 'hdmv_pgs_subtitle')
          .copyWith(subtitleSelectionStatus: status);
      expect(state.actualSubtitleCodec, isNull);
      final value = SubtitlePresentation.fromState(state);
      expect(value.delay || value.position || value.textStyle, isFalse);
    });
  }
  test(
    'unknown active format allows only timing and does not invent corruption',
    () {
      final value = SubtitlePresentation.fromState(
        _state(codec: 'unrecognized'),
      );
      expect(value.delay, isTrue);
      expect(value.position || value.textStyle, isFalse);
      for (final error in [
        StateError('api_key=fixture-private'),
        const FormatException('fixture parser unknown'),
        const SourceInputException('unrecognized'),
      ]) {
        final problem = SubtitleProblem.classify(error);
        expect(problem.kind, SubtitleProblemKind.unknown);
        expect(problem.message, isNot(contains('损坏')));
        expect(problem.message, isNot(contains('fixture')));
      }
    },
  );
  test(
    'codec substring inside an unrelated word is not subtitle decoder evidence',
    () {
      expect(
        SubtitleProblem.fromNative(
          'No decoder found for h264; class initialization failed',
          'ass',
        ),
        isNull,
      );
      expect(
        SubtitleProblem.fromNative('No decoder found for srtp_audio', 'srt'),
        isNull,
      );
    },
  );
}

PlaybackState _state({
  required String codec,
  String? format,
  String? delivery,
  PlayMethod method = PlayMethod.directPlay,
  bool external = false,
}) => PlaybackState(
  subtitleSelectionStatus: external
      ? SubtitleSelectionStatus.appliedExternal
      : SubtitleSelectionStatus.appliedEmbedded,
  appliedSubtitleKind: external
      ? AppliedSubtitleKind.external
      : AppliedSubtitleKind.embedded,
  appliedSubtitleStreamIndex: 3,
  plan: PlaybackPlan(
    uri: Uri.parse('https://fixture.invalid/video'),
    mediaSourceId: 'fixture-source',
    playSessionId: null,
    method: method,
    usesServerAuthentication: false,
    mediaStreams: [
      {
        'Index': 3,
        'Type': 'Subtitle',
        'Codec': codec,
        'Format': ?format,
        'DeliveryMethod': ?delivery,
        'IsExternal': external,
      },
    ],
    transcodingReasons: const [],
    availableMediaSources: const [],
  ),
);
