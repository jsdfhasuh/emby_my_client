import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/strm_direct_play_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _session = EmbySession(
  serverUrl: 'https://emby.invalid',
  serverName: 'fixture',
  serverId: 'server',
  userId: 'user',
  username: 'fixture',
  accessToken: 'emby-only-token',
  deviceId: 'device',
);
const _url = 'https://source.invalid/a%2fb.mp4?signature=own%2Bsignature';
Map<String, dynamic> _source() => {
  'Id': 'source',
  'Path': _url,
  'Protocol': 'Http',
  'Container': 'strm',
  'Size': 50,
  'RunTimeTicks': 600000000,
  'RequiredHttpHeaders': {'User-Agent': 'source-agent'},
};
EmbyItem _item({bool sources = true}) => EmbyItem.fromJson({
  'Id': 'item',
  'Path': '/disk/movie.strm',
  if (sources)
    'MediaSources': [
      {
        ..._source(),
        'Path': 'https://source.invalid/stale.mp4',
        'RequiredHttpHeaders': {'Cookie': 'stale-cookie'},
      },
    ],
});

Future<PlaybackPlan> _resolve(
  EmbyApi api, {
  EmbyItem? item,
  CancelToken? cancelToken,
  bool forceTranscode = false,
  String? mediaSourceId = 'source',
}) => api.resolveOnlinePlayback(
  item ?? _item(),
  itemSession: Object(),
  generation: 1,
  cancelToken: cancelToken ?? CancelToken(),
  isCurrent: () => true,
  mediaSourceId: mediaSourceId,
  knownStrm: true,
  subtitleDisabled: true,
  forceTranscode: forceTranscode,
);

