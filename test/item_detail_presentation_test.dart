import 'package:emby_my_client/library/item_detail_presentation.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ambient detail layout is limited to large iPad landscape', () {
    expect(
      usesAmbientIPadDetailLayout(
        PlatformCapabilities.ipad,
        const Size(1024, 768),
      ),
      isTrue,
    );
    expect(
      usesAmbientIPadDetailLayout(
        PlatformCapabilities.ipad,
        const Size(1366, 1024),
      ),
      isTrue,
    );
    expect(
      usesAmbientIPadDetailLayout(
        PlatformCapabilities.ipad,
        const Size(768, 1024),
      ),
      isFalse,
    );
    expect(
      usesAmbientIPadDetailLayout(
        PlatformCapabilities.ipad,
        const Size(844, 390),
      ),
      isFalse,
    );
    expect(
      usesAmbientIPadDetailLayout(
        PlatformCapabilities.android,
        const Size(1024, 768),
      ),
      isFalse,
    );
  });

  test('estimated finish subtracts resume position and clamps at now', () {
    final now = DateTime(2026, 8, 9, 10);
    final resumed = _item(
      runTimeTicks: 72000000000,
      userData: const EmbyUserData(playbackPositionTicks: 18000000000),
    );
    expect(estimatedPlaybackEndAt(resumed, now), DateTime(2026, 8, 9, 11, 30));

    final beyondEnd = _item(
      runTimeTicks: 600000000,
      userData: const EmbyUserData(playbackPositionTicks: 1200000000),
    );
    expect(estimatedPlaybackEndAt(beyondEnd, now), now);
    expect(estimatedPlaybackEndAt(_item(), now), isNull);
  });

  test(
    'technical details select the first playable source and default audio',
    () {
      final item = _item(
        mediaSources: [
          _source(id: 'unplayable', name: 'Wrong version', container: 'avi'),
          _source(
            id: 'playable',
            name: 'Main version',
            container: 'mkv',
            bitrate: 8500000,
            playable: true,
            defaultAudioStreamIndex: 3,
            streams: const [
              {
                'Index': 2,
                'Type': 'Audio',
                'Codec': 'aac',
                'Channels': 2,
                'Language': 'eng',
                'IsDefault': true,
              },
              {
                'Index': 0,
                'Type': 'Video',
                'Codec': 'h264',
                'Width': 1920,
                'Height': 1080,
              },
              {
                'Index': 3,
                'Type': 'Audio',
                'Codec': 'eac3',
                'ChannelLayout': '5.1',
                'Language': 'zho',
              },
            ],
          ),
        ],
      );

      final presentation = technicalPresentationForItem(item);
      expect(presentation.source, 'Main version');
      expect(presentation.container, 'MKV');
      expect(presentation.video, 'H264 · 1920×1080');
      expect(presentation.audio, 'EAC3 · 5.1 · zho');
      expect(presentation.bitrate, '8.5 Mbps');
    },
  );

  test('audio selection falls back to IsDefault and then first audio', () {
    final markedDefault = technicalPresentationForItem(
      _item(
        mediaSources: [
          _source(
            id: 'source',
            playable: true,
            streams: const [
              {'Index': 1, 'Type': 'Audio', 'Codec': 'aac'},
              {'Index': 2, 'Type': 'Audio', 'Codec': 'opus', 'IsDefault': true},
            ],
          ),
        ],
      ),
    );
    expect(markedDefault.audio, 'OPUS');

    final first = technicalPresentationForItem(
      _item(
        mediaSources: [
          _source(
            id: 'source',
            playable: true,
            streams: const [
              {'Index': 4, 'Type': 'Audio', 'Codec': 'flac'},
              {'Index': 5, 'Type': 'Audio', 'Codec': 'aac'},
            ],
          ),
        ],
      ),
    );
    expect(first.audio, 'FLAC');
  });

  test('missing technical fields stay hidden', () {
    final presentation = technicalPresentationForItem(
      _item(mediaSources: [_source(id: 'source', playable: true)]),
    );

    expect(presentation.isEmpty, isTrue);
    expect(presentation.facts, isEmpty);
  });
}

PlaybackMediaSource _source({
  required String id,
  String? name,
  String? container,
  int? bitrate,
  int? defaultAudioStreamIndex,
  bool playable = false,
  List<Map<String, dynamic>> streams = const [],
}) => PlaybackMediaSource(
  id: id,
  name: name,
  container: container,
  bitrate: bitrate,
  defaultAudioStreamIndex: defaultAudioStreamIndex,
  supportsDirectPlay: playable,
  supportsDirectStream: false,
  supportsTranscoding: false,
  mediaStreams: streams,
  transcodingReasons: const [],
);

EmbyItem _item({
  int? runTimeTicks,
  EmbyUserData userData = const EmbyUserData(),
  List<PlaybackMediaSource> mediaSources = const [],
}) => EmbyItem(
  id: 'media-1',
  name: 'Test media',
  type: 'Movie',
  mediaType: 'Video',
  runTimeTicks: runTimeTicks,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: userData,
  mediaSources: mediaSources,
);
