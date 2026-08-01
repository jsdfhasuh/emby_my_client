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

  test('prefers exact mpv track ID then a unique metadata match', () {
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
      '2',
    );
    expect(
      mapper.engineTrackId(server, const [
        EngineTrack(id: '7', language: 'eng', codec: 'aac'),
        EngineTrack(id: '8', language: 'jpn', codec: 'aac'),
      ]),
      '7',
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
