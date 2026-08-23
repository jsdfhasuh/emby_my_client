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

  test(
    'preserves offline subtitle default and explicit disable semantics',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'emby-offline-subtitle-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}offline-video.mkv',
      );
      await file.writeAsBytes([1, 2, 3, 4]);
      final offline = _offline(
        file.path,
        mediaStreams: const [
          {
            'Index': 3,
            'Type': 'Subtitle',
            'IsDefault': true,
            'DisplayTitle': 'Chinese',
          },
        ],
      );
      final resolver = OfflinePlaybackResolver(offline);

      final defaultPlan = await resolver.resolve(offline.toEmbyItem());
      final disabledPlan = await resolver.resolve(
        offline.toEmbyItem(),
        subtitleDisabled: true,
      );

      expect(defaultPlan.subtitleStreamIndex, 3);
      expect(defaultPlan.subtitleDisabled, isFalse);
      expect(
        defaultPlan.availableMediaSources.single.defaultSubtitleStreamIndex,
        3,
      );
      expect(disabledPlan.subtitleStreamIndex, isNull);
      expect(disabledPlan.subtitleDisabled, isTrue);
    },
  );

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

OfflineMediaItem _offline(
  String path, {
  int? runtimeTicks,
  List<Map<String, dynamic>> mediaStreams = const [],
}) => OfflineMediaItem(
  scope: const ServerScope(serverId: 'server-1', userId: 'user-1'),
  itemId: 'item-1',
  mediaSourceId: 'source-1',
  metadata: OfflineMediaMetadata(
    name: 'Offline item',
    itemType: 'Movie',
    container: 'mkv',
    runTimeTicks: runtimeTicks,
    mediaStreams: mediaStreams,
  ),
  localMediaPath: path,
  completedAt: DateTime.utc(2026, 7, 30),
);
