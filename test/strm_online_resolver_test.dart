import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/emby_stream_resolver.dart';
import 'package:emby_my_client/playback/strm_direct_play_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _session = EmbySession(
  serverUrl: 'https://emby.invalid',
  serverName: 'fixture',
  serverId: 's',
  userId: 'u',
  username: 'fixture',
  accessToken: 'fixture',
  deviceId: 'd',
);
Map<String, Object> regular(String id) => {
  'Id': id,
  'Protocol': 'File',
  'Path': '/disk/$id.mp4',
  'SupportsDirectPlay': true,
  'Container': 'mp4',
};
Map<String, Object> strm(String id) => {
  'Id': id,
  'Protocol': 'File',
  'Path': '/disk/$id.strm',
  'Container': 'strm',
};
Map<String, Object> remote(String id) => {
  'Id': id,
  'Protocol': 'Http',
  'Path': 'https://source.invalid/$id%2fvideo?api_key=own',
  'Container': 'mp4',
};

void main() {
  for (final requested in ['a', 'b']) {
    test(
      'A03 A18 fixed $requested across regular A and STRM B reordered responses',
      () async {
        final requests = <RequestOptions>[];
        final sources = [regular('a'), strm('b')];
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (o, h) {
                requests.add(o);
                h.resolve(
                  Response(
                    requestOptions: o,
                    statusCode: 200,
                    data: o.method == 'GET'
                        ? {'Id': 'item', 'MediaSources': sources}
                        : {
                            'PlaySessionId': 'cycle',
                            'MediaSources': [remote('b'), regular('a')],
                          },
                  ),
                );
              },
            ),
          );
        final api = EmbyApi(_session, dio: dio);
        addTearDown(api.dispose);
        final resolver = EmbyStreamResolver(api);
        final plan = await resolver.resolve(
          EmbyItem.fromJson({'Id': 'item', 'MediaSources': sources}),
          mediaSourceId: requested,
        );
        expect(plan.mediaSourceId, requested);
        expect(plan.isSourceDirect, requested == 'b');
        final post = requests.where((o) => o.method == 'POST').single;
        expect(post.data['MediaSourceId'], requested);
        expect(post.data['EnableDirectStream'], requested == 'a');
        if (requested == 'b') {
          expect(post.data['EnableTranscoding'], false);
          expect(plan.sourceRequest!.rawUrl, remote('b')['Path']);
          api.dispose();
          expect(plan.sourceRequest!.sessionActive, false);
        }
      },
    );
  }

  test(
    'A19 regular A evidence cannot authorize response B when A disappears',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              requests.add(o);
              h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: o.method == 'GET'
                      ? {
                          'Id': 'item',
                          'MediaSources': [regular('a'), strm('b')],
                        }
                      : {
                          'MediaSources': [remote('b')],
                        },
                ),
              );
            },
          ),
        );
      final api = EmbyApi(_session, dio: dio);
      addTearDown(api.dispose);
      await expectLater(
        EmbyStreamResolver(
          api,
        ).resolve(EmbyItem.fromJson({'Id': 'item'}), mediaSourceId: 'a'),
        throwsA(
          isA<PlaybackResolveException>().having(
            (e) => e.failure,
            'failure',
            PlaybackResolveFailure.sourceMissing,
          ),
        ),
      );
      expect(requests, hasLength(2));
    },
  );

  test(
    'ordinary evidence changing to STRM re-enters strict group with same source',
    () async {
      final posts = <Map>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              if (o.method == 'POST') posts.add(Map.from(o.data as Map));
              h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: o.method == 'GET'
                      ? {
                          'Id': 'item',
                          'MediaSources': [regular('a')],
                        }
                      : {
                          'MediaSources': posts.length == 1
                              ? [strm('a'), regular('b')]
                              : [regular('b'), remote('a')],
                        },
                ),
              );
            },
          ),
        );
      final api = EmbyApi(_session, dio: dio);
      addTearDown(api.dispose);
      final plan = await EmbyStreamResolver(
        api,
      ).resolve(EmbyItem.fromJson({'Id': 'item'}));
      expect(plan.isSourceDirect, true);
      expect(plan.mediaSourceId, 'a');
      expect(posts, hasLength(2));
      expect(posts.every((p) => p['MediaSourceId'] == 'a'), true);
      expect(posts.last['EnableDirectStream'], false);
      expect(posts.last['EnableTranscoding'], false);
      expect(() => plan.copyWith(mediaSourceId: 'b'), throwsStateError);
      expect(
        () => plan.copyWith(usesServerAuthentication: true),
        throwsStateError,
      );
    },
  );

  test(
    'unknown container-only source never authorizes normal PlaybackInfo',
    () async {
      var posts = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              if (o.method == 'POST') posts++;
              h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: {
                    'Id': 'item',
                    'MediaSources': [
                      {'Id': 'a', 'Container': 'mp4'},
                    ],
                  },
                ),
              );
            },
          ),
        );
      final api = EmbyApi(_session, dio: dio);
      addTearDown(api.dispose);
      await expectLater(
        EmbyStreamResolver(api).resolve(EmbyItem.fromJson({'Id': 'item'})),
        throwsA(isA<PlaybackResolveException>()),
      );
      expect(posts, 0);
    },
  );
}
