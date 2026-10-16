import 'dart:io';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/ui/downloads/downloads_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/synthetic_download_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real service verifies generated media and sidecar and records local progress',
    () async {
      final fixture = await SyntheticDownloadFixture.create();
      addTearDown(fixture.close);
      final task = fixture.downloads.taskForItem(fixture.itemId)!;
      expect(task.id, fixture.taskId);
      expect(task.status, DownloadStatus.completed);
      expect(task.integrity, isNotNull);
      final item = (await fixture.downloads.offlineItem(fixture.itemId))!;
      expect(item.localMediaPath, fixture.mediaFile.path);
      expect(await fixture.mediaFile.length(), task.expectedBytes);
      final subtitle = item.metadata.playbackStreams.singleWhere(
        (stream) => stream['IsExternal'] == true,
      );
      expect(subtitle['Index'], 5);
      expect(subtitle['DeliveryUrl'], fixture.subtitleFile.path);
      expect(subtitle['OfflineSubtitleState'], 'available');
      expect(
        await fixture.subtitleFile.readAsString(),
        contains('EXTERNAL_CUE'),
      );
      expect(item.metadata.subtitlesNeedRepair, isFalse);
      await fixture.downloads.recordOfflineProgress(
        item,
        const Duration(seconds: 5),
        played: false,
      );
      final reopened = (await fixture.downloads.offlineItem(fixture.itemId))!;
      expect(reopened.progress!.positionTicks, 50000000);
      expect(reopened.toEmbyItem().userData.playbackPositionTicks, 50000000);
      expect(fixture.networkAttempts, 0);
      expect(
        await fixture.store.offlineItem(
          const ServerScope(serverId: 'other', userId: 'other'),
          fixture.itemId,
        ),
        isNull,
      );
      final directory = fixture.directory.path;
      final closing = fixture.close();
      expect(fixture.close(), same(closing));
      await closing;
      expect(fixture.closed, isTrue);
      expect(await Directory(directory).exists(), isFalse);
    },
  );

  test(
    'fixture API blocks attempts before opening any network connection',
    () async {
      final fixture = await SyntheticDownloadFixture.create();
      addTearDown(fixture.close);
      await expectLater(fixture.api.getItem(fixture.itemId), throwsA(anything));
      expect(fixture.networkAttempts, 1);
      expect(await fixture.downloads.offlineItem(fixture.itemId), isNotNull);
    },
  );

  testWidgets(
    'production DownloadsScreen exposes the completed local download action',
    (tester) async {
      late SyntheticDownloadFixture fixture;
      await tester.runAsync(() async {
        fixture = await SyntheticDownloadFixture.create();
      });
      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: DownloadsScreen(
                api: fixture.api,
                downloads: fixture.downloads,
              ),
            ),
          );
        });
        await tester.runAsync(() async {
          await fixture.downloads.offlineItems();
        });
        await tester.pump();
        final play = find.byKey(ValueKey('download-play-${fixture.taskId}'));
        expect(play, findsOneWidget);
        expect(tester.widget<IconButton>(play).onPressed, isNotNull);
        expect(fixture.networkAttempts, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      }
    },
  );
}
