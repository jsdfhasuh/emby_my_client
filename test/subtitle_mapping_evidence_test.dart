import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

const _mapper = TrackMapper();
const _stream = <String, dynamic>{
  'Index': 2,
  'Type': 'Subtitle',
  'Language': 'chi',
  'Codec': 'srt',
  'Title': 'private-original-title',
  'DisplayTitle': 'private-display-label',
};

PlaybackMediaSource _source(
  List<Map<String, dynamic>> streams, {
  String id = 'private-source-id',
}) => PlaybackMediaSource(
  id: id,
  supportsDirectPlay: true,
  supportsDirectStream: false,
  supportsTranscoding: false,
  mediaStreams: streams,
  transcodingReasons: const [],
);

PlaybackPlan _plan({
  List<PlaybackMediaSource>? sources,
  List<Map<String, dynamic>> streams = const [_stream],
}) => PlaybackPlan(
  uri: Uri.parse('file:///private-folder/private-media.mkv'),
  mediaSourceId: 'private-source-id',
  playSessionId: null,
  method: PlayMethod.directPlay,
  usesServerAuthentication: false,
  transportKind: PlaybackTransportKind.offlineLocal,
  mediaStreams: streams,
  transcodingReasons: const [],
  availableMediaSources: sources ?? [_source(streams)],
);

String _log(TrackMappingResult result, {PlaybackPlan? plan}) {
  final logs = <String>[];
  final diagnostics = PlaybackDiagnostics(
    writer: (_, _, line) => logs.add(line),
  );
  diagnostics.subtitleMappingFailed(
    selectionSource: 'explicit',
    subtitleKind: 'embedded',
    streamIndex: 2,
    generation: 1,
    result: result,
    source: _mapper.sourceEvidence(plan ?? _plan(), 2),
  );
  return logs.single;
}

