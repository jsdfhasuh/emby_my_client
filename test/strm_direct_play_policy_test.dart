import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/strm_direct_play_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('A03 A17 A19 regular evidence is tied to the selected source', () {
    final a = _source('a', path: '/media/a.mkv', protocol: 'File');
    final b = _source('b', path: '/media/b.strm', protocol: 'File');
    final detail = _detail([a, b]);
    expect(
      StrmDirectPlayPolicy.classify(a, freshDetail: detail),
      SourceClassification.confirmedRegular,
    );
    expect(
      StrmDirectPlayPolicy.classify(b, freshDetail: detail),
      SourceClassification.confirmedStrm,
    );
    expect(
      StrmDirectPlayPolicy.classify(_source('a', container: 'mp4')),
      SourceClassification.unknown,
    );
  });

  test('A02 top-level STRM is not propagated to every version', () {
    final a = _source('a');
    final b = _source('b');
    expect(
      StrmDirectPlayPolicy.classify(
        a,
        freshDetail: _detail([a, b], path: '/media/item.strm'),
      ),
      SourceClassification.unknown,
    );
    expect(
      StrmDirectPlayPolicy.classify(
        a,
        freshDetail: _detail([a], path: '/media/item.strm'),
      ),
      SourceClassification.confirmedStrm,
    );
    expect(
      StrmDirectPlayPolicy.classify(
        _source(
          'a',
          path: 'https://source.invalid/movie.mp4',
          container: 'mp4',
        ),
        previous: SourceClassification.confirmedStrm,
      ),
      SourceClassification.confirmedStrm,
    );
  });

  for (final extension in StrmDirectPlayPolicy.regularExtensions) {
    test('A17 positive File evidence accepts $extension', () {
      final a = _source('a', protocol: 'File');
      expect(
        StrmDirectPlayPolicy.classify(
          a,
          freshDetail: _detail([a], path: 'C:\\media\\movie.$extension'),
        ),
        SourceClassification.confirmedRegular,
      );
    });
  }

  test('A04 A18 fixed source survives order and support flag changes', () {
    final a = _source('a', direct: true);
    final b = _source('b', container: 'strm');
    final chosen = StrmDirectPlayPolicy.selectOnce([a, b]);
    final next = StrmDirectPlayPolicy.fixedSource([b, _source('a')], chosen.id);
    expect(next.id, 'a');
    expect(
      () => StrmDirectPlayPolicy.fixedSource([b], chosen.id),
      _failure(PlaybackResolveFailure.sourceMissing),
    );
    expect(
      () => StrmDirectPlayPolicy.selectOnce([a, a]),
      _failure(PlaybackResolveFailure.sourceIdentityConflict),
    );
    expect(
      () => StrmDirectPlayPolicy.selectOnce([_source('')]),
      _failure(PlaybackResolveFailure.sourceIdentityUnresolved),
    );
  });

  test(
    'A09 every compatibility payload keeps flags, source and disabled intent',
    () {
      final bodies = StrmDirectPlayPolicy.strictPayloads(
        userId: 'user',
        deviceProfile: const {},
        mediaSourceId: 'b',
        subtitleStreamIndex: 3,
        subtitleDisabled: true,
      );
      expect(bodies, hasLength(3));
      for (final body in bodies) {
        expect(body['EnableDirectPlay'], isTrue);
        expect(body['EnableDirectStream'], isFalse);
        expect(body['EnableTranscoding'], isFalse);
        expect(body['AutoOpenLiveStream'], isFalse);
        expect(body['MediaSourceId'], 'b');
        expect(body['SubtitleStreamIndex'], -1);
        expect(() => body['EnableTranscoding'] = true, throwsUnsupportedError);
      }
      expect(
        () => StrmDirectPlayPolicy.requireDirectRequest(forceTranscode: true),
        _failure(PlaybackResolveFailure.invalidSourceRequest),
      );
    },
  );

  test('A12 A13 error responses are not overridden by valid-looking paths', () {
    for (final error in {
      'NotAllowed': PlaybackResolveFailure.serverDenied,
      'RateLimitExceeded': PlaybackResolveFailure.rateLimited,
      'NoCompatibleStream': PlaybackResolveFailure.noCompatibleStream,
      'Other': PlaybackResolveFailure.serverError,
    }.entries) {
      expect(
        () => StrmDirectPlayPolicy.checkError(error.key),
        _failure(error.value),
      );
    }
  });

  test(
    'A06 request stores exact raw signature syntax; this is not native proof',
    () {
      const raw =
          'https://source.invalid/a%2fb.mp4?x=1&x=2&empty=&api_key=upstream&q=a+b&q=a%20b&sig=%7e%2f';
      final request = _request(raw);
      expect(request.rawUrl, raw);
      expect(request.toString(), isNot(contains('source.invalid')));
      expect(request.toString(), isNot(contains('sig')));
    },
  );

  test('A07 LAN is permitted regardless of IsRemote', () {
    expect(_request('http://192.168.1.8:5244/d/movie.mp4').headers, isEmpty);
  });

  for (final raw in [
    'file:///movie.mp4',
    r'C:\media\movie.mp4',
    '/movie.mp4',
    'https://user:pass@source.invalid/movie.mp4',
    'https://source.invalid/movie.strm',
    'http://localhost/movie',
    'http://127.0.0.1/movie',
    'http://0.0.0.0/movie',
    'http://[::1]/movie',
    'http://[::]/movie',
    'http://[::ffff:127.0.0.1]/movie',
    'http://127.1/movie',
    'http://2130706433/movie',
    'https://source.invalid/a\r\nb',
    'https://emby.invalid/emby/Videos/item/stream.mp4',
    'https://emby.invalid/emby/Items/item/Download',
  ]) {
    test('A05 A08 rejects invalid destination fixture ${raw.hashCode}', () {
      expect(
        () => _request(raw),
        _failure(PlaybackResolveFailure.invalidSourceRequest),
      );
    });
  }

  test('A20 rejects rather than drops invalid required headers', () {
    for (final headers in <Map<String, String>>[
      {'Host': 'other'},
      {'Range': 'bytes=1-'},
      {'X-Emby-Token': 'fixture'},
      {'Cookie': 'a', 'cookie': 'b'},
      {'X-Key': 'a\r\nb'},
      {'Bad Name': 'a'},
      {'Connection': 'close'},
      {'Content-Length': '1'},
    ]) {
      expect(
        () => _request('https://source.invalid/movie', headers: headers),
        _failure(PlaybackResolveFailure.invalidSourceRequest),
      );
    }
    final headers = {'Authorization': 'fixture', 'User-Agent': 'fixture'};
    final request = _request('https://source.invalid/movie', headers: headers);
    headers.clear();
    expect(request.headers, hasLength(2));
    expect(() => request.headers.clear(), throwsUnsupportedError);
  });

  test(
    'A14 A15 snapshot atomically replaces URL, headers and source metadata',
    () {
      final first = _snapshot(
        _source(
          'a',
          path: 'https://source.invalid/old',
          headers: {'Cookie': 'fixture'},
        ),
      );
      final next = _snapshot(_source('a', path: 'https://source.invalid/new'));
      expect(first.request.headers, isNotEmpty);
      expect(next.request.headers, isEmpty);
      expect(next.request.rawUrl, 'https://source.invalid/new');
      expect(next.duration, isNull);
      expect(next.mediaStreams, isEmpty);
      expect(() => next.mediaStreams.add({}), throwsUnsupportedError);
    },
  );

  test('A16 excludes server-owned or infinite sources', () {
    for (final field in [
      'RequiresOpening',
      'IsInfiniteStream',
      'OpenToken',
      'LiveStreamId',
    ]) {
      final source = PlaybackMediaSource.fromJson({
        'Id': 'a',
        'Path': 'https://source.invalid/movie',
        field: field.endsWith('Token') || field.endsWith('Id')
            ? 'fixture'
            : true,
      });
      expect(
        () => _snapshot(source),
        _failure(PlaybackResolveFailure.sourceRequiresOpening),
      );
    }
  });

  test('B14 B15 session and task identity isolates identical media IDs', () {
    final api = Object();
    final task = Object();
    final first = _identity(api: api, task: task);
    expect(first.sameAttempt(_identity(api: api, task: task)), isTrue);
    expect(first.sameSource(_identity(api: Object(), task: task)), isFalse);
    expect(first.sameSource(_identity(api: api, task: Object())), isFalse);
    expect(
      first.sameSource(_identity(api: api, task: task, generation: 2)),
      isTrue,
    );
    expect(
      first.sameAttempt(_identity(api: api, task: task, generation: 2)),
      isFalse,
    );
  });

  test('C01 unverified evidence never authorizes a native open', () {
    expect(
      () => const NativeSourceRequestEvidence().requireControlledProgressive(),
      _failure(PlaybackResolveFailure.nativeRequestPolicyUnsupported),
    );
  });
}

