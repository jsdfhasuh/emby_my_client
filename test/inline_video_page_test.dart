import 'package:emby_my_client/playback/inline_playback_session.dart';
import 'package:emby_my_client/ui/photos/inline_video_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'renders inactive, loading, paused, completed, and failed states',
    (tester) async {
      InlinePlaybackState state = const InlinePlaybackState(itemId: 'video-1');
      var playCalls = 0;
      var retryCalls = 0;

      Future<void> pump() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: InlineVideoPage(
              itemId: 'video-1',
              coverRequest: null,
              isActive: true,
              state: state,
              onPlay: () async => playCalls++,
              onPause: () async {},
              onSeek: (_) async {},
              onRetry: () async => retryCalls++,
              onSeekInteractionChanged: (_) {},
            ),
          ),
        ),
      );

      await pump();
      expect(
        find.byKey(const Key('inline-video-inactive-video-1')),
        findsOneWidget,
      );

      state = const InlinePlaybackState(
        itemId: 'video-1',
        phase: InlinePlaybackPhase.loading,
        isBuffering: true,
      );
      await pump();
      expect(
        find.byKey(const Key('inline-video-loading-video-1')),
        findsOneWidget,
      );

      state = const InlinePlaybackState(
        itemId: 'video-1',
        phase: InlinePlaybackPhase.ready,
        duration: Duration(minutes: 4),
      );
      await pump();
      expect(
        find.byKey(const Key('inline-video-surface-video-1')),
        findsOneWidget,
      );
      expect(find.byTooltip('播放'), findsWidgets);
      await tester.tap(
        find.byKey(const Key('inline-video-center-play-video-1')),
      );
      expect(playCalls, 1);

      state = const InlinePlaybackState(
        itemId: 'video-1',
        phase: InlinePlaybackPhase.ready,
        position: Duration(minutes: 4),
        duration: Duration(minutes: 4),
        isCompleted: true,
      );
      await pump();
      expect(find.byTooltip('重新播放'), findsOneWidget);

      state = const InlinePlaybackState(
        itemId: 'video-1',
        phase: InlinePlaybackPhase.failed,
        errorMessage: 'offline',
      );
      await pump();
      expect(find.text('视频加载失败，请重试'), findsOneWidget);
      await tester.tap(find.byKey(const Key('inline-video-retry-video-1')));
      expect(retryCalls, 1);
    },
  );

  testWidgets('slider reports one seek and brackets page-scroll locking', (
    tester,
  ) async {
    final locks = <bool>[];
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineVideoPage(
            itemId: 'video-1',
            coverRequest: null,
            isActive: true,
            state: const InlinePlaybackState(
              itemId: 'video-1',
              phase: InlinePlaybackPhase.ready,
              position: Duration(minutes: 1),
              duration: Duration(minutes: 4),
              isPlaying: true,
            ),
            onPlay: () async {},
            onPause: () async {},
            onSeek: (position) async => seeks.add(position),
            onRetry: () async {},
            onSeekInteractionChanged: locks.add,
          ),
        ),
      ),
    );

    final slider = find.byKey(const Key('inline-video-slider-video-1'));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    await tester.pump();

    expect(locks, [true, false]);
    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(const Duration(minutes: 1)));
  });
}
