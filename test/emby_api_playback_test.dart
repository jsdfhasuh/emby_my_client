import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_session_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackInfo compatibility', () {
    test('uses the full payload when the first request succeeds', () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_response(options, _directResponse()));
      });

      final plan = await api.getPlaybackPlan(_item);

      expect(requests, hasLength(1));
      expect((requests.single.data as Map)['DeviceProfile'], isA<Map>());
      expect(plan.method, PlayMethod.directPlay);
      expect(plan.playSessionId, 'play-session');
    });

    for (final status in [400, 422, 500]) {
      test('retries a compatibility payload after HTTP $status', () async {
        final requests = <RequestOptions>[];
        final api = _api((options, handler) {
          requests.add(options);
          if (requests.length == 1) {
            handler.reject(_httpError(options, status));
          } else {
            handler.resolve(_response(options, _directResponse()));
          }
        });

        await api.getPlaybackPlan(_item);

        expect(requests, hasLength(2));
        expect((requests.first.data as Map), contains('DeviceProfile'));
        expect((requests.last.data as Map), isNot(contains('DeviceProfile')));
      });
    }

    test(
      'uses the minimal third payload after two compatible errors',
      () async {
        final requests = <RequestOptions>[];
        final api = _api((options, handler) {
          requests.add(options);
          if (requests.length == 1) {
            handler.reject(_httpError(options, 400));
          } else if (requests.length == 2) {
            handler.reject(_httpError(options, 500));
          } else {
            handler.resolve(_response(options, _directResponse()));
          }
        });

        await api.getPlaybackPlan(_item);

        expect(requests, hasLength(3));
        expect(
          (requests.last.data as Map).keys,
          unorderedEquals(['UserId', 'StartTimeTicks']),
        );
      },
    );

    for (final status in [401, 403]) {
      test('does not retry authentication failure HTTP $status', () async {
        final requests = <RequestOptions>[];
        var sessionExpired = false;
        final api = _api((options, handler) {
          requests.add(options);
          handler.reject(_httpError(options, status));
        }, onSessionExpired: () => sessionExpired = true);

        await expectLater(
          api.getPlaybackPlan(_item),
          throwsA(
            isA<EmbyApiException>()
                .having((error) => error.statusCode, 'statusCode', status)
                .having(
                  (error) => error.isAuthenticationFailure,
                  'isAuthenticationFailure',
                  isTrue,
                ),
          ),
        );
        expect(requests, hasLength(1));
        await Future<void>.delayed(Duration.zero);
        expect(sessionExpired, isTrue);
      });
    }
  });

  group('playback plan selection', () {
    test('prioritizes DirectPlay over DirectStream and Transcode', () async {
      final api = _api((options, handler) {
        handler.resolve(
          _response(options, {
            'MediaSources': [
              _source(
                id: 'transcode',
                transcode: true,
                transcodingUrl: '/transcode/master.m3u8',
              ),
              _source(
                id: 'stream',
                directStream: true,
                directStreamUrl: '/stream/video.m3u8',
              ),
              _source(id: 'direct', directPlay: true),
            ],
          }),
        );
      });

      final plan = await api.getPlaybackPlan(_item);

      expect(plan.mediaSourceId, 'direct');
      expect(plan.method, PlayMethod.directPlay);
      expect(plan.usesServerAuthentication, isTrue);
    });

    test(
      'proxies remote strm through the authenticated Emby stream endpoint',
      () async {
        final api = _api((options, handler) {
          handler.resolve(
            _response(options, {
              'MediaSources': [
                _source(
                  id: 'remote-strm',
                  transcode: true,
                  path:
                      'https://upstream.example.test/live.m3u8'
                      '?api_key=upstream-key&quality=1080p',
                  protocol: 'Http',
                  container: 'strm',
                  transcodingUrl: '/Videos/item/master.m3u8',
                ),
              ],
            }),
          );
        });

        final plan = await api.getPlaybackPlan(_item);

        expect(plan.method, PlayMethod.directPlay);
        expect(plan.uri.origin, _session.serverUrl);
        expect(plan.uri.path, '/Videos/item-1/stream');
        expect(plan.uri.queryParameters['MediaSourceId'], 'remote-strm');
        expect(plan.uri.queryParameters['Static'], 'true');
        expect(plan.uri.queryParameters, isNot(contains('api_key')));
        expect(plan.usesServerAuthentication, isTrue);
      },
    );

    test(
      'forced retry bypasses remote strm and uses server transcode',
      () async {
        final api = _api((options, handler) {
          handler.resolve(
            _response(options, {
              'MediaSources': [
                _source(
                  id: 'remote-strm',
                  transcode: true,
                  path: 'https://upstream.example.test/live.m3u8',
                  protocol: 'Http',
                  container: 'strm',
                  transcodingUrl: '/Videos/item/master.m3u8',
                ),
              ],
            }),
          );
        });

        final plan = await api.getPlaybackPlan(_item, forceTranscode: true);

        expect(plan.method, PlayMethod.transcode);
        expect(plan.uri.origin, _session.serverUrl);
        expect(plan.usesServerAuthentication, isTrue);
      },
    );

    test(
      'ignores unsafe strm paths and uses the Emby stream endpoint',
      () async {
        final api = _api((options, handler) {
          handler.resolve(
            _response(options, {
              'MediaSources': [
                _source(
                  id: 'loopback-strm',
                  transcode: true,
                  path: 'http://127.0.0.1/private.m3u8',
                  protocol: 'Http',
                  container: 'strm',
                  transcodingUrl: '/Videos/item/master.m3u8',
                ),
              ],
            }),
          );
        });

        final plan = await api.getPlaybackPlan(_item);

        expect(plan.method, PlayMethod.directPlay);
        expect(plan.uri.origin, _session.serverUrl);
        expect(plan.uri.path, '/Videos/item-1/stream');
        expect(plan.uri.queryParameters['MediaSourceId'], 'loopback-strm');
        expect(plan.usesServerAuthentication, isTrue);
      },
    );

    test(
      'uses a stable preferred source ID and falls back when invalid',
      () async {
        final api = _api((options, handler) {
          handler.resolve(
            _response(options, {
              'MediaSources': [
                _source(id: 'direct', directPlay: true),
                _source(
                  id: 'stream',
                  directStream: true,
                  directStreamUrl: '/stream/video.m3u8',
                ),
              ],
            }),
          );
        });

        final preferred = await api.getPlaybackPlan(
          _item,
          mediaSourceId: 'stream',
        );
        final invalid = await api.getPlaybackPlan(
          _item,
          mediaSourceId: 'missing',
        );

        expect(preferred.mediaSourceId, 'stream');
        expect(preferred.method, PlayMethod.directStream);
        expect(invalid.mediaSourceId, 'direct');
      },
    );

    test('forces a transcoding source for the bounded retry', () async {
      RequestOptions? request;
      final api = _api((options, handler) {
        request = options;
        handler.resolve(
          _response(options, {
            'MediaSources': [
              _source(
                id: 'source',
                directPlay: true,
                transcode: true,
                transcodingUrl: '/Videos/item/master.m3u8',
              ),
            ],
          }),
        );
      });

      final plan = await api.getPlaybackPlan(
        _item,
        mediaSourceId: 'source',
        forceTranscode: true,
      );

      expect(plan.method, PlayMethod.transcode);
      expect((request!.data as Map)['EnableDirectPlay'], isFalse);
      expect((request!.data as Map)['EnableDirectStream'], isFalse);
    });

    test('normalizes stream URLs and canonicalizes track parameters', () async {
      var call = 0;
      final api = _api((options, handler) {
        call++;
        final url = call == 1
            ? '/Videos/item/master.m3u8?AudioStreamIndex=1&'
                  'audiostreamindex=2&SubtitleStreamIndex=3&'
                  'api_key=secret&foo=bar'
            : 'https://cdn.example.test/video.m3u8?x-emby-token=secret';
        handler.resolve(
          _response(options, {
            'MediaSources': [
              _source(id: 'stream', directStream: true, directStreamUrl: url),
            ],
          }),
        );
      });

      final relative = await api.getPlaybackPlan(
        _item,
        audioStreamIndex: 7,
        subtitleStreamIndex: 8,
      );
      final absolute = await api.getPlaybackPlan(_item);

      expect(relative.uri.origin, _session.serverUrl);
      expect(relative.uri.queryParameters['AudioStreamIndex'], '7');
      expect(relative.uri.queryParameters['SubtitleStreamIndex'], '8');
      expect(relative.uri.queryParameters['foo'], 'bar');
      expect(
        relative.uri.queryParameters.keys.where(
          (key) => key.toLowerCase() == 'audiostreamindex',
        ),
        hasLength(1),
      );
      expect(relative.uri.toString(), isNot(contains('secret')));
      expect(absolute.uri.host, 'cdn.example.test');
      expect(absolute.uri.toString(), isNot(contains('secret')));
      expect(relative.usesServerAuthentication, isTrue);
      expect(absolute.usesServerAuthentication, isFalse);
    });

    test('keeps a missing PlaySessionId nullable', () async {
      final api = _api((options, handler) {
        handler.resolve(
          _response(options, {
            'MediaSources': [_source(id: 'direct', directPlay: true)],
          }),
        );
      });

      final plan = await api.getPlaybackPlan(_item);

      expect(plan.playSessionId, isNull);
    });
  });

  group('reporting and authentication', () {
    test('builds a header-authenticated Trickplay tile URL', () {
      final api = _api((options, handler) {
        handler.resolve(_response(options, const {}));
      });

      final uri = api.trickplayTileUrl(
        itemId: 'item-1',
        width: 320,
        imageIndex: 4,
        mediaSourceId: 'source-1',
      );

      expect(uri.path, '/Videos/item-1/Trickplay/320/4.jpg');
      expect(uri.queryParameters['MediaSourceId'], 'source-1');
      expect(uri.toString(), isNot(contains(_session.accessToken)));
    });

    test(
      'sends playback headers through Dio and exposes them for libmpv',
      () async {
        RequestOptions? request;
        final api = _api((options, handler) {
          request = options;
          handler.resolve(_response(options, _directResponse()));
        });

        await api.getPlaybackPlan(_item);

        expect(request!.headers['X-Emby-Token'], _session.accessToken);
        expect(
          request!.headers['X-Emby-Authorization'].toString(),
          contains(_session.accessToken),
        );
        expect(api.playbackHeaders['X-Emby-Token'], _session.accessToken);
        expect(
          api.playbackHeaders['X-Emby-Authorization'],
          contains(_session.accessToken),
        );
      },
    );

    test('reports lifecycle payloads and cleans server resources', () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_response(options, const {}));
      });
      final plan = _plan(
        method: PlayMethod.transcode,
        playSessionId: 'session-1',
        liveStreamId: 'live-1',
      );

      await api.reportPlaybackStart(
        _item,
        plan,
        position: const Duration(seconds: 1),
      );
      await api.reportPlaybackProgress(
        _item,
        plan,
        position: const Duration(seconds: 2),
        isPaused: true,
      );
      await api.reportPlaybackStopped(
        _item,
        plan,
        position: const Duration(seconds: 3),
      );
      await api.closeLiveStream(plan);
      await api.stopActiveEncoding(plan);

      expect(requests.map((request) => request.path), [
        '/Sessions/Playing',
        '/Sessions/Playing/Progress',
        '/Sessions/Playing/Stopped',
        '/LiveStreams/Close',
        '/Videos/ActiveEncodings',
      ]);
      expect((requests[0].data as Map)['PositionTicks'], 10000000);
      expect((requests[1].data as Map)['IsPaused'], isTrue);
      expect((requests[2].data as Map)['PositionTicks'], 30000000);
      expect(requests[3].queryParameters['LiveStreamId'], 'live-1');
      expect(requests[4].queryParameters['playSessionId'], 'session-1');
    });

    test('omits a missing PlaySessionId from reports and cleanup', () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_response(options, const {}));
      });
      final plan = _plan(method: PlayMethod.transcode, playSessionId: null);

      await api.reportPlaybackStart(_item, plan);
      await api.stopActiveEncoding(plan);

      expect(requests, hasLength(1));
      expect((requests.single.data as Map), isNot(contains('PlaySessionId')));
    });

    test('reports stop and cleanup at most once', () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        handler.resolve(_response(options, const {}));
      });
      final reporter = PlaybackSessionReporter(api: api, item: _item)
        ..activate(
          _plan(
            method: PlayMethod.transcode,
            playSessionId: 'session-1',
            liveStreamId: 'live-1',
          ),
        );
      await reporter.reportStart(Duration.zero);

      await Future.wait([
        reporter.stop(const Duration(seconds: 3)),
        reporter.stop(const Duration(seconds: 4)),
      ]);

      expect(
        requests
            .where((request) => request.path == '/Sessions/Playing/Stopped')
            .length,
        1,
      );
      expect(
        requests
            .where((request) => request.path == '/LiveStreams/Close')
            .length,
        1,
      );
      expect(
        requests
            .where((request) => request.path == '/Videos/ActiveEncodings')
            .length,
        1,
      );
    });

    test('redacts encoded URL, headers and exception text', () {
      const token = 'super-secret-token';
      final value = DiagnosticLog.redact(
        'api_key%3D$token X-Emby-Token: $token '
        'Token="$token" Bearer $token',
      );

      expect(value, isNot(contains(token)));
      expect(value, contains('<redacted>'));
    });
  });
}

