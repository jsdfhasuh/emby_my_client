import 'dart:io';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/offline/offline_playback_reporter.dart';
import 'package:emby_my_client/offline/offline_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves a verified local file without transcode fallback', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-offline-playback-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}offline-video.mkv',
    );
    await file.writeAsBytes([1, 2, 3, 4]);
    final offline = _offline(file.path, runtimeTicks: 36000000000);
    final resolver = OfflinePlaybackResolver(offline);

    final plan = await resolver.resolve(offline.toEmbyItem());

    expect(resolver.canForceTranscode, isFalse);
    expect(plan.uri, file.uri);
    expect(plan.playSessionId, isNull);
    expect(plan.usesServerAuthentication, isFalse);
    expect(plan.transportKind, PlaybackTransportKind.offlineLocal);
    expect(plan.duration, const Duration(hours: 1));
    expect(
      () => resolver.resolve(offline.toEmbyItem(), forceTranscode: true),
      throwsStateError,
    );
  });

  test('rejects an empty local file without online fallback', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emby-offline-empty-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}empty.mkv');
    await file.create();
    final offline = _offline(file.path);
    final resolver = OfflinePlaybackResolver(offline);

    expect(
      () => resolver.resolve(offline.toEmbyItem()),
      throwsA(isA<FileSystemException>()),
    );
    expect(resolver.canForceTranscode, isFalse);
  });

  test('writes offline progress without an online session report', () async {
    final writes = <(Duration, bool)>[];
    final reporter = OfflinePlaybackReporter(
      item: _offline('offline.mkv', runtimeTicks: 100000000),
      writeProgress: (position, played) async {
        writes.add((position, played));
      },
    );

    await reporter.reportProgress(
      position: const Duration(seconds: 5),
      isPaused: false,
    );
    await reporter.stop(const Duration(seconds: 9));

    expect(writes.first, (const Duration(seconds: 5), false));
    expect(writes.last, (const Duration(seconds: 9), true));
  });
}

OfflineMediaItem _offline(String path, {int? runtimeTicks}) => OfflineMediaItem(
  scope: const ServerScope(serverId: 'server-1', userId: 'user-1'),
  itemId: 'item-1',
  mediaSourceId: 'source-1',
  metadata: OfflineMediaMetadata(
    name: 'Offline item',
    itemType: 'Movie',
    container: 'mkv',
    runTimeTicks: runtimeTicks,
    mediaStreams: const [],
  ),
  localMediaPath: path,
  completedAt: DateTime.utc(2026, 7, 30),
);
