import 'package:flutter/material.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import 'player_screen.dart';

/// Returns true when the offline action was handled (including a cache miss).
Future<bool> openCachedPlayback(
  BuildContext context, {
  required EmbyApi api,
  required DownloadService? downloads,
  required EmbyItem item,
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
  final local = downloads != null && downloads.scope == api.scope
      ? await downloads.offlineItem(item.id)
      : null;
  if (!context.mounted || !api.isSessionActive) return true;
  if (local == null || local.scope != api.scope) {
    if (!api.browseState.offline && !api.browseState.hasStalePages) {
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
        item: local.toEmbyItem(),
        offlineItem: local,
        downloads: downloads,
      ),
    ),
  );
  return true;
}
