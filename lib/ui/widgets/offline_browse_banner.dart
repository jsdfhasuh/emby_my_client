import 'package:flutter/material.dart';
import '../../data/emby_api.dart';

class OfflineBrowseBanner extends StatelessWidget {
  const OfflineBrowseBanner({super.key, required this.api, this.onRetry});
  final EmbyApi api;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: api.browseState,
    builder: (context, _) {
      final state = api.browseState;
      if (!state.offline &&
          !state.hasStalePages &&
          !state.storageUnavailable &&
          !state.authenticationRequired &&
          !state.missingPage) {
        return const SizedBox.shrink();
      }
      final retry =
          onRetry ?? (state.needsRecovery ? state.requestRecovery : null);
      final timestamp = state.cachedAt?.toLocal().toString().split('.').first;
      final title = state.authenticationRequired
          ? '登录已失效，请重新登录'
          : state.offline
          ? '服务器离线，信息未更新'
          : state.hasStalePages
          ? '部分信息未更新，正在显示缓存'
          : state.missingPage
          ? '此页面或分页尚未缓存，联网后可用'
          : '本机缓存写入失败，请检查存储空间';
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      title,
                      if (timestamp != null) '缓存时间：$timestamp',
                      if (state.offline) '未缓存的页面和分页需联网后查看',
                    ].join('\n'),
                    key: const ValueKey('offline-browse-status'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (retry != null && !state.authenticationRequired)
                  TextButton(onPressed: retry, child: const Text('刷新')),
              ],
            ),
          ),
        ),
      );
    },
  );
}
