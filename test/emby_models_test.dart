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
      'Genres': ['剧情'],
      'Tags': ['高码率'],
      'ImageTags': {'Primary': 'image-tag'},
      'UserData': {
        'PlaybackPositionTicks': 9000000000,
        'PlayedPercentage': 25,
        'UnplayedItemCount': 12,
      },
    });

    expect(item.isPlayable, isTrue);
    expect(item.subtitle, 'S01E02 · Sample Show');
    expect(item.runtimeLabel, '1 小时 0 分钟');
    expect(item.resumePosition, const Duration(minutes: 15));
    expect(item.progress, 0.25);
    expect(item.userData.unplayedItemCount, 12);
    expect(item.genres, ['剧情']);
    expect(item.tags, ['高码率']);
  });

  test(
    'parses and copies UserData PlayCount without regressing other fields',
    () {
      final parsed = EmbyUserData.fromJson(const {
        'PlayCount': '7',
        'PlaybackPositionTicks': 900,
        'PlayedPercentage': 25,
        'Played': true,
        'IsFavorite': true,
        'UnplayedItemCount': 3,
      });

      expect(const EmbyUserData().playCount, 0);
      expect(parsed.playCount, 7);
      expect(parsed.playbackPositionTicks, 900);
      expect(parsed.playedPercentage, 25);
      expect(parsed.isPlayed, isTrue);
      expect(parsed.isFavorite, isTrue);
      expect(parsed.unplayedItemCount, 3);
      expect(parsed.copyWith().playCount, 7);
      expect(parsed.copyWith(playCount: 11).playCount, 11);
    },
  );

  group('people parsing', () {
    test('parses cast fields, preserves order, and deduplicates people', () {
      final item = EmbyItem.fromJson({
        'Id': 'movie-1',
        'Name': 'Movie',
        'Type': 'Movie',
        'People': [
          {
            'Id': 'person-1',
            'Name': '演员一',
            'Type': 'Actor',
            'Role': '主角',
            'PrimaryImageTag': 'tag-1',
          },
          {'Name': '客串演员', 'Type': 'GuestStar', 'Role': '客串角色'},
          {'Id': 'person-1', 'Name': '重复演员', 'Type': 'Actor'},
          {'Name': '  客串演员  ', 'Type': ' gueststar ', 'Role': '  客串角色 '},
          {'Id': 'director-1', 'Name': '导演', 'Type': 'Director'},
          {'Name': '   ', 'Type': 'Actor'},
          'invalid-entry',
        ],
      });

      expect(item.people, hasLength(3));
      expect(item.people.map((person) => person.name), ['演员一', '客串演员', '导演']);
      expect(item.people.first.id, 'person-1');
      expect(item.people.first.role, '主角');
      expect(item.people.first.primaryImageTag, 'tag-1');
      expect(item.people.first.isNavigable, isTrue);
      expect(item.people[1].isCast, isTrue);
      expect(item.people[1].isNavigable, isFalse);
      expect(item.people.last.isCast, isFalse);
    });

    test('ignores malformed people payloads and malformed fields', () {
      for (final people in [null, const {}, 'invalid']) {
        final item = EmbyItem.fromJson({'People': people});
        expect(item.people, isEmpty);
      }

      final item = EmbyItem.fromJson({
        'People': [
          {
            'Name': '演员',
            'Type': 7,
            'Id': 9,
            'Role': const [],
            'PrimaryImageTag': const {},
          },
          {'Name': 42, 'Type': 'Actor'},
        ],
      });

      expect(item.people, hasLength(1));
      expect(item.people.single.name, '演员');
      expect(item.people.single.type, isEmpty);
      expect(item.people.single.id, isNull);
      expect(item.people.single.role, isNull);
      expect(item.people.single.primaryImageTag, isNull);
    });

    test('deduplicates anonymous people by normalized type name and role', () {
      final item = EmbyItem.fromJson({
        'People': [
          {'Name': 'Actor  Name', 'Type': 'Actor', 'Role': 'Lead Role'},
          {'Name': ' actor name ', 'Type': ' actor ', 'Role': ' lead   role '},
          {'Name': 'Actor Name', 'Type': 'Actor', 'Role': 'Other Role'},
        ],
      });

      expect(item.people, hasLength(2));
    });

    test('prefers a later cast record without changing the first position', () {
      final item = EmbyItem.fromJson({
        'People': [
          {'Id': 'person-1', 'Name': '导演记录', 'Type': 'Director'},
          {'Id': 'person-2', 'Name': '另一演员', 'Type': 'Actor'},
          {'Id': 'person-1', 'Name': '演员记录', 'Type': 'Actor', 'Role': '主角'},
        ],
      });

      expect(item.people.map((person) => person.id), ['person-1', 'person-2']);
      expect(item.people.first.name, '演员记录');
      expect(item.people.first.type, 'Actor');
      expect(item.people.first.role, '主角');
      expect(
        item.people.where((person) => person.id == 'person-1'),
        hasLength(1),
      );
    });

    test('fills a missing image tag from a later record with the same ID', () {
      final item = EmbyItem.fromJson({
        'People': [
          {'Id': 'person-1', 'Name': '演员一', 'Type': 'Actor'},
          {
            'Id': 'person-1',
            'Name': '演员一',
            'Type': 'Writer',
            'PrimaryImageTag': 'later-image-tag',
          },
        ],
      });

      expect(item.people, hasLength(1));
      expect(item.people.single.type, 'Actor');
      expect(item.people.single.primaryImageTag, 'later-image-tag');
    });

    test('does not fill a cast role from a non-cast record', () {
      final item = EmbyItem.fromJson({
        'People': [
          {'Id': 'person-1', 'Name': '演员记录', 'Type': 'Actor'},
          {'Id': 'person-1', 'Name': '编剧记录', 'Type': 'Writer', 'Role': '编剧职务'},
        ],
      });

      expect(item.people.single.type, 'Actor');
      expect(item.people.single.role, isNull);
    });

    test('uses the cast role when a non-cast record appears first', () {
      final item = EmbyItem.fromJson({
        'People': [
          {
            'Id': 'person-1',
            'Name': '导演记录',
            'Type': 'Director',
            'Role': '导演职务',
          },
          {'Id': 'person-1', 'Name': '演员记录', 'Type': ' actor ', 'Role': '演员角色'},
        ],
      });

      expect(item.people.single.name, '演员记录');
      expect(item.people.single.type, 'actor');
      expect(item.people.single.role, '演员角色');
    });

    test('recognizes normalized cast types and merge priority', () {
      final actor = EmbyPerson.fromJson(const {
        'Name': '小写演员',
        'Type': ' actor ',
      });
      final guestStar = EmbyPerson.fromJson(const {
        'Name': '小写客串',
        'Type': 'GUESTSTAR',
      });
      final item = EmbyItem.fromJson({
        'People': [
          {'Id': 'person-1', 'Name': '导演记录', 'Type': 'Director'},
          {
            'Id': 'person-1',
            'Name': '客串记录',
            'Type': ' gueststar ',
            'Role': '客串角色',
          },
        ],
      });

      expect(actor?.isCast, isTrue);
      expect(guestStar?.isCast, isTrue);
      expect(item.people.single.name, '客串记录');
      expect(item.people.single.isCast, isTrue);
      expect(item.people.single.role, '客串角色');
    });
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

  test('classifies STRM items from item and media source metadata', () {
    final itemPath = EmbyItem.fromJson({
      'Id': 'movie-1',
      'Name': 'Movie',
      'Type': 'Movie',
      'Path': r'D:\Media\Movie.STRM',
    });
    final sourceContainer = EmbyItem.fromJson({
      'Id': 'movie-2',
      'Name': 'Movie 2',
      'Type': 'Movie',
      'MediaSources': [
        {
          'Id': 'source-1',
          'Path': 'https://media.example.test/video',
          'Container': 'STRM',
        },
      ],
    });
    final regular = EmbyItem.fromJson({
      'Id': 'movie-3',
      'Name': 'Movie 3',
      'Type': 'Movie',
      'Path': '/media/movie.mkv',
      'Container': 'mkv',
    });

    expect(itemPath.isStrm, isTrue);
    expect(sourceContainer.isStrm, isTrue);
    expect(regular.isStrm, isFalse);
  });

  test('parses media source runtime ticks for playback planning', () {
    final source = PlaybackMediaSource.fromJson(const {
      'Id': 'source-1',
      'SupportsDirectPlay': true,
      'RunTimeTicks': 900000000,
    });

    expect(source.runTimeTicks, 900000000);
  });

  test('accepts positive media source sizes and rejects unsafe values', () {
    for (final entry in <Object?, int?>{
      123: 123,
      '456': 456,
      null: null,
      0: null,
      -1: null,
      '-2': null,
      '9223372036854775808': null,
      'not-a-size': null,
      1.5: null,
      double.nan: null,
    }.entries) {
      final source = PlaybackMediaSource.fromJson({
        'Id': 'source-1',
        'SupportsDirectPlay': true,
        'Size': entry.key,
      });
      expect(source.size, entry.value, reason: '${entry.key}');
    }
  });

  test('diagnostic logs redact network URLs and Emby credentials', () {
    const token = 'c608e7499c5e4df19de4f0951ef6fce9';
    final redacted = DiagnosticLog.redact(
      'http://server/stream?api_key=$token '
      'wss://server/socket?api_key=$token '
      'https%3A%2F%2Fserver%2Fencoded%3Fapi_key%3D$token '
      'X-Emby-Token=$token X-Emby-Token: $token Token="$token"',
    );

    expect(redacted, isNot(contains(token)));
    expect(redacted, isNot(contains('server')));
    expect('<redacted-url>'.allMatches(redacted), hasLength(3));
    expect(redacted, contains('X-Emby-Token=<redacted>'));
    expect(redacted, contains('X-Emby-Token: <redacted>'));
    expect(redacted, contains('Token="<redacted>"'));
  });

  test('diagnostic logs redact usernames and media titles', () {
    final redacted = DiagnosticLog.redact(
      'Authenticated user private-user\n'
      'Selected DirectPlay source=source-1 '
      'name=Private Media Title container=mp4 bitrate=1234',
    );

    expect(redacted, isNot(contains('private-user')));
    expect(redacted, isNot(contains('Private Media Title')));
    expect(redacted, contains('Authenticated user <redacted>'));
    expect(redacted, contains('name=<redacted> container=mp4'));
  });
}
