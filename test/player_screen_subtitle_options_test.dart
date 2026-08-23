import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = PlaybackTrack(
    index: 3,
    type: 'Subtitle',
    title: 'Chinese',
    language: 'chi',
  );

  testWidgets('shows a check only after the subtitle is applied', (
    tester,
  ) async {
    final selections = <int?>[];
    final state = PlaybackState(
      plan: PlaybackPlan(
        uri: Uri.parse('https://media.example.test/video'),
        mediaSourceId: 'source-1',
        playSessionId: null,
        method: PlayMethod.directPlay,
        usesServerAuthentication: false,
        subtitleStreamIndex: 3,
        mediaStreams: [
          {'Index': 3, 'Type': 'Subtitle', 'DisplayTitle': 'Chinese'},
        ],
        transcodingReasons: [],
        availableMediaSources: [],
      ),
      appliedSubtitleStreamIndex: null,
      subtitleSelectionStatus: SubtitleSelectionStatus.notApplied,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSubtitleOptions(
            tracks: const [track],
            playbackState: state,
            onSelect: selections.add,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsNothing);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Chinese')).onTap,
      isNotNull,
    );
    await tester.tap(find.widgetWithText(ListTile, 'Chinese'));
    expect(selections, [3]);
  });

  testWidgets('shows applied state and exposes a retry after failure', (
    tester,
  ) async {
    final appliedState = const PlaybackState(
      appliedSubtitleStreamIndex: 3,
      subtitleSelectionStatus: SubtitleSelectionStatus.appliedEmbedded,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSubtitleOptions(
            tracks: const [track],
            playbackState: appliedState,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Chinese')).onTap,
      isNull,
    );

    final selections = <int?>[];
    final failedState = const PlaybackState(
      subtitleSelectionStatus: SubtitleSelectionStatus.failed,
      subtitleSelectionError: '字幕加载失败，请重试',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSubtitleOptions(
            tracks: const [track],
            playbackState: failedState,
            onSelect: selections.add,
          ),
        ),
      ),
    );

    expect(find.text('字幕加载失败，请重试'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Chinese'));
    expect(selections, [3]);
  });
}
