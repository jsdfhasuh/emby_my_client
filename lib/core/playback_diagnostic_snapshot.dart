import 'diagnostic_log.dart';
import 'export_credential_redactor.dart';
import 'strm_diagnostics.dart';

enum DiagnosticLogScope { currentPlayback, all }

/// An immutable selection. Only explicit structured trace fields associate a
/// record with playback; timestamps, nearby lines and JSON values never do.
class PlaybackDiagnosticSnapshot {
  const PlaybackDiagnosticSnapshot._({
    required this.scope,
    required this.playbackTraceId,
    required this.content,
    required this.sourceTruncated,
    required this.summary,
  });

  final DiagnosticLogScope scope;
  final String? playbackTraceId;
  final String content;
  final bool sourceTruncated;
  final PlaybackDiagnosticSummary summary;

  static bool isTraceId(String value) =>
      RegExp(r'^[0-9a-f]{16}$').hasMatch(value);

  factory PlaybackDiagnosticSnapshot.capture(
    String log, {
    DiagnosticLogScope scope = DiagnosticLogScope.currentPlayback,
    String? playbackTraceId,
    bool resolveLatest = true,
  }) {
    if (playbackTraceId != null && !isTraceId(playbackTraceId)) {
      throw ArgumentError.value(playbackTraceId, 'playbackTraceId');
    }
    final lines = log.replaceAll('\r', '').split('\n');
    String? selected = playbackTraceId;
    if (selected == null && resolveLatest) {
      // A late callback from an older trace must not change the selected item.
      for (final line in lines) {
        final fields = _fields(line);
        if (fields['event'] == 'strm_entry' && fields['trace'] != null) {
          selected = fields['trace'];
        }
      }
    }
    final selectedLines = scope == DiagnosticLogScope.all
        ? lines.where((line) => line.isNotEmpty).toList()
        : lines
              .where(
                (line) =>
                    selected != null && _fields(line)['trace'] == selected,
              )
              .toList();
    final safeContent = ExportCredentialRedactor.redact(
      selectedLines.isEmpty ? '' : '${selectedLines.join('\n')}\n',
    );
    return PlaybackDiagnosticSnapshot._(
      scope: scope,
      playbackTraceId: scope == DiagnosticLogScope.all ? null : selected,
      content: safeContent,
      sourceTruncated: log.contains(DiagnosticLog.truncationMarker),
      summary: PlaybackDiagnosticSummary.fromLines(
        scope == DiagnosticLogScope.all ? const [] : selectedLines,
      ),
    );
  }

  String get scopeLabel => scope == DiagnosticLogScope.all ? '全部日志' : '本次播放';

  String get associationLabel => scope == DiagnosticLogScope.all
      ? '范围：全部日志'
      : '播放标识：${playbackTraceId ?? '暂无播放会话'}';

  String get exportMarker =>
      'event=diagnostic_export scope=${scope.name} '
      'trace=${playbackTraceId ?? 'none'} credentialRedaction=credentials-v1';

  static Map<String, String> _fields(String line) {
    final payload = StrmDiagnosticSchema.payload(line);
    if (!payload.startsWith('event=')) return const {};
    // Stop before detailed JSON: a URL or quoted payload cannot impersonate
    // a trace, event, generation or subtitle field.
    final prefix = payload.split(' details=').first;
    final fields = <String, String>{};
    for (final part in prefix.split(' ')) {
      final match = RegExp(
        r'^([A-Za-z][A-Za-z0-9]*)=([A-Za-z0-9_.-]+)$',
      ).firstMatch(part);
      if (match == null) continue;
      if (fields.containsKey(match[1])) return const {};
      fields[match[1]!] = match[2]!;
    }
    final trace = fields['trace'];
    if (trace == null || !isTraceId(trace)) return const {};
    return fields;
  }
}

class PlaybackDiagnosticSummary {
  const PlaybackDiagnosticSummary({
    this.streamIndex,
    this.nativeId,
    this.actualFormat,
    this.declaredFormat,
    this.subtitleStage = 'unavailable',
    this.playbackStage = 'unavailable',
    this.closed = false,
  });

  final int? streamIndex;
  final String? nativeId;
  final String? actualFormat;
  final String? declaredFormat;
  final String subtitleStage;
  final String playbackStage;
  final bool closed;

