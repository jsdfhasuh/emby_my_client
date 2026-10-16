import 'package:emby_my_client/core/playback_diagnostic_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const a = '1111111111111111';
const b = '2222222222222222';

void main() {
  test('subtitle download stage ignores stale work from this playback', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture(
      'event=strm_entry trace=$a\n'
      'event=strm_subtitle trace=$a task=2 stage=subtitle_download outcome=started stale=false\n'
      'event=strm_subtitle trace=$a task=1 stage=subtitle_download outcome=failed stale=true\n',
    );
    expect(snapshot.summary.stageLabel, '下载中');
    expect(snapshot.summary.playbackStageLabel, '下载字幕');
  });

  test('actual native format and ID are shown without a server track index', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture(
      'event=strm_entry trace=$a\n'
      'event=playback_subtitle_apply_requested trace=$a generation=2 streamIndex=none\n'
      'event=playback_subtitle_applied trace=$a generation=2 streamIndex=none '
      'nativeFormat=hdmvPgsSubtitle nativeId=12',
    );
    expect(snapshot.summary.formatLabel, 'PGS');
    expect(snapshot.summary.trackLabel, '原生 #12');
    expect(snapshot.summary.subtitleStage, 'applied');
  });

  test('latest entry wins, not a late callback from an older session', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture('''
event=strm_entry trace=$a entry=fullscreen outcome=started
event=playback_subtitle_apply_requested trace=$a generation=1 streamIndex=3
event=strm_entry trace=$b entry=fullscreen outcome=started
event=playback_subtitle_apply_requested trace=$b generation=1 streamIndex=8
event=playback_subtitle_applied trace=$a generation=1 streamIndex=3
event=unrelated message=outside
''');
    expect(snapshot.playbackTraceId, b);
    expect(snapshot.content, contains('streamIndex=8'));
    expect(snapshot.content, isNot(contains(a)));
    expect(snapshot.content, isNot(contains('outside')));
    expect(snapshot.summary.streamIndex, 8);
  });

  test('explicit trace is exact and cannot be supplied by detailed JSON', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture('''
event=strm_entry trace=$a entry=fullscreen outcome=started
event=strm_detail trace=$b stage=metadata details={"trace":"$a"}
event=strm_detail trace=$b stage=metadata details={"message":" trace=$a "}
event=strm_detail trace=${a}0 stage=metadata
event=strm_entry trace=$a trace=$b entry=fullscreen
unstructured trace=$a
event=playback_subtitle_applied trace=$a generation=1 streamIndex=2
''', playbackTraceId: a);
    expect(
      snapshot.content.split('\n').where((line) => line.isNotEmpty),
      hasLength(2),
    );
    expect(snapshot.content, isNot(contains('details=')));
    expect(
      () =>
          PlaybackDiagnosticSnapshot.capture('', playbackTraceId: 'private-id'),
      throwsArgumentError,
    );
  });

  test('no trace never silently falls back to all logs', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture(
      'event=app password=secret',
    );
    expect(snapshot.playbackTraceId, isNull);
    expect(snapshot.content, isEmpty);
    final pinned = PlaybackDiagnosticSnapshot.capture(
      'event=strm_entry trace=$b entry=fullscreen',
      resolveLatest: false,
    );
    expect(pinned.content, isEmpty);
  });

  test(
    'format is actual detected content, stale generations cannot replace it',
    () {
      final snapshot = PlaybackDiagnosticSnapshot.capture('''
event=strm_entry trace=$a entry=fullscreen outcome=started
event=playback_subtitle_apply_requested trace=$a generation=2 streamIndex=7
event=playback_subtitle_delivery trace=$a streamIndex=7 format=srt
event=playback_subtitle_content_detected trace=$a generation=2 streamIndex=7 format=ass
event=playback_subtitle_applied trace=$a generation=2 streamIndex=7
event=playback_subtitle_apply_failed trace=$a generation=1 streamIndex=3
event=playback_subtitle_content_detected trace=$a generation=1 streamIndex=3 format=vtt
event=playback_subtitle_apply_skipped_stale trace=$a generation=3
''');
      expect(snapshot.summary.streamIndex, 7);
      expect(snapshot.summary.actualFormat, 'ass');
      expect(snapshot.summary.declaredFormat, 'srt');
      expect(snapshot.summary.subtitleStage, 'applied');
    },
  );

  test('selection changes clear previous format and disabled clears the track', () {
    const first =
        '''
event=strm_entry trace=$a entry=fullscreen
event=playback_subtitle_apply_requested trace=$a generation=1 streamIndex=2
event=playback_subtitle_content_detected trace=$a generation=1 streamIndex=2 format=ass
''';
    final changed = PlaybackDiagnosticSnapshot.capture(
      '${first}event=playback_subtitle_apply_requested trace=$a generation=2 streamIndex=4',
    );
    expect(changed.summary.actualFormat, isNull);
    expect(changed.summary.streamIndex, 4);
    final disabled = PlaybackDiagnosticSnapshot.capture(
      '${changed.content}event=playback_subtitle_disabled trace=$a generation=2',
    );
    expect(disabled.summary.trackLabel, '已关闭');
    expect(disabled.summary.actualFormat, isNull);
  });

  test('declared format alone is not presented as actual content', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture(
      'event=strm_entry trace=$a\n'
      'event=playback_subtitle_delivery trace=$a streamIndex=2 format=srt',
    );
    expect(snapshot.summary.declaredFormat, 'srt');
    expect(snapshot.summary.formatLabel, '未确认');
  });

  test('selection masks credentials but retains the synthetic trace', () {
    final snapshot = PlaybackDiagnosticSnapshot.capture(
      'event=strm_entry trace=$a\n'
      'event=strm_detail trace=$a stage=metadata details={"password":"secret",'
      '"url":"https://fixture.invalid/file?sig=private"}',
    );
    expect(snapshot.content, contains(a));
    expect(snapshot.content, isNot(contains('secret')));
    expect(snapshot.content, isNot(contains('private')));
    expect(snapshot.exportMarker, contains('scope=currentPlayback trace=$a'));
  });
}
