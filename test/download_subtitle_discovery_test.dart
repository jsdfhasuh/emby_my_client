import 'dart:async';
import 'support/dio_download_test_api.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_assets.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:emby_my_client/downloads/download_asset_verifier.dart';
import 'package:emby_my_client/downloads/download_cleanup.dart';
import 'package:emby_my_client/offline/offline_playback_resolver.dart';
import 'package:emby_my_client/offline/offline_playback_reporter.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_presentation.dart';
import 'package:emby_my_client/playback/track_mapper.dart';

import 'support/route_playback_engine.dart';

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
      final api = DioDownloadTestApi(
        _session,
        dio: Dio()..httpClientAdapter = wire,
      );
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

  test(
    'failed refresh retains verified subtitles and skips cover and video',
    () async {
      final wire = _Wire('success');
      final api = DioDownloadTestApi(
        _session,
        dio: Dio()..httpClientAdapter = wire,
      );
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-preserve-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final assets = EmbyDownloadAssetService(api);
      final saved = await assets.downloadAssets(_task, directory);
      final subtitlePath =
          saved.playbackStreams.singleWhere(
                (s) => s['IsExternal'] == true,
              )['DeliveryUrl']
              as String;
      final before = await File(subtitlePath).readAsBytes();
      // Even a known cover must not be requested by subtitle-only repair.
      final withCover = OfflineMediaMetadata.fromJson({
        ...saved.toJson(),
        'primaryImageTag': 'fixture-cover',
      });
      wire.requests.clear();
      wire.mode = '503';
      final repaired = await assets.repairSubtitles(
        _task.copyWith(metadata: withCover),
        directory,
      );
      final subtitle = repaired.playbackStreams.singleWhere(
        (s) => s['IsExternal'] == true,
      );
      expect(subtitle['DeliveryUrl'], subtitlePath);
      expect(subtitle['OfflineSubtitleState'], 'available');
      expect(subtitle['OfflineSubtitleError'], 'refreshFailed');
      expect(await File(subtitlePath).readAsBytes(), before);
      expect(repaired.subtitlesNeedRepair, isTrue);
      expect(
        wire.requests.every(
          (r) =>
              r.path.endsWith('/Items/item') ||
              r.path.endsWith('/PlaybackInfo') ||
              r.path.contains('/Subtitles/'),
        ),
        isTrue,
      );
    },
  );

  test(
    'cancelled refresh preserves previously published subtitle bytes',
    () async {
      final wire = _Wire('success');
      final api = DioDownloadTestApi(
        _session,
        dio: Dio()..httpClientAdapter = wire,
      );
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-retain-cancel-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final assets = EmbyDownloadAssetService(api);
      final saved = await assets.downloadAssets(_task, directory);
      final subtitlePath =
          saved.playbackStreams.singleWhere(
                (s) => s['IsExternal'] == true,
              )['DeliveryUrl']
              as String;
      final token = CancelToken();
      wire.onSubtitle = () => token.cancel('fixture cancel refresh');
      await expectLater(
        assets.repairSubtitles(
          _task.copyWith(metadata: saved),
          directory,
          cancelToken: token,
        ),
        throwsA(isA<DioException>()),
      );
      expect(await File(subtitlePath).readAsString(), _srt);
      expect(
        await directory
            .list(recursive: true)
            .where((file) => file.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'offline discovery and removed tracks retain existing subtitles',
    () async {
      final wire = _Wire('success');
      final api = DioDownloadTestApi(
        _session,
        dio: Dio()..httpClientAdapter = wire,
      );
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-retain-discovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final assets = EmbyDownloadAssetService(api);
      final saved = await assets.downloadAssets(_task, directory);
      for (final mode in ['missing-source', 'no-subtitles']) {
        wire.mode = mode;
        final repaired = await assets.repairSubtitles(
          _task.copyWith(metadata: saved),
          directory,
        );
        expect(
          repaired.playbackStreams.where((s) => s['IsExternal'] == true),
          hasLength(1),
        );
        final local =
            repaired.playbackStreams.singleWhere(
                  (s) => s['IsExternal'] == true,
                )['DeliveryUrl']
                as String;
        expect(await File(local).readAsString(), _srt);
      }
    },
  );

  test(
    'successful refresh publishes a new revision without replacing old files',
    () async {
      final wire = _Wire('success');
      final api = DioDownloadTestApi(
        _session,
        dio: Dio()..httpClientAdapter = wire,
      );
      addTearDown(api.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-revisions-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final assets = EmbyDownloadAssetService(api);
      final saved = await assets.downloadAssets(_task, directory);
      String local(OfflineMediaMetadata metadata) =>
          metadata.playbackStreams.singleWhere(
                (s) => s['IsExternal'] == true,
              )['DeliveryUrl']
              as String;
      final same = await assets.repairSubtitles(
        _task.copyWith(metadata: saved),
        directory,
      );
      expect(local(same), local(saved));
      wire.replacementSubtitle = _srt.replaceAll(
        'Fixture subtitle',
        'Refreshed subtitle',
      );
      final updated = await assets.repairSubtitles(
        _task.copyWith(metadata: saved),
        directory,
      );
      expect(local(updated), isNot(local(saved)));
      expect(await File(local(saved)).readAsString(), _srt);
      expect(
        await File(local(updated)).readAsString(),
        wire.replacementSubtitle,
      );
      expect(updated.subtitlesNeedRepair, isFalse);
    },
  );

  for (final scenario in [
    ('pgs', 'srt', false, _srt),
    ('ass', 'vtt', false, _vtt),
    ('ssa', 'ssa', true, _ass),
    ('subrip', null, true, _srt),
  ]) {
    test(
      'negotiated sidecar preserves source identity through playback: ${scenario.$1}/${scenario.$2}',
      () async {
        final wire = _Wire('success')
          ..replacementSubtitle = scenario.$4
          ..overrideStreams = [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'Codec': scenario.$1,
              'Format': scenario.$2,
              'IsExternal': scenario.$3,
              'DeliveryMethod': 'External',
              'Language': 'chi',
              'Title': 'Fixture identity',
              if (scenario.$2 == 'vtt')
                'DeliveryUrl': '/Videos/item/source-B/Subtitles/4/Stream.vtt',
            },
          ];
        final api = DioDownloadTestApi(
          _session,
          dio: Dio()..httpClientAdapter = wire,
        );
        addTearDown(api.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'negotiated-sidecar-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final assets = EmbyDownloadAssetService(api);
        final saved = await assets.downloadAssets(_task, directory);
        final stream = saved.mediaStreams.single;
        final extension = scenario.$2 ?? 'srt';
        expect(stream['Index'], 4);
        expect(stream['Codec'], scenario.$1);
        expect(stream['IsExternal'], scenario.$3);
        expect(stream['Format'], extension);
        expect(stream['Title'], 'Fixture identity');
        expect(stream['OfflineSubtitleState'], 'available');
        expect(saved.subtitlesNeedRepair, isFalse);
        final local = File(stream['DeliveryUrl'] as String);
        expect(local.path, endsWith('.$extension'));
        expect(await local.readAsString(), scenario.$4);
        expect(saved.assetPaths, contains(local.path));
        expect(
          wire.requests
              .where((r) => r.path.contains('/Subtitles/'))
              .single
              .path,
          endsWith('/Videos/item/source-B/Subtitles/4/Stream.$extension'),
        );
        final verified = await verifyOfflineAssets(saved, directory: directory);
        expect(verified.playbackStreams.single, stream);
        final video = File(
          '${directory.path}${Platform.pathSeparator}video.mkv',
        );
        await video.writeAsBytes([1, 2, 3, 4]);
        final offline = OfflineMediaItem(
          scope: _task.scope,
          itemId: _task.itemId,
          mediaSourceId: _task.mediaSourceId,
          metadata: verified,
          localMediaPath: video.path,
          completedAt: DateTime.utc(2026),
        );
        final resolver = OfflinePlaybackResolver(offline);
        final engine = _ExternalEngine();
        final controller = PlaybackController(
          item: offline.toEmbyItem(),
          engine: engine,
          resolver: resolver,
          reporter: OfflinePlaybackReporter(
            item: offline,
            writeProgress: (_, _) async {},
          ),
          playbackHeaders: const {},
        );
        addTearDown(() async {
          await controller.shutdown();
          controller.dispose();
        });
        await controller.start();
        expect(controller.state.phase, PlaybackPhase.ready);
        final track = const TrackMapper()
            .fromPlan(controller.state.plan!, 'subtitle')
            .single;
        expect(
          track.deliveryFor(controller.state.plan!),
          SubtitleDelivery.external,
        );
        expect(controller.localSubtitleChoices, hasLength(1));
        await controller.selectLocalSubtitle(
          controller.localSubtitleChoices.single,
        );
        expect(
          controller.state.subtitleSelectionStatus,
          SubtitleSelectionStatus.appliedExternal,
        );
        expect(engine.externalLoads, [local.uri]);
        expect(engine.subtitleSelections.whereType<String>(), isEmpty);
        expect(
          SubtitlePresentation.fromState(controller.state).textStyle,
          isTrue,
        );
        expect(SubtitlePresentation.activeCodec(controller.state), extension);
        expect(engine.openedUri, video.uri);
        // Failed refresh and a later negotiation back to Embed retain one identity.
        wire.mode = '503';
        final failedRefresh = await assets.repairSubtitles(
          _task.copyWith(metadata: saved),
          directory,
        );
        expect(failedRefresh.playbackStreams.single['DeliveryUrl'], local.path);
        expect(failedRefresh.playbackStreams.single['Codec'], scenario.$1);
        expect(
          failedRefresh.playbackStreams.single['OfflineSubtitleError'],
          'refreshFailed',
        );
        wire.mode = 'success';
        wire.overrideStreams = [
          {
            ...wire.overrideStreams!.single,
            'IsExternal': false,
            'DeliveryMethod': 'Embed',
          },
        ];
        wire.requests.clear();
        final embedded = await assets.repairSubtitles(
          _task.copyWith(metadata: saved),
          directory,
        );
        expect(embedded.mediaStreams, hasLength(1));
        expect(embedded.playbackStreams.single['DeliveryUrl'], local.path);
        expect(
          wire.requests.where((r) => r.path.contains('/Subtitles/')),
          isEmpty,
        );
        final now = DateTime.utc(2026, 10, 16);
        await local.setLastModified(now.subtract(const Duration(days: 8)));
        final cleanup = await DownloadCleanup(now: () => now).run(
          directory: directory,
          tasks: [_task.copyWith(metadata: embedded, finalPath: video.path)],
        );
        expect(cleanup.deletedFiles, 0);
        expect(await local.readAsString(), scenario.$4);
      },
    );
  }

  for (final scenario in [
    ('pgs', null, 'unsupported'),
    ('subrip', 'pgs', 'unsupported'),
    ('ass', 'vtt', 'failed'),
  ]) {
    test(
      'does not guess or mislabel delivered subtitle conversion: ${scenario.$1}/${scenario.$2}',
      () async {
        final wire = _Wire('success')
          ..overrideStreams = [
            {
              'Index': 4,
              'Type': 'Subtitle',
              'Codec': scenario.$1,
              'Format': scenario.$2,
              'IsExternal': false,
              'DeliveryMethod': 'External',
            },
          ];
        final api = DioDownloadTestApi(
          _session,
          dio: Dio()..httpClientAdapter = wire,
        );
        addTearDown(api.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'unsupported-delivery-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final saved = await EmbyDownloadAssetService(
          api,
        ).downloadAssets(_task, directory);
        expect(saved.mediaStreams.single['OfflineSubtitleState'], scenario.$3);
        expect(saved.mediaStreams.single['Codec'], scenario.$1);
        expect(saved.playbackStreams, isEmpty);
        expect(saved.subtitlesNeedRepair, isTrue);
        expect(saved.assetPaths, isEmpty);
        expect(
          wire.requests.where((r) => r.path.contains('/Subtitles/')),
          hasLength(scenario.$3 == 'unsupported' ? 0 : 1),
        );
        expect(
          await directory
              .list(recursive: true)
              .where((e) => e is File)
              .toList(),
          isEmpty,
        );
      },
    );
  }

  test('cancel during subtitle body leaves no published subtitle', () async {
    final token = CancelToken();
    final wire = _Wire('success')
      ..onSubtitle = () => token.cancel('fixture cancel');
    final api = DioDownloadTestApi(
      _session,
      dio: Dio()..httpClientAdapter = wire,
    );
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
  String mode;
  final requests = <RequestOptions>[];
  void Function()? onSubtitle;
  String get extension => ['ass', 'vtt'].contains(mode) ? mode : 'srt';
  String? replacementSubtitle;
  String get subtitle =>
      replacementSubtitle ??
      (mode == 'ass'
          ? _ass
          : mode == 'vtt'
          ? _vtt
          : _srt);
  List<Map<String, dynamic>>? overrideStreams;
  List<Map<String, dynamic>> get streams =>
      overrideStreams ??
      (mode == 'no-subtitles'
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
            ]);
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

class _ExternalEngine extends RoutePlaybackEngine {
  final externalLoads = <Uri>[];
  @override
  Future<void> loadExternalSubtitle(
    Uri uri, {
    String? title,
    String? language,
  }) async {
    externalLoads.add(uri);
  }
}
