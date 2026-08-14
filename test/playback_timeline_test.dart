import 'dart:ui' show SemanticsAction;

import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
import 'package:emby_my_client/ui/widgets/playback_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes, clamps, and merges complete cache ranges', () {
    final ranges = normalizePlaybackTimelineCacheRanges(
      duration: const Duration(seconds: 100),
      ranges: const [
        PlaybackCacheRange(
          start: Duration(seconds: -10),
          end: Duration(seconds: 10),
        ),
        PlaybackCacheRange(
          start: Duration(seconds: 10),
          end: Duration(seconds: 20),
        ),
        PlaybackCacheRange(
          start: Duration(seconds: 18),
          end: Duration(seconds: 30),
        ),
        PlaybackCacheRange(
          start: Duration(seconds: 40),
          end: Duration(seconds: 40),
        ),
        PlaybackCacheRange(
          start: Duration(seconds: 90),
          end: Duration(seconds: 120),
        ),
        PlaybackCacheRange(
          start: Duration(seconds: 120),
          end: Duration(seconds: 90),
        ),
      ],
    );

    expect(ranges, hasLength(2));
    expect(ranges[0].start, Duration.zero);
    expect(ranges[0].end, const Duration(seconds: 30));
    expect(ranges[1].start, const Duration(seconds: 90));
    expect(ranges[1].end, const Duration(seconds: 100));
    expect(
      normalizePlaybackTimelineCacheRanges(
        duration: Duration.zero,
        ranges: ranges,
      ),
      isEmpty,
    );
  });

  test('maps normalized ranges to LTR and RTL track geometry', () {
    const track = Rect.fromLTWH(10, 20, 200, 4);
    const ranges = [
      PlaybackCacheRange(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
      ),
      PlaybackCacheRange(
        start: Duration(seconds: 50),
        end: Duration(seconds: 75),
      ),
    ];

    expect(
      playbackTimelineCacheRects(
        trackRect: track,
        duration: const Duration(seconds: 100),
        ranges: ranges,
        textDirection: TextDirection.ltr,
      ),
      const [Rect.fromLTRB(30, 20, 50, 24), Rect.fromLTRB(110, 20, 160, 24)],
    );
    expect(
      playbackTimelineCacheRects(
        trackRect: track,
        duration: const Duration(seconds: 100),
        ranges: ranges,
        textDirection: TextDirection.rtl,
      ),
      const [Rect.fromLTRB(170, 20, 190, 24), Rect.fromLTRB(60, 20, 110, 24)],
    );
  });

  test('exposes ranges only for confirmed, available disk telemetry', () {
    final available = _snapshot(cacheOnDisk: true);

    expect(
      confirmedPlaybackTimelineCacheRanges(
        runtimeMode: PlaybackCacheRuntimeMode.disk,
        snapshot: available,
      ),
      same(available.seekableRanges),
    );
    for (final mode in [
      PlaybackCacheRuntimeMode.disabled,
      PlaybackCacheRuntimeMode.memory,
      PlaybackCacheRuntimeMode.memoryFallback,
      PlaybackCacheRuntimeMode.unconfirmed,
    ]) {
      expect(
        confirmedPlaybackTimelineCacheRanges(
          runtimeMode: mode,
          snapshot: available,
        ),
        isEmpty,
      );
    }
    expect(
      confirmedPlaybackTimelineCacheRanges(
        runtimeMode: PlaybackCacheRuntimeMode.disk,
        snapshot: _snapshot(cacheOnDisk: false),
      ),
      isEmpty,
    );
    expect(
      confirmedPlaybackTimelineCacheRanges(
        runtimeMode: PlaybackCacheRuntimeMode.disk,
        snapshot: _snapshot(
          cacheOnDisk: true,
          status: PlaybackCacheTelemetryStatus.readFailed,
        ),
      ),
      isEmpty,
    );
    expect(
      confirmedPlaybackTimelineCacheRanges(
        runtimeMode: PlaybackCacheRuntimeMode.disk,
        snapshot: null,
      ),
      isEmpty,
    );
  });

  testWidgets('keeps Slider callbacks and accessibility semantics', (
    tester,
  ) async {
    var starts = 0;
    var changes = 0;
    var ends = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackTimeline(
            duration: const Duration(seconds: 100),
            max: 100000,
            value: 20000,
            secondaryTrackValue: 60000,
            cacheRuntimeMode: PlaybackCacheRuntimeMode.disk,
            cacheSnapshot: _snapshot(cacheOnDisk: true),
            onChangeStart: (_) => starts++,
            onChanged: (_) => changes++,
            onChangeEnd: (_) => ends++,
          ),
        ),
      ),
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.secondaryTrackValue, 60000);
    final theme = tester.widget<SliderTheme>(find.byType(SliderTheme));
    final shape = theme.data.trackShape! as PlaybackTimelineTrackShape;
    expect(shape.normalizedSeekableRanges, hasLength(2));
    expect(shape.cacheColor, playbackTimelineCacheColor);
    expect(shape.cacheColor, isNot(theme.data.activeTrackColor));

    final semanticsData = tester
        .getSemantics(find.byType(Slider))
        .getSemanticsData();
    expect(semanticsData.hasAction(SemanticsAction.increase), isTrue);
    expect(semanticsData.hasAction(SemanticsAction.decrease), isTrue);

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();
    expect(starts, 1);
    expect(changes, greaterThan(0));
    expect(ends, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'does not expose stale cache ranges outside confirmed disk mode',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackTimeline(
              duration: const Duration(seconds: 100),
              max: 100000,
              value: 20000,
              secondaryTrackValue: 60000,
              cacheRuntimeMode: PlaybackCacheRuntimeMode.memoryFallback,
              cacheSnapshot: _snapshot(cacheOnDisk: true),
              onChangeStart: (_) {},
              onChanged: (_) {},
              onChangeEnd: (_) {},
            ),
          ),
        ),
      );

      final theme = tester.widget<SliderTheme>(find.byType(SliderTheme));
      final shape = theme.data.trackShape! as PlaybackTimelineTrackShape;
      expect(shape.seekableRanges, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

PlaybackCacheEngineSnapshot _snapshot({
  required bool cacheOnDisk,
  PlaybackCacheTelemetryStatus status = PlaybackCacheTelemetryStatus.available,
}) => PlaybackCacheEngineSnapshot(
  fileCacheBytes: 1024,
  rawInputRateBytesPerSecond: 2048,
  seekableRanges: const [
    PlaybackCacheRange(
      start: Duration(seconds: 10),
      end: Duration(seconds: 30),
    ),
    PlaybackCacheRange(
      start: Duration(seconds: 40),
      end: Duration(seconds: 70),
    ),
  ],
  pausedForCache: false,
  cacheBufferingPercent: 100,
  cacheOnDisk: cacheOnDisk,
  telemetryStatus: status,
);
