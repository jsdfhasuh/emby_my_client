import 'package:flutter/material.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../downloads/download_models.dart';
import '../models/emby_models.dart';
import 'player_screen.dart';

/// Returns true when the offline action was handled (including a cache miss).
Future<bool> openCachedPlayback(
  BuildContext context, {
  required EmbyApi api,
  required DownloadService? downloads,
  required EmbyItem item,
  bool requireLocal = false,
}) async {
  if (!api.isSessionActive) return true;
  if (api.browseState.authenticationRequired) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('登录已失效，请重新登录')));
    return true;
  }
  // A verified local copy can play immediately even before the first failed
  // request has detected a newly disconnected server.
  OfflineMediaItem? local;
  try {
    local = downloads != null && downloads.scope == api.scope
        ? await downloads.offlineItem(item.id)
        : null;
  } catch (_) {
    if (!context.mounted || !api.isSessionActive) return true;
    if (!requireLocal &&
        !api.browseState.offline &&
        !api.browseState.authenticationRequired) {
      return false;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('本地下载暂不可用，请到下载管理检查文件')));
    return true;
  }
  if (!context.mounted || !api.isSessionActive) return true;
  if (api.browseState.authenticationRequired) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('登录已失效，请重新登录')));
    return true;
  }
  final playable = local;
  if (playable == null || playable.scope != api.scope) {
    if (!requireLocal && !api.browseState.offline) {
      return false;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('此视频尚无可用的本地下载，联网后可播放')));
    return true;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        api: api,
        item: playable.toEmbyItem(),
        offlineItem: playable,
        downloads: downloads,
      ),
    ),
  );
  return true;
}
