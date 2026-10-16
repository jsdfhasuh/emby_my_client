import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:emby_my_client/downloads/download_integrity.dart';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/browse_cache.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:emby_my_client/downloads/download_assets.dart';
import 'package:emby_my_client/downloads/download_preflight.dart';
import 'package:emby_my_client/downloads/download_repository.dart';
import 'package:emby_my_client/downloads/download_service.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage_scope.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_settings_scope.dart';
import 'package:emby_my_client/ui/downloads/downloads_screen.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:emby_my_client/ui/player_playback_backend.dart';
import 'package:emby_my_client/ui/widgets/playback_timeline.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';

void main() {
  _subtitleRouteTests();
  testWidgets('stale browsing data does not block online playback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create();
    });
    addTearDown(() => _disposeUiHarness(tester, harness));
    harness.api.browseState.cached(
      'fixture',
      BrowseSnapshot({}, DateTime.utc(2026)),
      disconnected: false,
    );
    final observer = _PlayerRouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: ItemDetailScreen(
          api: harness.api,
          initialItem: _item,
          downloads: harness.service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final play = find.text('播放');
    await tester.ensureVisible(play);
    await tester.tap(play);
    for (var i = 0; i < 50 && observer.playerRoute == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    final route = observer.playerRoute;
    expect(route, isNotNull);
    final player = route!.builder(observer.navigator!.context) as PlayerScreen;
    expect(player.offlineItem, isNull);
    observer.navigator!.removeRoute(route);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final offline in [false, true]) {
    testWidgets(
      'normal detail play opens the downloaded file, offline=$offline',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late final _UiHarness harness;
        await tester.runAsync(() async {
          harness = await _UiHarness.create(withCompletedDownload: true);
        });
        addTearDown(() => _disposeUiHarness(tester, harness));
        if (offline) {
          harness.api.browseState.cached(
            'fixture',
            BrowseSnapshot({}, DateTime.utc(2026)),
            disconnected: true,
          );
        }
        final observer = _PlayerRouteObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: ItemDetailScreen(
              api: harness.api,
              initialItem: _item,
              downloads: harness.service,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final play = find.text('播放');
        await tester.ensureVisible(play);
        await tester.tap(play);
        // Resolve the local file checks before building the native player. This
        // asserts the real UI route/arguments, not native rendering or decoding.
        for (var i = 0; i < 50 && observer.playerRoute == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        final route = observer.playerRoute;
        expect(route, isNotNull);
        final player =
            route!.builder(observer.navigator!.context) as PlayerScreen;
        expect(player.offlineItem?.itemId, _item.id);
        expect(player.offlineItem?.mediaSourceId, 'source-1');
        expect(player.offlineItem?.scope, _scope);
        expect(player.downloads, same(harness.service));
        observer.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'normal detail play clearly rejects an undownloaded item offline',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late final _UiHarness harness;
      await tester.runAsync(() async {
        harness = await _UiHarness.create();
      });
      addTearDown(() => _disposeUiHarness(tester, harness));
      harness.api.browseState.cached(
        'fixture',
        BrowseSnapshot({}, DateTime.utc(2026)),
        disconnected: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ItemDetailScreen(
            api: harness.api,
            initialItem: _item,
            downloads: harness.service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(find.text('此视频尚无可用的本地下载，联网后可播放'), findsOneWidget);
      expect(find.byType(PlayerScreen), findsNothing);
    },
  );
  testWidgets('detail presents a download action for a playable item', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create();
    });
    addTearDown(() => _disposeUiHarness(tester, harness));

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

  testWidgets(
    'subtitle repair can be cancelled while preserving offline playback',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late _PendingRepairAssets assets;
      late _UiHarness harness;
      await tester.runAsync(() async {
        assets = _PendingRepairAssets();
        harness = await _UiHarness.create(
          withCompletedDownload: true,
          assetService: assets,
        );
      });
      addTearDown(() => _disposeUiHarness(tester, harness));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: DownloadsScreen(api: harness.api, downloads: harness.service),
        ),
      );
      late Future<void> repair;
      await tester.runAsync(() async {
        repair = harness.service.repairSubtitles('task-1');
        await assets.started.future.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(find.byTooltip('取消字幕修复（保留下载）'), findsOneWidget);
      expect(find.byTooltip('离线播放'), findsOneWidget);
      expect(find.textContaining('正在修复，可取消'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('取消字幕修复（保留下载）'));
      await tester.runAsync(() => repair.timeout(const Duration(seconds: 5)));
      await tester.pump();
      expect(find.textContaining('修复已取消'), findsOneWidget);
      expect(find.byTooltip('检查并补下载字幕'), findsOneWidget);
      expect(find.byTooltip('离线播放'), findsOneWidget);
      expect(harness.service.tasks.single.isComplete, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      var stopped = false;
      final stopping = harness.service.shutdown().then((_) => stopped = true);
      for (var attempt = 0; attempt < 100 && !stopped; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(
        stopped,
        isTrue,
        reason: 'Shutdown must drain all verification IO',
      );
      await stopping;
    },
  );

  for (final withDigest in [false, true]) {
    testWidgets(
      'cache check accurately reports digest availability: $withDigest',
      (tester) async {
        late _UiHarness harness;
        await tester.runAsync(() async {
          harness = await _UiHarness.create(
            withCompletedDownload: true,
            integrity: withDigest
                ? DownloadIntegrity.fromStored(
                    'sha-256',
                    base64Encode(sha256.convert(_mediaBytes).bytes),
                  )
                : null,
          );
        });
        addTearDown(() => _disposeUiHarness(tester, harness));
        await tester.pumpWidget(
          MaterialApp(
            home: DownloadsScreen(api: harness.api, downloads: harness.service),
          ),
        );
        await tester.tap(find.byTooltip('检查下载缓存'));
        final result = find.textContaining(
          withDigest ? '1 个通过摘要校验' : '1 个无摘要（仅检查文件头和大小）',
        );
        for (
          var attempt = 0;
          attempt < 100 && result.evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(result, findsOneWidget);
        expect(harness.service.tasks.single.isComplete, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('downloads screen presents offline playback and delete dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create(withCompletedDownload: true);
    });
    addTearDown(() => _disposeUiHarness(tester, harness));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DownloadsScreen(api: harness.api, downloads: harness.service),
      ),
    );
    await tester.pump();

    expect(find.text('Offline Test'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-video-task-1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('download-subtitles-task-1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('download-cover-task-1')), findsOneWidget);
    expect(find.text('服务器未提供封面'), findsOneWidget);
    expect(find.textContaining('视频可离线播放 · 12 B / 12 B'), findsOneWidget);
    expect(find.textContaining('字幕待检查，可补下载'), findsOneWidget);
    expect(find.byTooltip('检查并补下载字幕'), findsOneWidget);
    expect(find.text('媒体文件占用 12 B'), findsOneWidget);
    expect(find.text('1 个可离线播放'), findsOneWidget);
    expect(find.byTooltip('离线播放'), findsOneWidget);
    expect(find.byTooltip('检查下载缓存'), findsOneWidget);
    expect(find.byTooltip('清空下载缓存'), findsOneWidget);

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

  testWidgets(
    'downloads screen clears all cached downloads after confirmation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late final _UiHarness harness;
      await tester.runAsync(() async {
        harness = await _UiHarness.create(withCompletedDownload: true);
      });
      addTearDown(() => _disposeUiHarness(tester, harness));
      final mediaFile = File(harness.service.tasks.single.finalPath);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: DownloadsScreen(api: harness.api, downloads: harness.service),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('清空下载缓存'));
      await tester.pumpAndSettle();
      expect(find.text('清空下载缓存？'), findsOneWidget);
      expect(find.textContaining('预计释放 12 B'), findsOneWidget);

      final confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '清空'),
      );
      confirmButton.onPressed!();
      for (var attempt = 0; attempt < 20; attempt++) {
        if (harness.service.tasks.isEmpty ||
            harness.service.tasks.single.status == DownloadStatus.cancelling) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        harness.service.tasks.isEmpty ||
            harness.service.tasks.single.status == DownloadStatus.cancelling,
        isTrue,
      );
      for (
        var attempt = 0;
        attempt < 100 && harness.service.tasks.isNotEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      for (
        var attempt = 0;
        attempt < 20 && find.textContaining('已提交清理 1 项').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(harness.service.tasks, isEmpty);
      final mediaExists = await tester.runAsync(mediaFile.exists);
      expect(mediaExists, isFalse);
      expect(find.text('还没有离线内容'), findsOneWidget);
      expect(find.textContaining('已提交清理 1 项'), findsOneWidget);
      expect(find.byTooltip('清空下载缓存'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('downloads screen presents a pausable Wi-Fi waiting state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create(withWaitingDownload: true);
    });
    addTearDown(() => _disposeUiHarness(tester, harness));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DownloadsScreen(api: harness.api, downloads: harness.service),
      ),
    );
    await tester.pump();

    expect(find.textContaining('等待 Wi-Fi'), findsOneWidget);
    expect(find.textContaining('1 个未完成'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('downloads screen presents corrupt media as a fresh download', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create(withCorruptDownload: true);
    });
    addTearDown(() => _disposeUiHarness(tester, harness));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DownloadsScreen(api: harness.api, downloads: harness.service),
      ),
    );
    await tester.pump();

    expect(find.text('视频：本地文件损坏 · 4 B / 12 B'), findsOneWidget);
    expect(find.byTooltip('重新下载'), findsOneWidget);
    expect(find.byTooltip('离线播放'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail presents a fresh download action for corrupt media', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create(withCorruptDownload: true);
    });
    addTearDown(() => _disposeUiHarness(tester, harness));

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

    expect(find.byTooltip('重新下载'), findsOneWidget);
    expect(find.byTooltip('离线播放'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('downloads screen presents a pausable storage waiting state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late final _UiHarness harness;
    await tester.runAsync(() async {
      harness = await _UiHarness.create(withStorageWaitingDownload: true);
    });
    addTearDown(() => _disposeUiHarness(tester, harness));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DownloadsScreen(api: harness.api, downloads: harness.service),
      ),
    );
    await tester.pump();

    expect(find.textContaining('等待存储空间'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _subtitleRouteTests() {
  for (final action in [
    'success',
    'codecFamily',
    'nativeConflict',
    'engineFailure',
    'metadataConflict',
    'disable',
    'audio',
  ]) {
    for (final repeat in [false, true]) {
      testWidgets(
        'offline player sheet preserves route: $action repeat=$repeat',
        (tester) async {
          final fixture = await _mountOfflinePlayer(tester, action: action);
          await tester.tap(find.byTooltip('播放设置'));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          await tester.tap(find.text(action == 'audio' ? '音轨' : '字幕'));
          await tester.pumpAndSettle();
          final label = action == 'disable'
              ? '关闭字幕'
              : action == 'audio'
              ? 'Route audio'
              : 'Route subtitle';
          final tile = action == 'nativeConflict'
              ? find.byKey(const ValueKey('native-subtitle-42'))
              : find.widgetWithText(ListTile, label);
          final callback = tester.widget<ListTile>(tile).onTap!;
          fixture.logs.clear();
          fixture.engine.subtitleSelections.clear();
          fixture.engine.audioSelections.clear();

          await tester.tap(tile);
          if (repeat) {
            // A second gesture may already be queued before the pop animation.
            callback();
            await tester.pump(const Duration(milliseconds: 80));
            callback();
          }
          await _flushRoute(tester);
          expect(
            fixture.observer.popped,
            hasLength(1),
            reason: 'Only the sheet may pop',
          );
          expect(
            fixture.observer.popped.single,
            isA<ModalBottomSheetRoute<dynamic>>(),
          );
          expect(find.byType(PlayerScreen), findsOneWidget);
          expect(find.byType(PlaybackSubtitleOptions), findsNothing);
          expect(fixture.engine.stops, 0);
          expect(fixture.engine.disposals, 0);
          expect(fixture.engine.isPlaying, isTrue);
          expect(
            fixture.logs.where(
              (line) =>
                  line.contains('event=player_route_dispose') ||
                  line.contains('event=player_exit_requested'),
            ),
            isEmpty,
          );
          if (action == 'audio') {
            expect(fixture.engine.audioSelections, ['7']);
          } else {
            expect(
              fixture.logs.where(
                (line) =>
                    line.contains('event=playback_subtitle_apply_requested'),
              ),
              hasLength(1),
            );
            expect(
              fixture.engine.subtitleSelections,
              action == 'metadataConflict'
                  ? isEmpty
                  : [action == 'disable' ? null : '42'],
            );
          }
          fixture.engine.positions.add(const Duration(seconds: 42));
          await tester.pump();
          expect(
            tester
                .widget<PlaybackTimeline>(find.byType(PlaybackTimeline))
                .value,
            const Duration(seconds: 42).inMilliseconds,
          );
          if (action == 'engineFailure' || action == 'metadataConflict') {
            await tester.tap(find.byTooltip('播放设置'));
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pumpAndSettle();
            await tester.tap(find.text('字幕'));
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(PlaybackSubtitleOptions),
                matching: find.textContaining(
                  action == 'metadataConflict' ? '无法确认服务器字幕' : '字幕未能加载，原因尚未确认',
                ),
              ),
              findsOneWidget,
            );
            expect(
              tester
                  .widget<ListTile>(
                    find.widgetWithText(ListTile, 'Route subtitle'),
                  )
                  .onTap,
              isNotNull,
            );
          }
          // Leaving the player must return to the same download list after
          // successful selection, failure, disable, and repeated gestures.
          if (find.byType(BottomSheet).evaluate().isNotEmpty) {
            Navigator.of(tester.element(find.byType(BottomSheet))).pop();
            await _flushRoute(tester);
          }
          Navigator.of(tester.element(find.byType(PlayerScreen))).pop();
          await _flushRoute(tester);
          expect(find.byType(PlayerScreen), findsNothing);
          expect(find.byType(DownloadsScreen), findsOneWidget);
          expect(fixture.engine.disposals, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final phase in ['closing', 'dismissed', 'playerDisposed']) {
    testWidgets('offline player ignores subtitle callback: $phase', (
      tester,
    ) async {
      final fixture = await _mountOfflinePlayer(tester);
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('字幕'));
      await tester.pumpAndSettle();
      final tile = find.widgetWithText(ListTile, 'Route subtitle');
      final callback = tester.widget<ListTile>(tile).onTap!;
      Navigator.of(tester.element(tile)).pop();
      if (phase != 'closing') await tester.pumpAndSettle();
      if (phase == 'playerDisposed') {
        await tester.pumpWidget(const SizedBox.shrink());
        await _flushRoute(tester);
      }
      fixture.logs.clear();
      callback();
      await _flushRoute(tester);
      expect(fixture.observer.popped, hasLength(1));
      expect(
        find.byType(PlayerScreen),
        phase == 'playerDisposed' ? findsNothing : findsOneWidget,
      );
      expect(fixture.engine.disposals, phase == 'playerDisposed' ? 1 : 0);
      expect(fixture.engine.stops, phase == 'playerDisposed' ? 1 : 0);
      expect(
        fixture.logs.where(
          (line) => line.contains('event=playback_subtitle_apply_requested'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'offline player opens only one settings sheet for repeated requests',
    (tester) async {
      final fixture = await _mountOfflinePlayer(tester);
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '播放设置',
        ),
      );
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet, skipOffstage: false), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await _flushRoute(tester);
      expect(fixture.observer.popped, hasLength(1));
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(fixture.engine.disposals, 0);
    },
  );
}

Future<void> _flushRoute(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<
  ({
    RoutePlaybackEngine engine,
    _FullPlayerRouteObserver observer,
    List<String> logs,
  })
>
_mountOfflinePlayer(WidgetTester tester, {String action = 'success'}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 700));
  late final _UiHarness harness;
  await tester.runAsync(() async {
    harness = await _UiHarness.create(
      withCompletedDownload: true,
      mediaStreams: [
        {
          'Type': 'Subtitle',
          'Index': 2,
          'DisplayTitle': 'Route subtitle',
          'Language': 'chi',
          'Codec': action == 'codecFamily' ? 'ssa' : 'srt',
          'IsDefault': action == 'disable',
        },
        {
          'Type': 'Audio',
          'Index': 1,
          'DisplayTitle': 'Route audio',
          'Language': 'eng',
          'Codec': 'aac',
        },
      ],
    );
  });
  final engine = RoutePlaybackEngine()
    ..matroskaFamily = action == 'codecFamily'
    ..failSubtitle = action == 'engineFailure'
    ..conflictingMetadata =
        action == 'metadataConflict' || action == 'nativeConflict';
  final observer = _FullPlayerRouteObserver();
  final logs = <String>[];
  DiagnosticLog.instance.setTestSink(logs.add);
  final settings = PlaybackSettingsRepository(storage: _RouteSettingsStorage());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flushRoute(tester);
    await tester.runAsync(harness.dispose);
    settings.dispose();
    DiagnosticLog.instance.setTestSink(null);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    PlayerPlaybackBackendScope(
      create: () => PlayerPlaybackBackend(
        engine: engine,
        buildVideo: (_) => const ColoredBox(color: Colors.black),
      ),
      child: PlaybackSettingsRepositoryScope(
        repository: settings,
        child: PlaybackCacheStorageScope(
          storage: PlatformPlaybackCacheStorage(
            rootResolver: () async => harness.directory,
            freeBytesResolver: (_) async => 1000000000,
          ),
          child: MaterialApp(
            navigatorObservers: [observer],
            home: DownloadsScreen(api: harness.api, downloads: harness.service),
          ),
        ),
      ),
    ),
  );
  await _flushRoute(tester);
  await tester.tap(find.byTooltip('离线播放'));
  await _flushRoute(tester);
  expect(find.byType(PlayerScreen), findsOneWidget);
  expect(engine.openedUri?.scheme, 'file');
  expect(engine.isPlaying, isTrue);
  expect(engine.disposals, 0);
  return (engine: engine, observer: observer, logs: logs);
}

class _RouteSettingsStorage implements PlaybackSettingsStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _FullPlayerRouteObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      popped.add(route);
}

class _PlayerRouteObserver extends NavigatorObserver {
  MaterialPageRoute<dynamic>? playerRoute;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null && route is MaterialPageRoute<dynamic>) {
      playerRoute = route;
    }
  }
}

// File IO from initState completes through Flutter's fake async zone. Keep
// pumping during shutdown so all tracked checks drain before deleting fixtures.
Future<void> _disposeUiHarness(WidgetTester tester, _UiHarness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var stopped = false;
  final stopping = harness.service.shutdown().whenComplete(
    () => stopped = true,
  );
  for (var attempt = 0; attempt < 100 && !stopped; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(
    stopped,
    isTrue,
    reason: 'Shutdown must drain verification IO before fixture deletion',
  );
  await stopping;
  await tester.runAsync(harness.dispose);
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

  static Future<_UiHarness> create({
    bool withCompletedDownload = false,
    bool withCorruptDownload = false,
    bool withWaitingDownload = false,
    bool withStorageWaitingDownload = false,
    List<Map<String, dynamic>>? mediaStreams,
    DownloadAssetService? assetService,
    DownloadIntegrity? integrity,
  }) async {
    final directory = await Directory.systemTemp.createTemp('emby-ui-test-');
    final store = _MemoryDownloadStore();
    if (withCompletedDownload || withCorruptDownload) {
      final finalPath =
          '${directory.path}${Platform.pathSeparator}offline-test.mkv';
      await File(finalPath).writeAsBytes(
        withCorruptDownload ? _mediaBytes.sublist(0, 4) : _mediaBytes,
      );
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
        ).copyWith(mediaStreams: mediaStreams),
        createdAt: now,
        updatedAt: now,
        expectedBytes: _mediaBytes.length,
        integrity: integrity,
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
    if (withWaitingDownload || withStorageWaitingDownload) {
      final finalPath =
          '${directory.path}${Platform.pathSeparator}waiting-test.mkv';
      final now = DateTime.utc(2026, 7, 30);
      await store.saveTask(
        DownloadTaskRecord(
          id: 'task-waiting',
          scope: _scope,
          itemId: _item.id,
          mediaSourceId: 'source-1',
          sourceKind: DownloadSourceKind.original,
          sourceFingerprint: 'test-source',
          status: withStorageWaitingDownload
              ? DownloadStatus.waitingForStorage
              : DownloadStatus.waitingForNetwork,
          downloadedBytes: 4,
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
          lastErrorCode: withStorageWaitingDownload
              ? 'insufficientStorage'
              : 'wifiRequired',
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
      assetService: assetService,
      directoryResolver: (_) async => directory,
      preflight: withWaitingDownload ? const _WifiBlockedPreflight() : null,
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

class _WifiBlockedPreflight implements DownloadPreflight {
  const _WifiBlockedPreflight();

  @override
  Stream<void> get networkChanges => const Stream<void>.empty();

  @override
  Future<void> verifyNetwork({required bool wifiOnly}) {
    throw const DownloadPreflightException(
      code: 'wifiRequired',
      message: 'wifi required',
    );
  }

  @override
  Future<void> verifyStorage({
    required Directory directory,
    required int? expectedBytes,
    required int downloadedBytes,
  }) async {}
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
  Future<bool> saveProgressIfUnchanged(
    OfflineProgressRecord expected,
    OfflineProgressRecord replacement,
  ) async {
    final key = _key(expected.scope, expected.itemId);
    final current = _progress[key];
    if (current == null ||
        current.scope != expected.scope ||
        current.itemId != expected.itemId ||
        current.positionTicks != expected.positionTicks ||
        current.played != expected.played ||
        current.updatedAt != expected.updatedAt ||
        current.syncStatus != expected.syncStatus ||
        current.retryAfter != expected.retryAfter) {
      return false;
    }
    _progress[key] = replacement;
    return true;
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
    bool includeDeferred = false,
  }) async {
    return _progress.values
        .where(
          (progress) =>
              progress.scope == scope &&
              progress.syncStatus != 'synced' &&
              (includeDeferred ||
                  progress.retryAfter == null ||
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

class _PendingRepairAssets implements DownloadAssetService {
  final started = Completer<void>();
  @override
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory directory, {
    CancelToken? cancelToken,
  }) async {
    started.complete();
    throw await cancelToken!.whenCancel;
  }
}