void main() {
  test('resolution route uses the closed diagnostic vocabulary', () {
    for (final route in ['detail_direct', 'playback_info']) {
      expect(
        StrmDiagnosticSchema.valid(
          'event=strm_resolve trace=abcdef0123456789 resolution=$route '
          'fixedSource=true outcome=succeeded',
        ),
        isTrue,
      );
    }
  });
  test(
    'source identification remains compatible with detail omitting sources',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((o, h) {
        requests.add(o);
        h.resolve(
          Response(
            requestOptions: o,
            statusCode: 200,
            data: {
              'Id': 'item',
              if (o.method == 'POST') 'PlaySessionId': 'identified',
              if (o.method == 'POST') 'MediaSources': [_source()],
            },
          ),
        );
      });
      addTearDown(api.dispose);
      final plan = await _resolve(
        api,
        item: _item(sources: false),
        mediaSourceId: null,
      );
      expect(plan.sourceRequest!.rawUrl, _url);
      expect(plan.playSessionId, 'identified');
      expect(requests.map((r) => r.method), ['GET', 'POST']);
    },
  );

  test(
    'direct detail plan reports item/source without requiring PlaySessionId',
    () async {
      final reports = <RequestOptions>[];
      final api = _api((o, h) {
        if (o.method == 'POST') {
          reports.add(o);
          h.resolve(Response(requestOptions: o, statusCode: 204));
        } else {
          h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {
                'Id': 'item',
                'MediaSources': [_source()],
              },
            ),
          );
        }
      });
      addTearDown(api.dispose);
      final plan = await _resolve(api);
      await api.reportPlaybackStart(_item(), plan, isPaused: false);
      await api.reportPlaybackProgress(
        _item(),
        plan,
        position: const Duration(seconds: 5),
        isPaused: false,
      );
      await api.reportPlaybackStopped(
        _item(),
        plan,
        position: const Duration(seconds: 5),
      );
      expect(reports.map((r) => r.path), [
        '/Sessions/Playing',
        '/Sessions/Playing/Progress',
        '/Sessions/Playing/Stopped',
      ]);
      for (final report in reports) {
        expect(report.data['ItemId'], 'item');
        expect(report.data['MediaSourceId'], 'source');
        expect((report.data as Map).containsKey('PlaySessionId'), false);
      }
    },
  );

  for (final cachedSources in [true, false]) {
    test(
      'fresh STRM detail bypasses PlaybackInfo (cached=$cachedSources)',
      () async {
        final requests = <RequestOptions>[];
        final api = _api((o, h) {
          requests.add(o);
          expect(o.method, 'GET');
          h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {
                'Id': 'item',
                'Path': '/disk/movie.strm',
                'MediaSources': [_source()],
              },
            ),
          );
        });
        addTearDown(api.dispose);
        final plan = await _resolve(api, item: _item(sources: cachedSources));
        expect(requests.single.path, '/Users/user/Items/item');
        expect(plan.isSourceDirect, true);
        expect(plan.sourceRequest!.rawUrl, _url);
        expect(plan.sourceRequest!.headers, {'User-Agent': 'source-agent'});
        expect(plan.usesServerAuthentication, false);
        expect(plan.playSessionId, isNull);
        expect(plan.mediaSourceId, 'source');
        expect(plan.duration, const Duration(seconds: 60));
        expect(
          plan.sourceSizeBytes,
          isNull,
        ); // The STRM file size is not video size.
        expect(plan.subtitleDisabled, true);
      },
    );
  }

  test(
    'local STRM detail retains fixed-source strict compatibility request',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((o, h) {
        requests.add(o);
        h.resolve(
          Response(
            requestOptions: o,
            statusCode: 200,
            data: {
              'Id': 'item',
              'PlaySessionId': 'play-session',
              'MediaSources': [
                {
                  ..._source(),
                  if (o.method == 'GET') 'Path': '/disk/movie.strm',
                },
              ],
            },
          ),
        );
      });
      addTearDown(api.dispose);
      final plan = await _resolve(api);
      expect(requests.map((r) => r.method), ['GET', 'POST']);
      expect(requests.last.data['MediaSourceId'], 'source');
      expect(requests.last.data['EnableTranscoding'], false);
      expect(requests.last.data['EnableDirectStream'], false);
      expect(plan.playSessionId, 'play-session');
      expect(plan.sourceRequest!.rawUrl, _url);
    },
  );

  for (final status in [401, 403, 429]) {
    test('fresh detail HTTP $status cannot fall back to cached URL', () async {
      var requests = 0;
      final api = _api((o, h) {
        requests++;
        h.reject(
          DioException(
            requestOptions: o,
            response: Response(requestOptions: o, statusCode: status),
          ),
        );
      });
      addTearDown(api.dispose);
      await expectLater(_resolve(api), throwsA(isA<EmbyApiException>()));
      expect(requests, 1);
    });
  }

  for (final invalid in [
    'missing',
    'duplicate',
    'requiresOpening',
    'item',
    'denied',
  ]) {
    test('fresh detail $invalid is rejected without PlaybackInfo', () async {
      var requests = 0;
      final api = _api((o, h) {
        requests++;
        h.resolve(
          Response(
            requestOptions: o,
            statusCode: 200,
            data: {
              'Id': invalid == 'item' ? 'other' : 'item',
              if (invalid == 'denied') 'PlayAccess': 'None',
              'MediaSources': [
                if (invalid != 'missing')
                  {
                    ..._source(),
                    if (invalid == 'requiresOpening') 'RequiresOpening': true,
                  },
                if (invalid == 'duplicate') _source(),
              ],
            },
          ),
        );
      });
      addTearDown(api.dispose);
      await expectLater(
        _resolve(api),
        throwsA(isA<PlaybackResolveException>()),
      );
      expect(requests, 1);
    });
  }

  test('cancelled detail cannot create a late source snapshot', () async {
    final pending = Completer<void>();
    final started = Completer<void>();
    final token = CancelToken();
    final api = _api((o, h) async {
      started.complete();
      await pending.future;
      h.resolve(
        Response(
          requestOptions: o,
          statusCode: 200,
          data: {
            'Id': 'item',
            'MediaSources': [_source()],
          },
        ),
      );
    });
    addTearDown(api.dispose);
    final result = expectLater(
      _resolve(api, cancelToken: token),
      throwsA(anything),
    );
    await started.future;
    token.cancel('test_cancel');
    pending.complete();
    await result;
  });

  test('known STRM transcode is rejected before detail I/O', () async {
    var requests = 0;
    final api = _api((o, h) => requests++);
    addTearDown(api.dispose);
    await expectLater(
      _resolve(api, item: _item(sources: false), forceTranscode: true),
      throwsA(isA<PlaybackResolveException>()),
    );
    expect(requests, 0);
  });
}

EmbyApi _api(InterceptorSendCallback handler) => EmbyApi(
  _session,
  dio: Dio()..interceptors.add(InterceptorsWrapper(onRequest: handler)),
);
