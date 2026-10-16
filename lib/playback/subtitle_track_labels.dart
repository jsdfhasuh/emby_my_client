import '../models/emby_models.dart';
import 'playback_engine.dart';
import 'track_mapper.dart';

enum ChineseSubtitleScript { unknown, simplified, traditional, conflicting }

/// Presentation and preference evidence only. Never use labels to map IDs.
class SubtitleLanguageInfo {
  const SubtitleLanguageInfo({
    required this.label,
    required this.isChinese,
    required this.script,
    required this.isBilingual,
    required this.forced,
  });

  final String label;
  final bool isChinese;
  final ChineseSubtitleScript script;
  final bool isBilingual;
  final bool? forced;
}

SubtitleLanguageInfo describeSubtitleLanguage({
  String? language,
  String? title,
  bool? isForced,
}) {
  final code = language?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  final text = title?.trim().toLowerCase() ?? '';
  final simplified =
      const {'chs', 'zh-cn', 'zh-sg'}.contains(code) ||
      RegExp(r'^(zh|cmn)-hans(?:-|$)').hasMatch(code) ||
      RegExp(r'简体|簡體|简中|簡中|简英|簡英|simplified|\bchs\b').hasMatch(text);
  final traditional =
      const {'cht', 'zh-tw', 'zh-hk', 'zh-mo'}.contains(code) ||
      RegExp(r'^(zh|cmn)-hant(?:-|$)').hasMatch(code) ||
      RegExp(r'繁体|繁體|繁中|繁英|traditional|\bcht\b').hasMatch(text);
  final chinese =
      const {'zh', 'zho', 'chi', 'cmn', 'chs', 'cht'}.contains(code) ||
      code.startsWith('zh-') ||
      code.startsWith('cmn-') ||
      simplified ||
      traditional ||
      RegExp(r'中文|汉语|漢語|国语|國語|中英|chinese|mandarin').hasMatch(text);
  final bilingual =
      chinese &&
      (RegExp(r'双语|雙語|中英|英中|简英|簡英|繁英|bilingual').hasMatch(text) ||
          (RegExp(r'chinese|mandarin').hasMatch(text) &&
              RegExp(r'english|\beng\b').hasMatch(text)));
  final conflictingLanguage =
      chinese &&
      !bilingual &&
      const {
        'en',
        'eng',
        'ja',
        'jpn',
        'ko',
        'kor',
        'fr',
        'fra',
        'fre',
        'de',
        'deu',
        'ger',
        'es',
        'spa',
        'it',
        'ita',
        'pt',
        'por',
        'ru',
        'rus',
        'ar',
        'ara',
      }.contains(code.split('-').first);
  final script = simplified && traditional
      ? ChineseSubtitleScript.conflicting
      : simplified
      ? ChineseSubtitleScript.simplified
      : traditional
      ? ChineseSubtitleScript.traditional
      : ChineseSubtitleScript.unknown;
  final titleForced = RegExp(r'强制|強制|\bforced\b').hasMatch(text);
  final forced = isForced == false && titleForced
      ? null
      : isForced ?? (titleForced ? true : null);
  final label = conflictingLanguage
      ? '语言信息冲突（${language!.trim()} / 中文）'
      : chinese
      ? switch (script) {
          ChineseSubtitleScript.simplified => '简体中文',
          ChineseSubtitleScript.traditional => '繁体中文',
          ChineseSubtitleScript.conflicting => '中文（简繁信息冲突）',
          ChineseSubtitleScript.unknown => '中文（简繁未知）',
        }
      : switch (code) {
          '' || 'und' || 'unknown' => '语言未知',
          'en' || 'eng' => '英语',
          'ja' || 'jpn' => '日语',
          'ko' || 'kor' => '韩语',
          'fr' || 'fra' || 'fre' => '法语',
          'de' || 'deu' || 'ger' => '德语',
          'es' || 'spa' => '西班牙语',
          'it' || 'ita' => '意大利语',
          'pt' || 'por' => '葡萄牙语',
          'ru' || 'rus' => '俄语',
          'ar' || 'ara' => '阿拉伯语',
          _ => '语言标记：${language!.trim()}',
        };
  return SubtitleLanguageInfo(
    label: bilingual ? '$label · 双语' : label,
    isChinese: chinese && !conflictingLanguage,
    script: script,
    isBilingual: bilingual,
    forced: forced,
  );
}

