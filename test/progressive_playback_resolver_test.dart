import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:flutter_test/flutter_test.dart';

const _session = EmbySession(
  serverUrl: 'https://emby.example.test/base',
  serverName: 'fixture',
  serverId: 'server',
  userId: 'user',
  username: 'fixture',
  accessToken: 'fixture-token',
  deviceId: 'device',
);
final _item = EmbyItem.fromJson({'Id': 'item', 'Type': 'Movie'});

Map<String, dynamic> _source({
  String id = 'source-a',
  String container = 'mkv',
}) => {
  'Id': id,
  'Protocol': 'File',
  'Path': '/media/movie.$container',
  'Container': container,
  'RunTimeTicks': 36000000000,
  'Size': 128 * 1024 * 1024,
  'SupportsDirectPlay': true,
  'SupportsDirectStream': true,
  'SupportsTranscoding': true,
  'DirectStreamUrl': '/Videos/item/stream.$container?MediaSourceId=$id',
  'TranscodingUrl': '/Videos/item/master.m3u8?MediaSourceId=$id',
};

void main() {
  for (final container in [
    'mp4',
    'm4v',
    'mov',
    'mkv',
    'matroska',
    'avi',
    'ts',
    'mpegts',
  ]) {
    test(
      'finite $container server plan gains optional controlled input',
      () async {
        final fixture = _ResolverFixture([_source(container: container)]);

        final plan = await fixture.resolver.resolve(
          _item,
          subtitleDisabled: true,
        );

        final request = plan.progressiveRequest!;
        expect(plan.isSourceDirect, isFalse);
        expect(plan.sourceRequest, isNull);
        expect(plan.routeKind, PlaybackRouteKind.serverMedia);
        expect(plan.method, PlayMethod.directPlay);
        expect(plan.usesServerAuthentication, isTrue);
        expect(plan.usesControlledInput, isTrue);
        expect(plan.controlledInputRequest, request);
        expect(request.isProgressive, isTrue);
        expect(request.rawUrl, plan.uri.toString());
        expect(plan.uri.origin, 'https://emby.example.test');
        expect(plan.uri.path, '/base/Videos/item/stream');
        expect(request.headers, fixture.api.playbackHeaders);
        expect(
          () => request.headers['X-Emby-Token'] = 'changed',
          throwsUnsupportedError,
        );
        expect(request.identity.itemId, _item.id);
        expect(request.identity.sourceId, plan.mediaSourceId);
        expect(identical(request.identity.apiSession, fixture.api), isTrue);
        expect(request.identity.scope.serverId, _session.serverId);
        expect(request.identity.scope.userId, _session.userId);
        expect(request.sessionActive, isTrue);
        expect(fixture.resolver.canForceTranscode, isTrue);
        expect(plan.playSessionId, 'play-session');
        expect(plan.duration, const Duration(hours: 1));
        expect(fixture.playbackInfoRequests, hasLength(1));
        expect(
          fixture.playbackInfoRequests.single.data['EnableTranscoding'],
          isTrue,
        );
      },
    );
  }

  test(
    'ordinary direct stream to the selected same-origin video is eligible',
    () async {
      final fixture = _ResolverFixture([
        _source()..['SupportsDirectPlay'] = false,
      ]);

      final plan = await fixture.resolver.resolve(_item);

      expect(plan.method, PlayMethod.directStream);
      expect(plan.uri.path, '/base/Videos/item/stream.mkv');
      expect(plan.progressiveRequest!.rawUrl, plan.uri.toString());
      expect(plan.isSourceDirect, isFalse);
    },
  );

  final exclusions = <String, Map<String, dynamic>>{
    'unknown duration': _source()..remove('RunTimeTicks'),
    'zero duration': _source()..['RunTimeTicks'] = 0,
    'infinite stream': _source()..['IsInfiniteStream'] = true,
    'live stream': _source()..['LiveStreamId'] = 'live',
    'requires opening': _source()..['RequiresOpening'] = true,
    'open token': _source()..['OpenToken'] = 'open',
    'unrecognized container': _source(container: 'custom'),
    'HLS direct stream': _source(container: 'm3u8')
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] = '/Videos/item/master.m3u8',
    'DASH direct stream': _source(container: 'mpd')
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] = '/Videos/item/manifest.mpd',
    'segmented URL with progressive container': _source()
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] = '/Videos/item/master.m3u8',
    'remote direct stream': _source()
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] = 'https://cdn.example.test/movie.mkv',
    'different item stream': _source()
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] = '/Videos/other-item/stream.mkv',
    'unrelated same-origin endpoint': _source()
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] = '/Items/item/Download',
    'different source query': _source()
      ..['SupportsDirectPlay'] = false
      ..['DirectStreamUrl'] =
          '/Videos/item/stream.mkv?MediaSourceId=other-source',
  };
  for (final entry in exclusions.entries) {
    test(
      '${entry.key} keeps original player plan without optimization',
      () async {
        final fixture = _ResolverFixture([entry.value]);

        final plan = await fixture.resolver.resolve(_item);

        expect(plan.progressiveRequest, isNull);
        expect(plan.sourceRequest, isNull);
        expect(plan.isSourceDirect, isFalse);
        expect(plan.usesControlledInput, isFalse);
        expect(plan.controlledInputRequest, isNull);
        expect(plan.mediaSourceId, 'source-a');
        expect(plan.playSessionId, 'play-session');
        expect(fixture.playbackInfoRequests, hasLength(1));
      },
    );
  }

  test(
    'forced transcode never carries the optional progressive request',
    () async {
      final fixture = _ResolverFixture([_source()]);

      final plan = await fixture.resolver.resolve(_item, forceTranscode: true);

      expect(plan.method, PlayMethod.transcode);
      expect(plan.uri.path, '/base/Videos/item/master.m3u8');
      expect(plan.progressiveRequest, isNull);
      expect(plan.usesControlledInput, isFalse);
    },
  );

  test(
    'direct getPlaybackPlan without online identity cannot gain controlled input',
    () async {
      final fixture = _ResolverFixture([_source()]);

      final plan = await fixture.api.getPlaybackPlan(_item);

      expect(plan.method, PlayMethod.directPlay);
      expect(plan.progressiveRequest, isNull);
      expect(plan.usesControlledInput, isFalse);
    },
  );

  test(
    'clearing optional request preserves the complete native/reporting plan',
    () async {
      final fixture = _ResolverFixture([_source()]);
      final original = await fixture.resolver.resolve(
        _item,
        subtitleDisabled: true,
      );

      final native = original.copyWith(clearProgressiveRequest: true);

      expect(original.progressiveRequest, isNotNull);
      expect(native.progressiveRequest, isNull);
      expect(native.usesControlledInput, isFalse);
      expect(native.uri, original.uri);
      expect(
        native.usesServerAuthentication,
        original.usesServerAuthentication,
      );
      expect(native.method, original.method);
      expect(native.mediaSourceId, original.mediaSourceId);
      expect(native.playSessionId, original.playSessionId);
      expect(native.duration, original.duration);
      expect(native.container, original.container);
      expect(native.mediaStreams, original.mediaStreams);
      expect(native.availableMediaSources, original.availableMediaSources);
      expect(native.subtitleDisabled, isTrue);
    },
  );

  test(
    'verified controlled input updates cache evidence without changing route',
    () async {
      final fixture = _ResolverFixture([_source()]);
      final original = await fixture.resolver.resolve(_item);

      final verified = original.withVerifiedSourceInput(
        VerifiedSourceInput(
          request: original.progressiveRequest!,
          sizeBytes: 234567890,
        ),
      );

      expect(verified.sourceSizeBytes, 234567890);
      expect(verified.transportKind, PlaybackTransportKind.progressiveHttp);
      expect(verified.uri, original.uri);
      expect(verified.progressiveRequest, original.progressiveRequest);
      expect(verified.isSourceDirect, isFalse);
      expect(verified.usesServerAuthentication, isTrue);
      expect(verified.playSessionId, original.playSessionId);
    },
  );

  test(
    'API disposal revokes its progressive requests and rejects late verification',
    () async {
      final fixture = _ResolverFixture([_source()]);
      final plan = await fixture.resolver.resolve(_item);
      final request = plan.progressiveRequest!;

      await fixture.api.dispose();

      expect(request.sessionActive, isFalse);
      expect(
        () => plan.withVerifiedSourceInput(
          VerifiedSourceInput(request: request, sizeBytes: 1024),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'new resolver attempts do not revoke the still-playing source',
    () async {
      final fixture = _ResolverFixture([_source(), _source(id: 'source-b')]);
      final first = await fixture.resolver.resolve(
        _item,
        mediaSourceId: 'source-a',
      );
      final again = await fixture.resolver.resolve(
        _item,
        mediaSourceId: 'source-a',
      );
      final next = await fixture.resolver.resolve(
        _item,
        mediaSourceId: 'source-b',
      );

      expect(first.progressiveRequest!.sessionActive, isTrue);
      expect(again.progressiveRequest!.sessionActive, isTrue);
      expect(
        first.progressiveRequest!.identity.sameSource(
          again.progressiveRequest!.identity,
        ),
        isTrue,
      );
      expect(
        first.progressiveRequest!.identity.sameAttempt(
          again.progressiveRequest!.identity,
        ),
        isFalse,
      );
      expect(
        first.progressiveRequest!.identity.sameSource(
          next.progressiveRequest!.identity,
        ),
        isFalse,
      );
      expect(next.progressiveRequest!.identity.sourceId, 'source-b');
      fixture.resolver.cancelPending();
      expect(next.progressiveRequest!.sessionActive, isTrue);
      await fixture.api.dispose();
      expect(first.progressiveRequest!.sessionActive, isFalse);
      expect(again.progressiveRequest!.sessionActive, isFalse);
      expect(next.progressiveRequest!.sessionActive, isFalse);
    },
  );

  test('failed source-switch preflight leaves active request usable', () async {
    final fixture = _ResolverFixture([_source(), _source(id: 'source-b')]);
    final first = await fixture.resolver.resolve(
      _item,
      mediaSourceId: 'source-a',
    );
    fixture.failedSource = 'source-b';

    await expectLater(
      fixture.resolver.resolve(_item, mediaSourceId: 'source-b'),
      throwsA(anything),
    );

    expect(first.progressiveRequest!.sessionActive, isTrue);
    expect(first.progressiveRequest!.identity.sourceId, 'source-a');
    expect(
      first
          .withVerifiedSourceInput(
            VerifiedSourceInput(
              request: first.progressiveRequest!,
              sizeBytes: 1024,
            ),
          )
          .usesControlledInput,
      isTrue,
    );
  });

  test(
    'same source from another API or resolver cannot reuse verified evidence',
    () async {
      final fixture = _ResolverFixture([_source()]);
      final other = _ResolverFixture([_source()]);
      final first = await fixture.resolver.resolve(_item);
      final newLogin = await other.resolver.resolve(_item);
      final newItemSession = await EmbyStreamResolver(
        fixture.api,
      ).resolve(_item);

      expect(
        first.progressiveRequest!.identity.sameSource(
          newLogin.progressiveRequest!.identity,
        ),
        isFalse,
      );
      expect(
        first.progressiveRequest!.identity.sameSource(
          newItemSession.progressiveRequest!.identity,
        ),
        isFalse,
      );
      expect(
        () => first.withVerifiedSourceInput(
          VerifiedSourceInput(
            request: newLogin.progressiveRequest!,
            sizeBytes: 1024,
          ),
        ),
        throwsStateError,
      );
      expect(
        () => first.withVerifiedSourceInput(
          VerifiedSourceInput(
            request: newItemSession.progressiveRequest!,
            sizeBytes: 1024,
          ),
        ),
        throwsStateError,
      );
    },
  );
}

class _ResolverFixture {
  _ResolverFixture(List<Map<String, dynamic>> sources) {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final isPlaybackInfo = request.path.endsWith('/PlaybackInfo');
            if (isPlaybackInfo &&
                failedSource != null &&
                request.data['MediaSourceId'] == failedSource) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: 404,
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: isPlaybackInfo
                    ? {'PlaySessionId': 'play-session', 'MediaSources': sources}
                    : {'Id': _item.id, 'MediaSources': sources},
              ),
            );
          },
        ),
      );
    api = EmbyApi(_session, dio: dio);
    resolver = EmbyStreamResolver(api);
    addTearDown(api.dispose);
  }

  late final EmbyApi api;
  late final EmbyStreamResolver resolver;
  final requests = <RequestOptions>[];
  String? failedSource;
  List<RequestOptions> get playbackInfoRequests =>
      requests.where((r) => r.path.endsWith('/PlaybackInfo')).toList();
}
