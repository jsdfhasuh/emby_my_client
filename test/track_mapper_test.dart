import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mapper = TrackMapper();

  test('maps typed Emby audio and subtitle metadata', () {
    final plan = _plan([
      {
        'Index': 1,
        'Type': 'Audio',
        'DisplayTitle': 'English 5.1',
        'Language': 'eng',
        'Codec': 'aac',
        'Channels': 6,
        'IsDefault': true,
      },
      {
        'Index': 3,
        'Type': 'Subtitle',
        'DisplayTitle': 'Chinese',
        'Language': 'chi',
        'Codec': 'srt',
        'IsExternal': true,
        'DeliveryUrl': '/Videos/item/Subtitles/3/Stream.srt',
      },
    ]);

    final audio = mapper.fromPlan(plan, 'audio').single;
    final subtitle = mapper.fromPlan(plan, 'subtitle').single;

    expect(audio.title, 'English 5.1');
    expect(audio.channels, 6);
    expect(audio.isDefault, isTrue);
    expect(subtitle.isExternal, isTrue);
    expect(subtitle.deliveryUrl, contains('/Subtitles/3/'));
  });

  test('requires positive metadata even when numeric track IDs match', () {
    const server = PlaybackTrack(
      index: 2,
      type: 'Audio',
      language: 'eng',
      codec: 'aac',
    );

    expect(
      mapper.engineTrackId(server, const [
        EngineTrack(id: '2'),
        EngineTrack(id: '9'),
      ]),
      isNull,
    );
    expect(
      mapper.engineTrackId(server, const [
        EngineTrack(id: '7', language: 'eng', codec: 'aac'),
        EngineTrack(id: '8', language: 'jpn', codec: 'aac'),
      ]),
      '7',
    );
  });

  test('B02 numeric coincidence cannot override a language conflict', () {
    const server = PlaybackTrack(index: 2, type: 'Audio', language: 'chi');
    final result = mapper.match(server, const [
      EngineTrack(id: '2', language: 'eng'),
      EngineTrack(id: '5', language: 'zho'),
    ]);
    expect(result.status, TrackMappingStatus.matched);
    expect(result.engineId, '5');
  });

  test('B03 absent and ambiguous metadata are distinct failures', () {
    const server = PlaybackTrack(index: 2, type: 'Audio', language: 'chi');
    expect(
      mapper.match(server, const [EngineTrack(id: '2')]).status,
      TrackMappingStatus.unavailable,
    );
    expect(
      mapper.match(server, const [
        EngineTrack(id: '2', language: 'chi'),
        EngineTrack(id: '5', language: 'zh'),
      ]).status,
      TrackMappingStatus.ambiguous,
    );
    expect(
      mapper.engineTrackId(server, const [
        EngineTrack(id: 'auto', language: 'chi'),
        EngineTrack(id: 'no', language: 'chi'),
      ]),
      isNull,
    );
  });
}

PlaybackPlan _plan(List<Map<String, dynamic>> streams) => PlaybackPlan(
  uri: Uri.parse('https://media.example.test/video'),
  mediaSourceId: 'source',
  playSessionId: 'session',
  method: PlayMethod.directPlay,
  usesServerAuthentication: true,
  mediaStreams: streams,
  transcodingReasons: const [],
  availableMediaSources: const [],
);
