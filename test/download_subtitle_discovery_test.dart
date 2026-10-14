import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/downloads/download_assets.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in [
    'success',
    '503',
    'html',
    'redirect',
    'unsupported',
    'missing-source',
    'empty-streams',
    'ass',
    'vtt',
    'embedded-only',
    'no-subtitles',
  ]) {
    test('subtitle discovery and asset result: $mode', () async {
      final wire = _Wire(mode);
      final api = EmbyApi(_session, dio: Dio()..httpClientAdapter = wire);
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-discovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final result = await EmbyDownloadAssetService(
        api,
      ).downloadAssets(_task, directory);
      if (mode == 'embedded-only' || mode == 'no-subtitles') {
        expect(result.subtitleDiscoveryComplete, isTrue);
        expect(result.subtitlesNeedRepair, isFalse);
        expect(
          result.mediaStreams.where((s) => s['IsExternal'] == true),
          isEmpty,
        );
        expect(
          wire.requests.where((r) => r.path.contains('/Subtitles/')),
          isEmpty,
        );
        expect(
          result.subtitleStatusText,
          mode == 'embedded-only' ? contains('内嵌字幕') : contains('未提供字幕'),
        );
      } else if (['success', 'empty-streams', 'ass', 'vtt'].contains(mode)) {
        expect(result.subtitleDiscoveryComplete, isTrue);
        expect(result.subtitlesNeedRepair, isFalse);
        final external = result.mediaStreams.singleWhere(
          (s) => s['IsExternal'] == true,
        );
        expect(external['OfflineSubtitleState'], 'available');
        expect(
          await File(external['DeliveryUrl'] as String).readAsString(),
          wire.subtitle,
        );
        expect(
          wire.requests.any(
            (r) => r.path.contains(
              '/Videos/item/source-B/Subtitles/4/Stream.${wire.extension}',
            ),
          ),
          isTrue,
        );
        expect(
          result.mediaStreams.any(
            (s) => s['Index'] == 2 && s['IsExternal'] == false,
          ),
          isTrue,
        );
        if (mode == 'empty-streams') {
          final discovery = wire.requests.singleWhere(
            (r) => r.method == 'POST',
          );
          expect(discovery.data['MediaSourceId'], 'source-B');
          expect(discovery.data['AutoOpenLiveStream'], isFalse);
          expect(discovery.data['EnableTranscoding'], isFalse);
        }
      } else if (mode == 'missing-source') {
        expect(result.subtitleDiscoveryComplete, isFalse);
        expect(result.subtitlesNeedRepair, isTrue);
        expect(wire.requests, hasLength(1));
      } else {
        expect(result.subtitlesNeedRepair, isTrue);
        final external = result.mediaStreams.singleWhere(
          (s) => s['IsExternal'] == true,
        );
        expect(
          external['OfflineSubtitleState'],
          mode == 'unsupported' ? 'unsupported' : 'failed',
        );
        expect(external.containsKey('DeliveryUrl'), isFalse);
        expect(
          result.playbackStreams.any((s) => s['IsExternal'] == true),
          isFalse,
        );
      }
      expect(
        wire.requests.any((r) => r.uri.host == 'external.invalid'),
        isFalse,
      );
      expect(
        wire.requests.every((r) => !r.uri.toString().contains('fixture-token')),
        isTrue,
      );
      final manifest = jsonEncode(result.toJson());
      expect(manifest, isNot(contains('fixture-token')));
      expect(manifest, isNot(contains('evil')));
      expect(
        await directory
            .list(recursive: true)
            .where((e) => e.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
    });
  }

  test('cancel during subtitle body leaves no published subtitle', () async {
    final token = CancelToken();
    final wire = _Wire('success')
      ..onSubtitle = () => token.cancel('fixture cancel');
    final api = EmbyApi(_session, dio: Dio()..httpClientAdapter = wire);
    addTearDown(api.dispose);
    final directory = await Directory.systemTemp.createTemp('subtitle-cancel-');
    addTearDown(() => directory.delete(recursive: true));
    await expectLater(
      EmbyDownloadAssetService(
        api,
      ).downloadAssets(_task, directory, cancelToken: token),
      throwsA(isA<DioException>()),
    );
    expect(
      await directory
          .list(recursive: true)
          .where((entity) => entity is File)
          .toList(),
      isEmpty,
    );
  });
}

const _srt = '1\n00:00:00,000 --> 00:00:01,000\nFixture subtitle\n';
const _ass =
    '[Script Info]\nTitle: Fixture\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Fixture subtitle\n';
const _vtt = 'WEBVTT\n\n00:00.000 --> 00:01.000\nFixture subtitle\n';
const _session = EmbySession(
  serverUrl: 'https://fixture.invalid',
  serverName: 'Fixture',
  serverId: 'server',
  userId: 'user',
  username: 'fixture',
  accessToken: 'fixture-token',
  deviceId: 'device',
);
final _task = DownloadTaskRecord(
  id: 'fixture-task',
  scope: const ServerScope(serverId: 'server', userId: 'user'),
  itemId: 'item',
  mediaSourceId: 'source-B',
  sourceKind: DownloadSourceKind.original,
  sourceFingerprint: 'fixture',
  status: DownloadStatus.completed,
  downloadedBytes: 10,
  retryCount: 0,
  tempPath: 'fixture.part',
  finalPath: 'fixture.mkv',
  metadata: OfflineMediaMetadata(
    name: 'Fixture',
    itemType: 'Movie',
    mediaStreams: const [],
  ),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

class _Wire implements HttpClientAdapter {
  _Wire(this.mode);
  final String mode;
  final requests = <RequestOptions>[];
  void Function()? onSubtitle;
  String get extension => ['ass', 'vtt'].contains(mode) ? mode : 'srt';
  String get subtitle => mode == 'ass'
      ? _ass
      : mode == 'vtt'
      ? _vtt
      : _srt;
  List<Map<String, dynamic>> get streams => mode == 'no-subtitles'
      ? []
      : [
          {
            'Index': 2,
            'Type': 'Subtitle',
            'IsExternal': false,
            'Codec': 'subrip',
          },
          if (mode != 'embedded-only')
            {
              'Index': 4,
              'Type': 'Subtitle',
              'IsExternal': true,
              'Codec': mode == 'unsupported' ? 'dvdsub' : extension,
              'Language': 'chi',
            },
        ];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.endsWith('/Items/item')) {
      return _json({
        'Id': 'item',
        'Name': 'Fixture',
        'Type': 'Movie',
        'MediaSources': [
          {
            'Id': 'source-A',
            'MediaStreams': [
              {
                'Index': 1,
                'Type': 'Subtitle',
                'Codec': 'subrip',
                'IsExternal': true,
                'DeliveryUrl':
                    'https://external.invalid/evil?api_key=fixture-token',
              },
            ],
          },
          if (mode != 'missing-source')
            {
              'Id': 'source-B',
              'MediaStreams': mode == 'empty-streams' ? [] : streams,
            },
        ],
      });
    }
    if (options.path.endsWith('/PlaybackInfo')) {
      return _json({
        'MediaSources': [
          {'Id': 'source-B', 'MediaStreams': streams},
        ],
      });
    }
    onSubtitle?.call();
    if (mode == 'redirect') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://external.invalid/evil'],
        },
      );
    }
    return ResponseBody.fromString(
      mode == 'html' ? '<html>Error</html>' : subtitle,
      mode == '503' ? 503 : 200,
      headers: {
        'content-type': [mode == 'html' ? 'text/html' : 'application/x-subrip'],
      },
    );
  }

  ResponseBody _json(Object value) => ResponseBody.fromString(
    jsonEncode(value),
    200,
    headers: {
      'content-type': ['application/json'],
    },
  );
  @override
  void close({bool force = false}) {}
}
