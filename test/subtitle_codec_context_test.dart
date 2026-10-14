import 'dart:async';

import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mapper = TrackMapper();
  const native = EngineTrack(
    id: '42',
    title: 'original',
    language: 'zho',
    codec: 'ass',
  );
  const server = PlaybackTrack(
    index: 2,
    type: 'Subtitle',
    title: 'original',
    language: 'chi',
    codec: 'ssa',
  );
  Map<String, Object?> row(EngineTrack track) => {
    'id': int.parse(track.id),
    'type': 'sub',
    'external': false,
    'title': track.title,
    'lang': track.language,
    'codec': track.codec,
  };
  SubtitleMappingContext context(List<EngineTrack> tracks) =>
      SubtitleMappingContext.fromMpv(
        demuxer: 'mkv',
        tracks: tracks.map(row).toList(),
      );

  test(
    'native Matroska SSA ASS identity matches actual ID in both directions',
    () {
      expect(
        mapper.match(server, [native], context: context([native])).engineId,
        '42',
      );
      const reverse = EngineTrack(
        id: '42',
        title: 'original',
        language: 'zho',
        codec: 'ssa',
      );
      const ass = PlaybackTrack(
        index: 2,
        type: 'Subtitle',
        title: 'original',
        language: 'chi',
        codec: 'ass',
      );
      expect(
        mapper.match(ass, [reverse], context: context([reverse])).engineId,
        '42',
      );
    },
  );

  test(
    'no context, wrong demuxer and external or unconfirmed native tracks stay strict',
    () {
      for (final ctx in [
        const SubtitleMappingContext.unknown(),
        for (final demuxer in [
          null,
          '',
          'lavf',
          'matroska',
          'mkv-private-path',
        ])
          SubtitleMappingContext.fromMpv(
            demuxer: demuxer,
            tracks: [row(native)],
          ),
        for (final external in [true, null, 'false'])
          SubtitleMappingContext.fromMpv(
            demuxer: 'mkv',
            tracks: [
              {...row(native), 'external': external},
            ],
          ),
        SubtitleMappingContext.fromMpv(
          demuxer: 'mkv',
          tracks: [row(native), row(native)],
        ),
        SubtitleMappingContext.fromMpv(demuxer: 'mkv', tracks: 'not a node'),
        SubtitleMappingContext.fromMpv(
          demuxer: 'mkv',
          tracks: [
            {...row(native), 'codec': 'ssa'},
          ],
        ),
      ]) {
        expect(
          mapper.match(server, [native], context: ctx).reason,
          TrackMappingReason.metadataConflict,
        );
      }
    },
  );

  test(
    'audio and external server subtitles never use the Matroska subtitle family',
    () {
      for (final value in [
        const PlaybackTrack(index: 2, type: 'Audio', codec: 'ssa'),
        const PlaybackTrack(
          index: 2,
          type: 'Subtitle',
          codec: 'ssa',
          isExternal: true,
        ),
      ]) {
        expect(
          mapper.match(value, [native], context: context([native])).engineId,
          isNull,
        );
      }
    },
  );

  test(
    'same family duplicates stay ambiguous and auto no cannot break ties',
    () {
      const second = EngineTrack(
        id: '8',
        title: 'original',
        language: 'zho',
        codec: 'ass',
      );
      final tracks = [
        const EngineTrack(id: 'auto'),
        native,
        const EngineTrack(id: 'no'),
        second,
      ];
      final result = mapper.match(
        server,
        tracks,
        context: context([native, second]),
      );
      expect(result.status, TrackMappingStatus.ambiguous);
      expect(result.candidateCount, 2);
      expect(result.realTrackCount, 2);
      expect(result.engineId, isNull);
    },
  );

  test(
    'family compatibility never overrides language or original title conflicts',
    () {
      for (final track in [
        const EngineTrack(
          id: '42',
          title: 'different',
          language: 'zho',
          codec: 'ass',
        ),
        const EngineTrack(
          id: '42',
          title: 'original',
          language: 'eng',
          codec: 'ass',
        ),
      ]) {
        final result = mapper.match(server, [track], context: context([track]));
        expect(result.reason, TrackMappingReason.metadataConflict);
        expect(
          result.conflictFields,
          isNot(contains(TrackMetadataField.codec)),
        );
        expect(result.engineId, isNull);
      }
    },
  );

  test(
    'ASS SubRip, PGS spelling guesses and different unknown codecs stay conflicting',
    () {
      for (final pair in [
        ('ass', 'subrip'),
        ('pgs', 'hdmv_pgs_subtitle'),
        ('unknown-a', 'unknown-b'),
        ('ass', 'unknown-a'),
      ]) {
        final track = EngineTrack(id: '42', language: 'zho', codec: pair.$2);
        final result = mapper.match(
          PlaybackTrack(
            index: 2,
            type: 'Subtitle',
            language: 'chi',
            codec: pair.$1,
          ),
          [track],
          context: context([track]),
        );
        expect(result.reason, TrackMappingReason.metadataConflict);
        expect(result.engineId, isNull);
      }
    },
  );

  test(
    'missing codecs give no identity evidence; existing matching fields still work',
    () {
      const empty = EngineTrack(id: '42');
      expect(
        mapper.match(const PlaybackTrack(index: 2, type: 'Subtitle'), [
          empty,
        ], context: context([empty])).reason,
        TrackMappingReason.insufficientMetadata,
      );
      expect(
        mapper.match(server, [
          const EngineTrack(id: '42', language: 'zho'),
        ]).engineId,
        '42',
      );
    },
  );

  test(
    'native context read is bounded, failure-safe and input-generation bound',
    () async {
      var current = true;
      var reads = 0;
      final gate = Completer<Object?>();
      final pending = SubtitleMappingContext.readMpv(
        readDemuxer: () async => 'mkv',
        readTracks: () {
          reads++;
          return gate.future;
        },
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, 1);
      current = false;
      gate.complete([row(native)]);
      expect((await pending).isMpvMatroskaEmbedded(native), isFalse);

      for (final failingRead in <Future<Object?> Function()>[
        () async => throw StateError('private-path?token=canary'),
        () => Completer<Object?>().future,
      ]) {
        final result = await SubtitleMappingContext.readMpv(
          readDemuxer: () async => 'mkv',
          readTracks: failingRead,
          isCurrent: () => true,
          timeout: const Duration(milliseconds: 5),
        );
        expect(result.isMpvMatroskaEmbedded(native), isFalse);
      }
      final good = await SubtitleMappingContext.readMpv(
        readDemuxer: () async => 'mkv',
        readTracks: () async => [row(native)],
        isCurrent: () => true,
      );
      expect(good.isMpvMatroskaEmbedded(native), isTrue);
    },
  );

  test(
    'native snapshot must match every field and cannot infer embedded status',
    () {
      for (final change in <Map<String, Object?>>[
        {'id': 9},
        {'id': '42'},
        {'id': 0},
        {'type': 'audio'},
        {'title': 'stale'},
        {'lang': 'eng'},
        {'codec': null},
        {'title': 1},
      ]) {
        final ctx = SubtitleMappingContext.fromMpv(
          demuxer: 'mkv',
          tracks: [
            {...row(native), ...change},
          ],
        );
        expect(ctx.isMpvMatroskaEmbedded(native), isFalse);
      }
    },
  );

  test(
    'unsupported demuxer and late timed-out reads never inspect track metadata',
    () async {
      var trackReads = 0;
      Future<Object?> readTracks() async {
        trackReads++;
        return [row(native)];
      }

      for (final demuxer in [null, '', 'lavf', 'private-mkv-path']) {
        final result = await SubtitleMappingContext.readMpv(
          readDemuxer: () async => demuxer,
          readTracks: readTracks,
          isCurrent: () => true,
        );
        expect(result.isMpvMatroskaEmbedded(native), isFalse);
      }
      final gate = Completer<String?>();
      final result = await SubtitleMappingContext.readMpv(
        readDemuxer: () => gate.future,
        readTracks: readTracks,
        isCurrent: () => true,
        timeout: const Duration(milliseconds: 5),
      );
      expect(result.isMpvMatroskaEmbedded(native), isFalse);
      gate.complete('mkv');
      await Future<void>.delayed(Duration.zero);
      expect(trackReads, 0);
    },
  );
}
