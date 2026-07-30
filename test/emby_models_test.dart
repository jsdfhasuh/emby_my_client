import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('server URL normalization', () {
    test('adds a default HTTP scheme and removes a trailing slash', () {
      expect(
        EmbyApi.normalizeServerUrl('192.168.1.10:8096/'),
        'http://192.168.1.10:8096',
      );
    });

    test('accepts a pasted Emby web URL', () {
      expect(
        EmbyApi.normalizeServerUrl(
          'https://media.example.com/emby/web/index.html#!/home',
        ),
        'https://media.example.com/emby',
      );
    });

    test('rejects unsupported schemes', () {
      expect(
        () => EmbyApi.normalizeServerUrl('ftp://media.example.com'),
        throwsA(isA<EmbyApiException>()),
      );
    });
  });

  test('parses an episode and converts Emby ticks', () {
    final item = EmbyItem.fromJson({
      'Id': 'episode-1',
      'Name': 'Pilot',
      'Type': 'Episode',
      'MediaType': 'Video',
      'SeriesName': 'Sample Show',
      'ParentIndexNumber': 1,
      'IndexNumber': 2,
      'RunTimeTicks': 36000000000,
      'ImageTags': {'Primary': 'image-tag'},
      'UserData': {'PlaybackPositionTicks': 9000000000, 'PlayedPercentage': 25},
    });

    expect(item.isPlayable, isTrue);
    expect(item.subtitle, 'S01E02 · Sample Show');
    expect(item.runtimeLabel, '1 小时 0 分钟');
    expect(item.resumePosition, const Duration(minutes: 15));
    expect(item.progress, 0.25);
  });

  test('parses intro and credits chapter markers', () {
    final item = EmbyItem.fromJson({
      'Id': 'episode-1',
      'Name': 'Pilot',
      'Type': 'Episode',
      'Chapters': [
        {
          'Name': 'Intro Start',
          'StartPositionTicks': 300000000,
          'MarkerType': 'IntroStart',
        },
        {
          'Name': 'Credits',
          'StartPositionTicks': 33000000000,
          'MarkerType': 'CreditsStart',
        },
      ],
    });

    expect(item.chapters, hasLength(2));
    expect(item.chapters.first.position, const Duration(seconds: 30));
    expect(item.chapters.last.markerType, 'CreditsStart');
  });

  test('parses a Trickplay sprite layout by media source', () {
    final item = EmbyItem.fromJson({
      'Id': 'episode-1',
      'Name': 'Pilot',
      'Type': 'Episode',
      'Trickplay': {
        'source-1': {
          '320': {
            'Width': 320,
            'Height': 180,
            'TileWidth': 10,
            'TileHeight': 10,
            'Interval': 10000,
          },
        },
      },
    });

    final info = item.trickplay?.resolutionFor('source-1');
    expect(info?.width, 320);
    expect(info?.height, 180);
    expect(info?.tilesPerImage, 100);
    expect(info?.intervalMilliseconds, 10000);
  });

  test('diagnostic logs redact Emby credentials', () {
    const token = 'c608e7499c5e4df19de4f0951ef6fce9';
    final redacted = DiagnosticLog.redact(
      'http://server/stream?api_key=$token '
      'X-Emby-Token=$token X-Emby-Token: $token Token="$token"',
    );

    expect(redacted, isNot(contains(token)));
    expect(redacted, contains('api_key=<redacted>'));
    expect(redacted, contains('X-Emby-Token=<redacted>'));
    expect(redacted, contains('X-Emby-Token: <redacted>'));
    expect(redacted, contains('Token="<redacted>"'));
  });
}
