import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/downloads/download_assets.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'downloads same-origin image and subtitles without credentials in URLs',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              final image = options.uri.path.contains('/Images/Primary');
              final bytes = image ? _imageBytes : _subtitleBytes;
              handler.resolve(
                Response<ResponseBody>(
                  requestOptions: options,
                  statusCode: 200,
                  headers: Headers.fromMap({
                    'content-length': ['${bytes.length}'],
                    'content-type': [
                      image ? 'image/jpeg' : 'application/x-subrip',
                    ],
                  }),
                  data: ResponseBody.fromBytes(bytes, 200),
                ),
              );
            },
          ),
        );
      final api = EmbyApi(_session, dio: dio);
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'emby-assets-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final task = _task();

      final metadata = await EmbyDownloadAssetService(
        api,
      ).downloadAssets(task, directory);

      expect(requests, hasLength(2));
      expect(
        requests,
        everyElement(
          predicate<RequestOptions>(
            (request) =>
                !request.uri.toString().contains(_session.accessToken) &&
                !request.uri.queryParameters.containsKey('api_key') &&
                request.headers['X-Emby-Token'] == _session.accessToken,
          ),
        ),
      );
      expect(metadata.primaryImagePath, isNotNull);
      expect(await File(metadata.primaryImagePath!).readAsBytes(), _imageBytes);
      final external = metadata.mediaStreams.where(
        (stream) => stream['IsExternal'] == true,
      );
      expect(external, hasLength(1));
      final subtitlePath = external.single['DeliveryUrl']!.toString();
      expect(await File(subtitlePath).readAsBytes(), _subtitleBytes);
      expect(
        metadata.mediaStreams.any((stream) => stream['Index'] == 4),
        isFalse,
      );
    },
  );
}

DownloadTaskRecord _task() {
  final now = DateTime.utc(2026, 7, 30);
  return DownloadTaskRecord(
    id: '0123456789abcdef-task',
    scope: _scope,
    itemId: 'item-1',
    mediaSourceId: 'source-1',
    sourceKind: DownloadSourceKind.original,
    sourceFingerprint: 'fingerprint',
    status: DownloadStatus.running,
    downloadedBytes: 0,
    retryCount: 0,
    tempPath: 'video.mkv.part',
    finalPath: 'video.mkv',
    metadata: OfflineMediaMetadata(
      name: 'Offline Test',
      itemType: 'Movie',
      primaryImageTag: 'image-tag',
      mediaStreams: const [
        {'Index': 0, 'Type': 'Video', 'Codec': 'h264'},
        {
          'Index': 3,
          'Type': 'Subtitle',
          'Codec': 'subrip',
          'IsExternal': true,
          'DeliveryUrl': '/Videos/item-1/Subtitles/3/Stream.srt?api_key=secret',
        },
        {
          'Index': 4,
          'Type': 'Subtitle',
          'Codec': 'subrip',
          'IsExternal': true,
          'DeliveryUrl': 'https://evil.example.test/subtitle.srt',
        },
      ],
    ),
    createdAt: now,
    updatedAt: now,
  );
}

const _scope = ServerScope(serverId: 'server-1', userId: 'user-1');

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'secret-token',
  deviceId: 'device-1',
);

const _imageBytes = <int>[0xFF, 0xD8, 0xFF, 0xD9];
const _subtitleBytes = <int>[
  0x31,
  0x0A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
  0x3A,
  0x30,
  0x30,
];
