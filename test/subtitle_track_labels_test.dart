import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_target.dart';
import 'package:emby_my_client/playback/subtitle_track_labels.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing and unrecognized metadata is labeled honestly', () {
    final unknown = labelServerSubtitle(
      track: const PlaybackTrack(index: 3, type: 'Subtitle'),
      ordinal: 1,
    );
    expect(unknown.details, contains('语言未知'));
    expect(unknown.details, contains('格式未知'));
    expect(unknown.details, contains('下载状态未知'));
    expect(unknown.details, contains('内嵌/外挂未知'));
    expect(describeSubtitleLanguage(language: 'xyz').label, '语言标记：xyz');
    expect(describeSubtitleLanguage(language: 'en-hans').isChinese, isFalse);
  });

  test(
    'resolved explicit flags distinguish embedded local media from unknown',
    () {
      final plan = PlaybackPlan(
        uri: Uri.file('/fixture/video.mkv'),
        mediaSourceId: 'source',
        playSessionId: null,
        method: PlayMethod.directPlay,
        usesServerAuthentication: false,
        mediaStreams: const [
          {
            'Index': 3,
            'Type': 'Subtitle',
            'IsExternal': false,
            'IsForced': false,
          },
        ],
        transcodingReasons: const [],
        availableMediaSources: const [],
        transportKind: PlaybackTransportKind.offlineLocal,
      );
      final label = labelServerSubtitle(
        track: const PlaybackTrack(index: 3, type: 'Subtitle'),
        ordinal: 1,
        plan: plan,
      );
      expect(label.details, contains('媒体库内嵌字幕'));
      expect(label.details, contains('随视频下载'));
      expect(label.details, isNot(contains('强制标记未知')));
    },
  );

  test('language and format remain separate from server display title', () {
    final label = labelServerSubtitle(
      track: const PlaybackTrack(
        index: 8,
        type: 'Subtitle',
        title: '繁体中文',
        displayTitle: 'Subtitle 8',
        language: 'zh-Hant',
        codec: 'ssa',
        format: 'ass',
        isExternal: true,
      ),
      ordinal: 2,
      downloaded: true,
    );
    expect(label.title, 'Subtitle 8');
    expect(label.details, contains('繁体中文'));
    expect(label.details, contains('SSA · 交付格式 ASS'));
    expect(label.details, contains('外挂字幕'));
    expect(label.details, contains('已下载'));
    expect(label.details, contains('轨道 2'));
  });

  test('native labels never invent forced or external flags', () {
    final label = labelNativeSubtitle(
      track: const EngineTrack(id: '8'),
      ordinal: 3,
    );
    expect(label.details, contains('语言未知'));
    expect(label.details, contains('格式未知'));
    expect(label.details, contains('当前文件轨道（内嵌/外挂未知）'));
    expect(label.details, contains('强制标记未知'));
  });

  test('Chinese script, bilingual and forced evidence are independent', () {
    final value = describeSubtitleLanguage(
      language: 'zh-Hant',
      title: '繁英双语',
      isForced: true,
    );
    expect(value.label, '繁体中文 · 双语');
    expect(value.forced, isTrue);
    expect(describeSubtitleLanguage(language: 'zho').label, '中文（简繁未知）');
    expect(
      describeSubtitleLanguage(language: 'zh-Hans', title: '繁体').script,
      ChineseSubtitleScript.conflicting,
    );
  });

  testWidgets(
    'same-title server tracks have distinct ordinals and source details',
    (tester) async {
      await tester.pumpWidget(
        _menu(
          tracks: const [
            PlaybackTrack(
              index: 2,
              type: 'Subtitle',
              title: 'Same',
              language: 'eng',
            ),
            PlaybackTrack(
              index: 3,
              type: 'Subtitle',
              title: 'Same',
              language: 'chi',
              isExternal: true,
            ),
          ],
        ),
      );
      expect(find.text('Same'), findsNWidgets(2));
      expect(find.textContaining('轨道 1 · 英语'), findsOneWidget);
      expect(find.textContaining('轨道 2 · 中文（简繁未知）'), findsOneWidget);
      expect(find.textContaining('外挂字幕'), findsOneWidget);
      expect(find.byKey(const ValueKey('server-subtitle-2-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('server-subtitle-3-1')), findsOneWidget);
    },
  );

  testWidgets(
    'failed selection keeps retry, off and diagnostic export usable',
    (tester) async {
      var exports = 0;
      final selected = <int?>[];
      await tester.pumpWidget(
        _menu(
          tracks: const [
            PlaybackTrack(index: 2, type: 'Subtitle', title: 'Retry'),
          ],
          state: const PlaybackState(
            subtitleSelectionStatus: SubtitleSelectionStatus.failed,
            subtitleSelectionError: 'Fixture failure',
          ),
          onSelect: selected.add,
          onExport: () => exports++,
        ),
      );
      expect(find.text('Fixture failure'), findsOneWidget);
      expect(find.textContaining('切换其他字幕'), findsOneWidget);
      await tester.tap(find.text('导出本次日志'));
      await tester.tap(find.text('Retry'));
      await tester.tap(find.text('关闭字幕'));
      expect(exports, 1);
      expect(selected, [2, null]);
    },
  );

  testWidgets(
    'downloaded local row shows state and routes through its bound target',
    (tester) async {
      final local = LocalExternalAsset(
        2,
        Uri.file('/fixture/subtitle.srt'),
        SubtitleInputBinding(
          itemId: 'item',
          itemSession: Object(),
          engine: _Engine(),
          generation: 1,
          inputEpoch: 1,
        ),
      );
      LocalExternalAsset? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackSubtitleOptions(
              tracks: const [
                PlaybackTrack(
                  index: 2,
                  type: 'Subtitle',
                  title: 'Local',
                  isExternal: true,
                ),
              ],
              localAssets: [local],
              playbackState: const PlaybackState(),
              onSelect: (_) => fail('must use current local binding'),
              onSelectLocal: (value) => selected = value,
            ),
          ),
        ),
      );
      expect(find.textContaining('已下载'), findsOneWidget);
      await tester.tap(find.text('Local'));
      expect(selected, same(local));
    },
  );
}

Widget _menu({
  required List<PlaybackTrack> tracks,
  PlaybackState state = const PlaybackState(),
  void Function(int?)? onSelect,
  VoidCallback? onExport,
}) => MaterialApp(
  home: Scaffold(
    body: PlaybackSubtitleOptions(
      tracks: tracks,
      playbackState: state,
      onSelect: onSelect ?? (_) {},
      onExportDiagnostics: onExport,
    ),
  ),
);

class _Engine implements PlaybackEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
