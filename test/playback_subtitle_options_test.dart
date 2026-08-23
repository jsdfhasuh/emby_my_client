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
  }) => MaterialApp(
    home: Scaffold(
      body: PlaybackSubtitleOptions(
        tracks: const [track],
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

  testWidgets('only an actually applied subtitle is checked and disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildMenu(
        const PlaybackState(
          subtitleSelectionStatus: SubtitleSelectionStatus.appliedEmbedded,
          appliedSubtitleStreamIndex: 3,
        ),
      ),
    );

    final tile = tester.widget<ListTile>(trackTile().first);
    expect(tile.onTap, isNull);
    expect(find.byIcon(Icons.check), findsOneWidget);
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