  factory PlaybackDiagnosticSummary.fromLines(List<String> lines) {
    int? stream, generation, downloadTask;
    String? actual, declared, nativeId;
    var subtitleStage = 'unavailable';
    var playbackStage = 'unavailable';
    var closed = false;
    for (final line in lines) {
      final fields = PlaybackDiagnosticSnapshot._fields(line);
      final event = fields['event'];
      if (event == null ||
          fields['stale'] == 'true' ||
          fields['outcome'] == 'stale') {
        continue;
      }
      if (event == 'strm_summary' &&
          fields['scope'] == 'playback' &&
          fields['outcome'] == 'closed') {
        closed = true;
      }
      final stage = fields['stage'];
      if (stage != null &&
          StrmDiagnosticSchema.enums['stage']!.contains(stage)) {
        playbackStage = stage;
      }
      if (event == 'strm_subtitle' && stage == 'subtitle_download') {
        final task = int.tryParse(fields['task'] ?? '');
        if (task != null && downloadTask != null && task < downloadTask) {
          continue;
        }
        if (task != null) downloadTask = task;
        subtitleStage = switch (fields['outcome']) {
          'started' => 'downloading',
          'succeeded' => 'downloaded',
          'failed' => 'failed',
          'cancelled' => 'cancelled',
          _ => subtitleStage,
        };
      }
      if (!event.startsWith('playback_subtitle_')) continue;
      final nextGeneration = int.tryParse(fields['generation'] ?? '');
      if (nextGeneration != null &&
          generation != null &&
          nextGeneration < generation) {
        continue;
      }
      if (event == 'playback_subtitle_apply_skipped_stale') continue;
      if (event == 'playback_subtitle_apply_requested') {
        generation = nextGeneration;
        stream = null;
        nativeId = null;
        actual = null;
        declared = null;
        subtitleStage = 'requested';
      }
      final nextStream = int.tryParse(fields['streamIndex'] ?? '');
      if (nextStream != null && nextStream >= 0 && nextStream <= 9999) {
        // Ignore late metadata for a different track in this generation.
        if (event != 'playback_subtitle_apply_requested' &&
            stream != null &&
            nextStream != stream) {
          continue;
        }
        stream = nextStream;
      }
      if (event == 'playback_subtitle_delivery') {
        declared = _format(fields['format']);
        subtitleStage = 'delivery';
      } else if (event == 'playback_subtitle_content_detected') {
        actual = _format(fields['format']);
        subtitleStage = 'downloaded';
      } else if (event == 'playback_subtitle_applied') {
        actual =
            _nativeFormat(fields['nativeFormat']) ??
            _format(fields['format']) ??
            actual;
        final id = fields['nativeId'];
        if (id != null &&
            RegExp(r'^(?:0|[1-9][0-9]{0,3}|auto|no)$').hasMatch(id)) {
          nativeId = id;
        }
        subtitleStage = 'applied';
      } else if (event == 'playback_subtitle_disabled') {
        stream = null;
        nativeId = null;
        actual = null;
        declared = null;
        subtitleStage = 'disabled';
      } else if (event == 'playback_subtitle_apply_failed' ||
          event == 'playback_subtitle_mapping_failed') {
        subtitleStage = 'failed';
      } else if (event == 'playback_subtitle_apply_cancelled') {
        subtitleStage = 'cancelled';
      }
    }
    return PlaybackDiagnosticSummary(
      streamIndex: stream,
      nativeId: nativeId,
      actualFormat: actual,
      declaredFormat: declared,
      subtitleStage: subtitleStage,
      playbackStage: playbackStage,
      closed: closed,
    );
  }

  static String? _format(String? value) => switch (value) {
    'ass' || 'ssa' || 'srt' || 'vtt' || 'webvtt' => value,
    _ => null,
  };

  static String? _nativeFormat(String? value) => switch (value) {
    'ass' || 'ssa' || 'srt' || 'webvtt' || 'text' => value,
    'subrip' => 'srt',
    'pgs' || 'hdmvPgsSubtitle' => 'pgs',
    'dvdSubtitle' => 'dvd_subtitle',
    'movText' => 'mov_text',
    _ => null,
  };

  String get formatLabel => actualFormat?.toUpperCase() ?? '未确认';
  String get trackLabel => subtitleStage == 'disabled'
      ? '已关闭'
      : streamIndex == null
      ? (nativeId == null ? '未确认' : '原生 #$nativeId')
      : '#$streamIndex${nativeId == null ? '' : '（原生 #$nativeId）'}';
  String get playbackStageLabel => switch (playbackStage) {
    'metadata' => '读取媒体信息',
    'classification' => '识别播放来源',
    'dns' => '解析服务器地址',
    'connect' => '连接服务器',
    'tls' => '建立安全连接',
    'redirect' => '跟随重定向',
    'range_response' => '读取媒体范围',
    'body_read' => '读取媒体数据',
    'native_register' => '准备播放器',
    'native_open' => '打开视频',
    'native_read' => '读取视频',
    'subtitle_download' => '下载字幕',
    'subtitle_apply' => '应用字幕',
    'reporting' => '同步播放进度',
    _ => '暂无记录',
  };

  String get stageLabel => switch (subtitleStage) {
    'requested' => '已请求',
    'delivery' => '已解析交付方式',
    'downloading' => '下载中',
    'downloaded' => '内容已检测，等待应用',
    'applied' => '已应用',
    'disabled' => '已关闭',
    'failed' => '失败',
    'cancelled' => '已取消',
    _ => '暂无记录',
  };
}