void main() {
  test(
    'three rejected candidates retain different conflicts instead of union per track',
    () {
      final server = _mapper.fromStreams([_stream], 'subtitle').single;
      final result = _mapper.match(server, const [
        EngineTrack(id: 'auto'),
        EngineTrack(
          id: 'private-native-id-a',
          language: 'eng',
          codec: 'subrip',
          title: 'private-original-title',
        ),
        EngineTrack(
          id: 'private-native-id-b',
          language: 'zho',
          codec: 'ass',
          title: 'private-original-title',
        ),
        EngineTrack(
          id: 'private-native-id-c',
          language: 'chi',
          codec: 'srt',
          title: 'different-private-title',
        ),
      ]);
      expect(result.engineId, isNull);
      expect(result.reason, TrackMappingReason.metadataConflict);
      expect(result.realTrackCount, 3);
      expect(result.candidateCount, 0);
      expect(result.conflictFields, {
        TrackMetadataField.language,
        TrackMetadataField.codec,
        TrackMetadataField.title,
      });
      final line = _log(result);
      expect(
        line,
        contains(
          'track0=rejected:language.conflict,codec.same,title.same,channels.missingBoth',
        ),
      );
      expect(
        line,
        contains(
          'track1=rejected:language.same,codec.conflict,title.same,channels.missingBoth',
        ),
      );
      expect(
        line,
        contains(
          'track2=rejected:language.same,codec.same,title.conflict,channels.missingBoth',
        ),
      );
      expect(line, contains('conflictFieldsScope=allTracksUnion'));
      expect(line, contains('comparisonBasis=normalizedRawMetadata'));
      expect(line, contains('nativeSourceIdentity=unverified'));
      for (final secret in [
        'private-original-title',
        'private-display-label',
        'private-native-id',
        'different-private-title',
        'private-source-id',
        'private-folder',
        'private-media',
      ]) {
        expect(line, isNot(contains(secret)));
      }
    },
  );

  test(
    'missing metadata distinguishes each side without becoming conflicting evidence',
    () {
      final result = _mapper.match(
        const PlaybackTrack(
          index: 2,
          type: 'Subtitle',
          language: 'chi',
          channels: 2,
        ),
        const [
          EngineTrack(id: '42', codec: 'srt', channels: 2),
          EngineTrack(id: '43'),
        ],
      );
      expect(result.engineId, '42');
      expect(result.trackEvidence[0].fields, {
        TrackMetadataField.language: TrackFieldComparison.missingRight,
        TrackMetadataField.codec: TrackFieldComparison.missingLeft,
        TrackMetadataField.title: TrackFieldComparison.missingBoth,
        TrackMetadataField.channels: TrackFieldComparison.same,
      });
      expect(result.trackEvidence[0].eligible, isTrue);
      expect(result.trackEvidence[1].eligible, isFalse);
      expect(
        result
            .asUnavailable(TrackMappingReason.trackWaitTimedOut)
            .trackEvidence,
        same(result.trackEvidence),
      );
    },
  );

  test('matching metadata from two candidates still rejects ambiguity', () {
    final result = _mapper.match(
      const PlaybackTrack(index: 2, type: 'Subtitle', language: 'chi'),
      const [
        EngineTrack(id: '2', language: 'zho'),
        EngineTrack(id: '42', language: 'chi'),
      ],
    );
    expect(result.engineId, isNull);
    expect(result.status, TrackMappingStatus.ambiguous);
    expect(
      result.trackEvidence.every((candidate) => candidate.eligible),
      isTrue,
    );
  });

  test(
    'plan and selected-source disagreement is separate from native comparison',
    () {
      final plan = _plan(
        sources: [
          _source([
            {
              ..._stream,
              'Language': 'eng',
              'Codec': null,
              'Title': 'changed-source-title',
            },
          ]),
        ],
      );
      final evidence = _mapper.sourceEvidence(plan, 2);
      expect(evidence.sourceLookup, TrackSourceLookup.unique);
      expect(evidence.streamLookup, TrackSourceLookup.unique);
      expect(
        evidence.planSourceFields[TrackMetadataField.language],
        TrackFieldComparison.conflict,
      );
      expect(
        evidence.planSourceFields[TrackMetadataField.codec],
        TrackFieldComparison.missingRight,
      );
      expect(
        evidence.planSourceFields[TrackMetadataField.title],
        TrackFieldComparison.conflict,
      );
      final line = _log(_mapper.match(null, []), plan: plan);
      expect(line, contains('planSourceComparisonSides=plan,selectedSource'));
      expect(line, contains('nativeSourceIdentity=unverified'));
      expect(line, isNot(contains('changed-source-title')));
    },
  );

  test(
    'selected-source lookup never picks arbitrary or ambiguous sources or streams',
    () {
      for (final entry in [
        (
          <PlaybackMediaSource>[],
          TrackSourceLookup.missing,
          TrackSourceLookup.missing,
        ),
        (
          [
            _source([_stream], id: 'different-source'),
          ],
          TrackSourceLookup.missing,
          TrackSourceLookup.missing,
        ),
        (
          [
            _source([_stream]),
            _source([_stream]),
          ],
          TrackSourceLookup.ambiguous,
          TrackSourceLookup.missing,
        ),
        ([_source([])], TrackSourceLookup.unique, TrackSourceLookup.missing),
        (
          [
            _source([_stream, _stream]),
          ],
          TrackSourceLookup.unique,
          TrackSourceLookup.ambiguous,
        ),
      ]) {
        final evidence = _mapper.sourceEvidence(_plan(sources: entry.$1), 2);
        expect(evidence.sourceLookup, entry.$2);
        expect(evidence.streamLookup, entry.$3);
      }
    },
  );

  test(
    'candidate output is bounded and arbitrary metadata values never reach logs',
    () {
      const secret =
          'https://user:password@private.example/movie?api_key=canary-token';
      final result = _mapper.match(
        const PlaybackTrack(
          index: 2,
          type: 'Subtitle',
          language: secret,
          codec: secret,
          title: secret,
          displayTitle: secret,
        ),
        [
          for (var index = 0; index < 20; index++)
            EngineTrack(
              id: '$secret-$index',
              language: 'different-$secret',
              codec: secret,
              title: secret,
            ),
        ],
      );
      final line = _log(result);
      expect(line, contains('trackEvidenceCount=16'));
      expect(line, contains('trackEvidenceOmitted=4'));
      expect(line, contains('track15='));
      expect(line, isNot(contains('track16=')));
      for (final value in [
        'canary-token',
        'private.example',
        'password',
        secret,
      ]) {
        expect(line, isNot(contains(value)));
      }
      expect(line.length, lessThan(4000));
    },
  );
}
