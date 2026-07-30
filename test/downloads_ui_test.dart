import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/downloads/download_repository.dart';
import 'package:emby_my_client/downloads/download_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/downloads/downloads_screen.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('detail presents a download action for a playable item', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create();
    });
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ItemDetailScreen(
          api: harness.api,
          initialItem: _item,
          downloads: harness.service,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('downloads screen presents offline playback and delete dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create(withCompletedDownload: true);
    });
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DownloadsScreen(api: harness.api, downloads: harness.service),
      ),
    );
    await tester.pump();

    expect(find.text('Offline Test'), findsOneWidget);
    expect(find.textContaining('可离线播放'), findsOneWidget);
    expect(find.byTooltip('离线播放'), findsOneWidget);

    await tester.tap(find.byTooltip('删除离线文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除离线文件？'), findsOneWidget);
    expect(find.textContaining('Offline Test'), findsWidgets);
    await tester.tap(find.text('保留'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除离线文件？'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _UiHarness {
  _UiHarness({
    required this.directory,
    required this.api,
    required this.service,
  });

  final Directory directory;
  final EmbyApi api;
  final DownloadService service;

  static Future<_UiHarness> create({bool withCompletedDownload = false}) async {
    final directory = await Directory.systemTemp.createTemp('emby-ui-test-');
    final store = _MemoryDownloadStore();
    if (withCompletedDownload) {
      final finalPath =
          '${directory.path}${Platform.pathSeparator}offline-test.mkv';
      await File(finalPath).writeAsBytes(_mediaBytes);
      final now = DateTime.utc(2026, 7, 30);
      final task = DownloadTaskRecord(
        id: 'task-1',
        scope: _scope,
        itemId: _item.id,
        mediaSourceId: 'source-1',
        sourceKind: DownloadSourceKind.original,
        sourceFingerprint: 'test-source',
        status: DownloadStatus.completed,
        downloadedBytes: _mediaBytes.length,
        retryCount: 0,
        tempPath: '$finalPath.part',
        finalPath: finalPath,
        metadata: OfflineMediaMetadata.fromItem(
          _item,
          _item.mediaSources.single,
        ),
        createdAt: now,
        updatedAt: now,
        expectedBytes: _mediaBytes.length,
      );
      await store.complete(
        task,
        OfflineMediaItem(
          scope: _scope,
          itemId: _item.id,
          mediaSourceId: task.mediaSourceId,
          metadata: task.metadata,
          localMediaPath: finalPath,
          completedAt: now,
        ),
      );
    }
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: _itemJson,
              ),
            );
          },
        ),
      );
    final api = EmbyApi(_session, dio: dio);
    final service = DownloadService(
      api: api,
      scope: _scope,
      repository: store,
      directoryResolver: (_) async => directory,
    );
    await service.initialize();
    return _UiHarness(directory: directory, api: api, service: service);
  }

  Future<void> dispose() async {
    await service.shutdown();
    service.dispose();
    await api.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _MemoryDownloadStore implements DownloadStore {
  final Map<String, DownloadTaskRecord> _tasks = {};
  final Map<String, OfflineMediaItem> _items = {};
  final Map<String, OfflineProgressRecord> _progress = {};

  String _key(ServerScope scope, String itemId) =>
      '${scope.databaseKey}:$itemId';

  @override
  Future<List<DownloadTaskRecord>> listTasks(ServerScope scope) async {
    return _tasks.values
        .where((task) => task.scope == scope)
        .toList(growable: false);
  }

  @override
  Future<void> saveTask(DownloadTaskRecord task) async {
    _tasks[task.id] = task;
  }

  @override
  Future<void> complete(DownloadTaskRecord task, OfflineMediaItem item) async {
    await saveTask(task);
    _items[_key(item.scope, item.itemId)] = item;
  }

  @override
  Future<List<OfflineMediaItem>> listOfflineItems(ServerScope scope) async {
    return _items.values
        .where((item) => item.scope == scope)
        .toList(growable: false);
  }

  @override
  Future<OfflineMediaItem?> offlineItem(
    ServerScope scope,
    String itemId,
  ) async {
    return _items[_key(scope, itemId)];
  }

  @override
  Future<void> saveProgress(OfflineProgressRecord progress) async {
    _progress[_key(progress.scope, progress.itemId)] = progress;
  }

  @override
  Future<OfflineProgressRecord?> loadProgress(
    ServerScope scope,
    String itemId,
  ) async => _progress[_key(scope, itemId)];

  @override
  Future<List<OfflineProgressRecord>> listPendingProgress(
    ServerScope scope, {
    required DateTime now,
  }) async {
    return _progress.values
        .where(
          (progress) =>
              progress.scope == scope &&
              progress.syncStatus != 'synced' &&
              (progress.retryAfter == null ||
                  !progress.retryAfter!.isAfter(now)),
        )
        .toList(growable: false);
  }

  @override
  Future<void> removeOfflineItem(DownloadTaskRecord task) async {
    _items.remove(_key(task.scope, task.itemId));
  }

  @override
  Future<void> removeDownload(DownloadTaskRecord task) async {
    _tasks.remove(task.id);
    _items.remove(_key(task.scope, task.itemId));
    _progress.remove(_key(task.scope, task.itemId));
  }
}

const _scope = ServerScope(serverId: 'server-1', userId: 'user-1');

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
  name: 'Offline Test',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
  mediaSources: [
    PlaybackMediaSource(
      id: 'source-1',
      supportsDirectPlay: true,
      supportsDirectStream: true,
      supportsTranscoding: true,
      mediaStreams: [],
      transcodingReasons: [],
      container: 'mkv',
      size: 12,
    ),
  ],
);

const _itemJson = <String, dynamic>{
  'Id': 'item-1',
  'Name': 'Offline Test',
  'Type': 'Movie',
  'MediaType': 'Video',
  'RunTimeTicks': 600000000,
  'MediaSources': [
    {
      'Id': 'source-1',
      'SupportsDirectPlay': true,
      'SupportsDirectStream': true,
      'SupportsTranscoding': true,
      'Container': 'mkv',
      'Size': 12,
      'MediaStreams': <dynamic>[],
    },
  ],
};

const _mediaBytes = <int>[
  0x1A,
  0x45,
  0xDF,
  0xA3,
  0x93,
  0x42,
  0x82,
  0x88,
  0x6D,
  0x61,
  0x74,
  0x72,
];
