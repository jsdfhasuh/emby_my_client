import 'dart:async';
import 'dart:io';

import 'source_input_failure.dart';
import 'subtitle_target.dart';

enum SubtitleProblemKind {
  network,
  notDownloaded,
  unsupported,
  unreadable,
  unknown,
}

/// User-facing categories require positive evidence. Remote/native text is never
/// displayed, and an unrecognized error is not evidence of a damaged file.
class SubtitleProblem {
  const SubtitleProblem(this.kind, this.message);
  final SubtitleProblemKind kind;
  final String message;

  static SubtitleProblem classify(Object error) {
    if (error is SubtitleSelectionFailure) {
      return SubtitleProblem(switch (error.reason) {
        SubtitleFailureReason.offlineNetworkForbidden =>
          SubtitleProblemKind.notDownloaded,
        SubtitleFailureReason.unsupportedDelivery =>
          SubtitleProblemKind.unsupported,
        _ => SubtitleProblemKind.unknown,
      }, error.message);
    }
    if (error is SocketException ||
        error is HttpException ||
        error is HandshakeException ||
        error is TimeoutException) {
      return const SubtitleProblem(
        SubtitleProblemKind.network,
        '字幕网络请求失败，可重试或切换字幕；视频继续播放',
      );
    }
    if (error is FileSystemException) {
      return const SubtitleProblem(
        SubtitleProblemKind.unreadable,
        '字幕文件无法读取，请检查文件或重新下载字幕',
      );
    }
    if (error is SourceInputException) {
      switch (error.code) {
        case 'subtitle_missing':
          return const SubtitleProblem(
            SubtitleProblemKind.notDownloaded,
            '字幕尚未下载或文件已丢失，可返回下载列表修复字幕',
          );
        case 'subtitle_format':
        case 'subtitle_unreadable':
          return const SubtitleProblem(
            SubtitleProblemKind.unreadable,
            '字幕内容无法识别或读取，可重新下载或切换字幕',
          );
        case 'subtitle_decoder_unsupported':
          return const SubtitleProblem(
            SubtitleProblemKind.unsupported,
            '当前播放器不支持该字幕解码，可切换其他字幕',
          );
        case 'dns_failed':
        case 'connect_failed':
        case 'tls_certificate':
        case 'source_denied':
        case 'timeout':
        case 'subtitle_timeout':
        case 'truncated':
          return const SubtitleProblem(
            SubtitleProblemKind.network,
            '字幕网络请求失败，可重试或切换字幕；视频继续播放',
          );
      }
    }
    return const SubtitleProblem(
      SubtitleProblemKind.unknown,
      '字幕未能加载，原因尚未确认；可切换、关闭字幕或导出本次日志',
    );
  }

  /// Only a codec-specific native decoder failure can be attributed to the
  /// current subtitle. Generic decoder/video/network failures stay untouched.
  static SubtitleProblem? fromNative(String message, String? activeCodec) {
    if (activeCodec == null || activeCodec.trim().isEmpty) return null;
    final text = message.toLowerCase();
    final codec = activeCodec.trim().toLowerCase();
    if (!RegExp(r'\b' + RegExp.escape(codec) + r'\b').hasMatch(text)) {
      return null;
    }
    if (text.contains('no decoder') ||
        text.contains('matching decoder') ||
        text.contains('decoder not found')) {
      return classify(
        const SourceInputException('subtitle_decoder_unsupported'),
      );
    }
    return null;
  }
}