Matcher _failure(PlaybackResolveFailure failure) => throwsA(
  isA<PlaybackResolveException>().having(
    (error) => error.failure,
    'failure',
    failure,
  ),
);

PlaybackMediaSource _source(
  String id, {
  String? path,
  String? protocol,
  String? container,
  bool direct = false,
  Map<String, String> headers = const {},
}) => PlaybackMediaSource.fromJson({
  'Id': id,
  'Path': path,
  'Protocol': protocol,
  'Container': container,
  'SupportsDirectPlay': direct,
  'RequiredHttpHeaders': headers,
});

EmbyItem _detail(List<PlaybackMediaSource> sources, {String? path}) =>
    EmbyItem.fromJson({
      'Id': 'item',
      'Path': path,
      'MediaSources': sources
          .map(
            (source) => {
              'Id': source.id,
              'Path': source.path,
              'Protocol': source.protocol,
              'Container': source.container,
            },
          )
          .toList(),
    });

PlaybackResourceIdentity _identity({
  Object? api,
  Object? task,
  int generation = 1,
}) => PlaybackResourceIdentity(
  scope: const ServerScope(serverId: 'server', userId: 'user'),
  apiSession: api ?? Object(),
  itemId: 'item',
  sourceId: 'a',
  itemSession: task ?? Object(),
  generation: generation,
);

PlaybackResourceRequest _request(
  String raw, {
  Map<String, String> headers = const {},
}) => PlaybackResourceRequest(
  rawUrl: raw,
  headers: headers,
  identity: _identity(),
  embyServer: Uri.parse('https://emby.invalid/emby'),
);

SelectedSourceSnapshot _snapshot(PlaybackMediaSource source) =>
    SelectedSourceSnapshot(
      source: source,
      identity: _identity(),
      embyServer: Uri.parse('https://emby.invalid/emby'),
      playSessionId: null,
    );
