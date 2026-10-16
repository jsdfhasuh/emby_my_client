import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage_scope.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_settings_scope.dart';
import 'package:emby_my_client/playback/subtitle_preferences_repository.dart';
import 'package:emby_my_client/playback/subtitle_preferences_scope.dart';
import 'package:emby_my_client/ui/downloads/downloads_screen.dart';
import 'package:emby_my_client/ui/player_playback_backend.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/route_playback_engine.dart';
import 'support/synthetic_download_fixture.dart';

void main() {
  testWidgets('failed offline startup returns through the visible error button', (
    tester,
  ) async {
    late SyntheticDownloadFixture fixture;
    await tester.runAsync(() async {
      fixture = await SyntheticDownloadFixture.create();
    });
    final storage = _Storage();
    final settings = PlaybackSettingsRepository(storage: storage);
    final preferences = SubtitlePreferencesRepository(storage: storage);
    final engine = _FailedEngine();
    try {
      await tester.pumpWidget(
        PlayerPlaybackBackendScope(
          create: () => PlayerPlaybackBackend(
            engine: engine,
            buildVideo: (_) => const SizedBox(),
          ),
          child: PlaybackCacheStorageScope(
            storage: PlatformPlaybackCacheStorage(
              rootResolver: () async => fixture.directory,
              freeBytesResolver: (_) async => 1000000000,
            ),
            child: SubtitlePreferencesRepositoryScope(
              repository: preferences,
              child: PlaybackSettingsRepositoryScope(
                repository: settings,
                child: MaterialApp(
                  home: DownloadsScreen(
                    api: fixture.api,
                    downloads: fixture.downloads,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _flush(tester);
      await tester.tap(find.byKey(ValueKey('download-play-${fixture.taskId}')));
      for (var i = 0; i < 30 && engine.disposals == 0; i++) {
        await _flush(tester);
      }
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.text('播放失败，请返回后重试'), findsOneWidget);
      expect(engine.disposals, 1);
      // The controls timer may hide the normal toolbar while the error remains.
      await tester.pump(const Duration(seconds: 5));
      final back = find.byKey(const ValueKey('player-error-back'));
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      for (
        var i = 0;
        i < 50 && find.byType(PlayerScreen).evaluate().isNotEmpty;
        i++
      ) {
        await _flush(tester);
      }
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byType(DownloadsScreen), findsOneWidget);
      expect(
        find.byKey(ValueKey('download-play-${fixture.taskId}')).hitTestable(),
        findsOneWidget,
      );
      expect(engine.disposals, 1);
      expect(fixture.networkAttempts, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      await tester.runAsync(fixture.close);
      final closing = Future.wait([settings.dispose(), preferences.dispose()]);
      await tester.pump();
      await closing;
    }
    expect(fixture.closed, isTrue);
    expect(await tester.runAsync(() => fixture.directory.exists()), isFalse);
  });
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

class _FailedEngine extends RoutePlaybackEngine {
  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    required bool play,
  }) async {
    if (uri.scheme != 'file') throw StateError('Fixture must remain local');
    throw StateError('Controlled offline native open failure');
  }
}

class _Storage implements PlaybackSettingsStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
