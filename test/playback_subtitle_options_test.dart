import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = PlaybackTrack(
    index: 3,
    type: 'Subtitle',
    title: '中文',
    language: 'chi',
    codec: 'ass',
  );

  Widget buildMenu(
    PlaybackState state, {
    void Function(int? streamIndex)? onSelect,
    List<PlaybackTrack> tracks = const [track],
  }) => MaterialApp(
    home: Scaffold(
      body: PlaybackSubtitleOptions(
        tracks: tracks,
        playbackState: state,
        onSelect: onSelect ?? (_) {},
      ),
    ),
  );

  Finder trackTile() =>
      find.ancestor(of: find.text('中文'), matching: find.byType(ListTile));

  testWidgets('resolved but unapplied subtitles remain selectable', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildMenu(
        const PlaybackState(
          subtitleSelectionStatus: SubtitleSelectionStatus.notApplied,
        ),
      ),
    );

    final tile = tester.widget<ListTile>(trackTile().first);
    expect(tile.onTap, isNotNull);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  for (final status in [
    SubtitleSelectionStatus.appliedEmbedded,
    SubtitleSelectionStatus.appliedExternal,
    SubtitleSelectionStatus.appliedServer,
  ]) {
    testWidgets('checked $status row can confirm a manual memory', (
      tester,
    ) async {
      final choices = <int?>[];
      await tester.pumpWidget(
        buildMenu(
          PlaybackState(
            subtitleSelectionStatus: status,
            appliedSubtitleStreamIndex: 3,
          ),
          onSelect: choices.add,
        ),
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(tester.widget<ListTile>(trackTile().first).onTap, isNotNull);
      await tester.tap(trackTile().first);
      expect(choices, [3]);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  }

  for (final status in [
    SubtitleSelectionStatus.disabled,
    SubtitleSelectionStatus.appliedNone,
  ]) {
    testWidgets(
      'checked $status off row can confirm a manual disabled memory',
      (tester) async {
        final choices = <int?>[];
        await tester.pumpWidget(
          buildMenu(
            PlaybackState(subtitleSelectionStatus: status),
            onSelect: choices.add,
          ),
        );
        final off = find.widgetWithText(ListTile, '关闭字幕');
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(tester.widget<ListTile>(off).onTap, isNotNull);
        await tester.tap(off);
        expect(choices, [null]);
        expect(find.byIcon(Icons.check), findsOneWidget);
      },
    );
  }

  testWidgets('ambiguous duplicate index stays disabled even when checked', (
    tester,
  ) async {
    final choices = <int?>[];
    await tester.pumpWidget(
      buildMenu(
        const PlaybackState(
          subtitleSelectionStatus: SubtitleSelectionStatus.appliedEmbedded,
          appliedSubtitleStreamIndex: 3,
        ),
        tracks: const [track, track],
        onSelect: choices.add,
      ),
    );
    for (final tile in tester.widgetList<ListTile>(trackTile())) {
      expect(tile.onTap, isNull);
    }
    expect(choices, isEmpty);
  });

  testWidgets('application in progress disables subtitle changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildMenu(
        const PlaybackState(
          subtitleSelectionStatus: SubtitleSelectionStatus.applying,
        ),
      ),
    );

    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '关闭字幕')).onTap,
      isNull,
    );
    expect(tester.widget<ListTile>(trackTile().first).onTap, isNull);
  });

  testWidgets('late-track waiting is visible and subtitles can be disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildMenu(
        const PlaybackState(
          desiredSubtitleSelection: SubtitleSelection.explicitStream(3),
          subtitleSelectionStatus: SubtitleSelectionStatus.waitingForTracks,
        ),
      ),
    );

    expect(find.text('字幕轨道仍在加载，视频可继续播放'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '关闭字幕')).onTap,
      isNotNull,
    );
    expect(tester.widget<ListTile>(trackTile().first).onTap, isNotNull);
  });

  testWidgets('subtitle failure is visible and leaves retry enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildMenu(
        const PlaybackState(
          subtitleSelectionStatus: SubtitleSelectionStatus.failed,
          subtitleSelectionError: '字幕加载失败，请重试',
        ),
      ),
    );

    final tile = tester.widget<ListTile>(trackTile().first);
    expect(tile.onTap, isNotNull);
    expect(find.text('字幕加载失败，请重试'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });
}