typedef _RequestHandler =
    void Function(RequestOptions options, RequestInterceptorHandler handler);

EmbyApi _api(
  _RequestHandler onRequest, {
  FutureOr<void> Function()? onSessionExpired,
}) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return EmbyApi(_session, dio: dio, onSessionExpired: onSessionExpired);
}

Response<dynamic> _response(RequestOptions options, dynamic data) =>
    Response<dynamic>(requestOptions: options, data: data, statusCode: 200);

DioException _httpError(RequestOptions options, int statusCode) => DioException(
  requestOptions: options,
  response: Response<dynamic>(
    requestOptions: options,
    statusCode: statusCode,
    data: {'Message': 'HTTP $statusCode'},
  ),
  type: DioExceptionType.badResponse,
);

Map<String, dynamic> _directResponse() => {
  'PlaySessionId': 'play-session',
  'MediaSources': [_source(id: 'direct', directPlay: true)],
};

Map<String, dynamic> _source({
  required String id,
  bool directPlay = false,
  bool directStream = false,
  bool transcode = false,
  String? path,
  String? protocol,
  String container = 'mkv',
  String? directStreamUrl,
  String? transcodingUrl,
}) => {
  'Id': id,
  'Name': id,
  'Path': ?path,
  'Protocol': ?protocol,
  'Container': container,
  'Bitrate': 8000000,
  'SupportsDirectPlay': directPlay,
  'SupportsDirectStream': directStream,
  'SupportsTranscoding': transcode,
  'DirectStreamUrl': ?directStreamUrl,
  'TranscodingUrl': ?transcodingUrl,
  'MediaStreams': [
    {
      'Index': 0,
      'Type': 'Video',
      'Codec': 'h264',
      'Profile': 'High',
      'Level': 41,
      'Width': 1920,
      'Height': 1080,
    },
  ],
};

PlaybackPlan _plan({
  required PlayMethod method,
  required String? playSessionId,
  String? liveStreamId,
}) => PlaybackPlan(
  uri: Uri.parse('https://media.example.test/video'),
  mediaSourceId: 'source-1',
  playSessionId: playSessionId,
  method: method,
  usesServerAuthentication: true,
  mediaStreams: const [],
  transcodingReasons: const [],
  availableMediaSources: const [],
  liveStreamId: liveStreamId,
);

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _item = EmbyItem(
  id: 'item-1',
  name: 'Movie',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