class SubtitleTrackLabel {
  const SubtitleTrackLabel({required this.title, required this.details});
  final String title;
  final String details;
}

SubtitleTrackLabel labelServerSubtitle({
  required PlaybackTrack track,
  required int ordinal,
  PlaybackPlan? plan,
  bool downloaded = false,
}) {
  final language = describeSubtitleLanguage(
    language: track.language,
    title: track.originalTitle ?? track.displayTitle,
    isForced: subtitleStreamFlag(plan, track, 'IsForced'),
  );
  final external = subtitleStreamFlag(plan, track, 'IsExternal');
  final codec = _formatLabel(track.codec);
  final delivered = _formatLabel(track.format);
  final offline = plan?.transportKind == PlaybackTransportKind.offlineLocal;
  final downloadLabel = downloaded
      ? '已下载'
      : offline && external == false
      ? '随视频下载'
      : offline && external == true
      ? '未下载'
      : '下载状态未知';
  return SubtitleTrackLabel(
    title: _nonempty(track.title) ?? language.label,
    details: [
      '轨道 $ordinal',
      language.label,
      codec ?? (delivered == null ? '格式未知' : '源格式未知'),
      if (delivered != null && delivered != codec) '交付格式 $delivered',
      switch (external) {
        true => '外挂字幕',
        false => '媒体库内嵌字幕',
        null => '媒体库字幕（内嵌/外挂未知）',
      },
      downloadLabel,
      if (language.forced == true) '强制',
      if (language.forced == null) '强制标记未知',
      if (track.isDefault) '默认',
    ].join(' · '),
  );
}

/// PlaybackTrack's legacy booleans default to false when metadata is absent.
/// Preserve the distinction between a real false flag and missing evidence.
bool? subtitleStreamFlag(
  PlaybackPlan? plan,
  PlaybackTrack track,
  String field,
) {
  final rows = plan?.mediaStreams
      .where(
        (row) =>
            row['Type']?.toString().toLowerCase() == 'subtitle' &&
            row['Index']?.toString() == track.index.toString(),
      )
      .toList();
  if (rows != null && rows.isNotEmpty) {
    final value = rows.first[field];
    return value is bool && rows.every((row) => row[field] == value)
        ? value
        : null;
  }
  if (field == 'IsExternal' && track.isExternal) return true;
  if (field == 'IsForced' && track.isForced) return true;
  return null;
}

SubtitleTrackLabel labelNativeSubtitle({
  required EngineTrack track,
  required int ordinal,
  PlaybackPlan? plan,
}) {
  final language = describeSubtitleLanguage(
    language: track.language,
    title: track.title,
  );
  return SubtitleTrackLabel(
    title: _nonempty(track.title) ?? language.label,
    details: [
      '轨道 $ordinal',
      language.label,
      _formatLabel(track.codec) ?? '格式未知',
      '当前文件轨道（内嵌/外挂未知）',
      plan?.transportKind == PlaybackTransportKind.offlineLocal
          ? '本地播放（单轨下载状态未知）'
          : '下载状态未知',
      if (language.forced == true) '强制' else '强制标记未知',
      if (track.isDefault) '默认',
    ].join(' · '),
  );
}

String? _nonempty(String? value) =>
    value == null || value.trim().isEmpty ? null : value.trim();

String? _formatLabel(String? value) {
  final raw = _nonempty(value);
  if (raw == null) return null;
  return switch (raw.toLowerCase()) {
    'subrip' || 'srt' => 'SRT',
    'webvtt' || 'vtt' => 'WebVTT',
    'hdmv_pgs_subtitle' || 'pgs' => 'PGS',
    'dvd_subtitle' || 'dvdsub' => 'VobSub',
    _ => raw.toUpperCase(),
  };
}
