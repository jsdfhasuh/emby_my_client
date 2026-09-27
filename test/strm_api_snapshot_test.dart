import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/strm_direct_play_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'A09 actual strict API retries keep source, flags and disabled subtitle',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        if (requests.length < 3) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 422),
            ),
          );
        } else {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _response(),
            ),
          );
        }
      });
      addTearDown(api.dispose);
      final snapshot = await _resolve(api, subtitleDisabled: true);
      expect(requests, hasLength(3));
      for (final request in requests) {
        final body = request.data as Map;
        expect(request.path, '/Items/item/PlaybackInfo');
        expect(body['MediaSourceId'], 'b');
        expect(body['EnableDirectPlay'], isTrue);
        expect(body['EnableDirectStream'], isFalse);
        expect(body['EnableTranscoding'], isFalse);
        expect(body['AutoOpenLiveStream'], isFalse);
        expect(body['SubtitleStreamIndex'], -1);
      }
      expect(snapshot.request.rawUrl, _raw);
      expect(snapshot.request.headers, {'User-Agent': 'fixture'});
      expect(snapshot.request.headers.keys, isNot(contains('X-Emby-Token')));
    },
  );

  test('A10 confirmed STRM forceTranscode fails before any I/O', () async {
    var calls = 0;
    final api = _api((options, handler) {
      calls++;
    });
    addTearDown(api.dispose);
    await expectLater(
      _resolve(api, force: true),
      _failure(PlaybackResolveFailure.invalidSourceRequest),
    );
    expect(calls, 0);
  });

  for (final status in [401, 403, 429]) {
    test('A12 HTTP $status stops metadata retries', () async {
      var calls = 0;
      final api = _api((options, handler) {
        calls++;
        handler.reject(
          DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: status),
          ),
        );
      });
      addTearDown(api.dispose);
      await expectLater(
        _resolve(api),
        _failure(
          status == 429
              ? PlaybackResolveFailure.rateLimited
              : PlaybackResolveFailure.serverDenied,
        ),
      );
      expect(calls, 1);
    });
  }

  test(
    'A13 NoCompatibleStream cannot be overridden with source Path',
    () async {
      final api = _api(
        (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {..._response(), 'ErrorCode': 'NoCompatibleStream'},
          ),
        ),
      );
      addTearDown(api.dispose);
      await expectLater(
        _resolve(api),
        _failure(PlaybackResolveFailure.noCompatibleStream),
      );
    },
  );

  test(
    'A03 A18 A19 response order cannot switch source B to regular A',
    () async {
      final api = _api(
        (options, handler) => handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: _response()),
        ),
      );
      addTearDown(api.dispose);
      final snapshot = await _resolve(api);
      expect(snapshot.request.identity.sourceId, 'b');
      expect(snapshot.request.rawUrl, _raw);
      expect(snapshot.duration, const Duration(seconds: 2));
      expect(snapshot.mediaStreams.single['Language'], 'chi');
    },
  );

  test(
    'A15 detail fallback replaces headers atomically and shares one GET',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        final data = options.method == 'GET'
            ? {
                'Id': 'item',
                'MediaSources': [
                  {'Id': 'b', 'Path': _raw},
                ],
              }
            : {
                'MediaSources': [
                  {
                    'Id': 'b',
                    'Path': '/disk/movie.strm',
                    'RequiredHttpHeaders': {'Cookie': 'old-fixture'},
                  },
                ],
              };
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: data),
        );
      });
      addTearDown(api.dispose);
      final snapshot = await _resolve(api);
      expect(snapshot.request.rawUrl, _raw);
      expect(snapshot.request.headers, isEmpty);
      expect(requests.map((request) => request.method), ['POST', 'GET']);
    },
  );

  test(
    'B14 B15 same scope new API and late invalidated response cannot publish',
    () async {
      final gate = Completer<void>();
      var active = true;
      final api = _api((options, handler) async {
        await gate.future;
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: _response()),
        );
      });
      addTearDown(api.dispose);
      final pending = _resolve(api, isCurrent: () => active);
      active = false;
      gate.complete();
      await expectLater(pending, _failure(PlaybackResolveFailure.cancelled));
      final other = _api((options, handler) => fail('wrong API issued I/O'));
      addTearDown(other.dispose);
      await expectLater(
        other.getSourceDirectSnapshot(
          _item,
          identity: _identity(api),
          cancelToken: CancelToken(),
          isCurrent: () => true,
        ),
        _failure(PlaybackResolveFailure.sourceIdentityConflict),
      );
    },
  );

  test('A11 explicit cancellation reaches the in-flight Dio request', () async {
    final entered = Completer<void>();
    final cancelled = Completer<void>();
    final api = _api((options, handler) {
      entered.complete();
      options.cancelToken!.whenCancel.then((error) {
        cancelled.complete();
        handler.reject(error);
      });
    });
    addTearDown(api.dispose);
    final token = CancelToken();
    final pending = _resolve(api, cancelToken: token);
    await entered.future;
    token.cancel();
    await expectLater(pending, _failure(PlaybackResolveFailure.cancelled));
    await cancelled.future;
  });
}

const _raw =
    'https://source.invalid/a%2fb.mp4?api_key=upstream&x=1&x=2&sig=%7e';
final _item = EmbyItem.fromJson({
  'Id': 'item',
  'MediaSources': [
    {'Id': 'a', 'Protocol': 'File', 'Path': '/disk/a.mp4'},
    {'Id': 'b', 'Protocol': 'File', 'Path': '/disk/b.strm'},
  ],
});
const _session = EmbySession(
  serverUrl: 'https://emby.invalid',
  serverName: 'fixture',
  serverId: 'fixture',
  userId: 'user',
  username: 'fixture',
  accessToken: 'fixture-token',
  deviceId: 'fixture-device',
);

Map<String, dynamic> _response() => {
  'PlaySessionId': 'session',
  'MediaSources': [
    {
      'Id': 'a',
      'Path': '/disk/a.mp4',
      'Protocol': 'File',
      'RunTimeTicks': 990000000,
    },
    {
      'Id': 'b',
      'Path': _raw,
      'Container': 'mp4',
      'Protocol': 'Http',
      'RequiredHttpHeaders': {'User-Agent': 'fixture'},
      'RunTimeTicks': 20000000,
      'MediaStreams': [
        {'Type': 'Audio', 'Index': 2, 'Language': 'chi'},
      ],
    },
  ],
};

EmbyApi _api(void Function(RequestOptions, RequestInterceptorHandler) handle) {
  final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: handle));
  return EmbyApi(_session, dio: dio);
}

PlaybackResourceIdentity _identity(EmbyApi api) => PlaybackResourceIdentity(
  scope: ServerScope.fromSession(_session),
  apiSession: api,
  itemId: 'item',
  sourceId: 'b',
  itemSession: Object(),
  generation: 1,
);

Future<SelectedSourceSnapshot> _resolve(
  EmbyApi api, {
  bool force = false,
  bool subtitleDisabled = false,
  bool Function()? isCurrent,
  CancelToken? cancelToken,
}) => api.getSourceDirectSnapshot(
  _item,
  identity: _identity(api),
  cancelToken: cancelToken ?? CancelToken(),
  isCurrent: isCurrent ?? () => true,
  forceTranscode: force,
  subtitleDisabled: subtitleDisabled,
);

Matcher _failure(PlaybackResolveFailure failure) => throwsA(
  isA<PlaybackResolveException>().having(
    (error) => error.failure,
    'failure',
    failure,
  ),
);
