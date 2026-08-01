import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/emby_api.dart';
import '../../downloads/download_models.dart';
import '../../downloads/download_service.dart';
import '../player_screen.dart';
import '../widgets/media_widgets.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({
    super.key,
    required this.api,
    required this.downloads,
  });

  final EmbyApi api;
  final DownloadService downloads;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('离线下载')),
      body: AnimatedBuilder(
        animation: downloads,
        builder: (context, _) {
          final tasks = downloads.tasks;
          return Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.wifi),
                title: const Text('仅 Wi-Fi 下载'),
                value: downloads.settings.wifiOnly,
                onChanged: (value) => downloads.setWifiOnly(value),
              ),
              const Divider(height: 1),
              if (tasks.isNotEmpty) ...[
                _DownloadStorageSummary(tasks: tasks),
                const Divider(height: 1),
              ],
              Expanded(
                child: tasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.download_for_offline_outlined,
                        title: '还没有离线内容',
                        message: '在媒体详情中选择下载。',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => _DownloadRow(
                          task: tasks[index],
                          downloads: downloads,
                          onPlay: () => _play(context, tasks[index]),
                          onDelete: () => _confirmDelete(context, tasks[index]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _play(BuildContext context, DownloadTaskRecord task) async {
    final item = await downloads.offlineItem(task.itemId);
    if (!context.mounted) return;
    if (item == null) {
      final current = downloads.taskForItem(task.itemId);
      final message = current?.requiresFreshDownload == true
          ? '${_friendlyError(current?.lastErrorCode)}，请重新下载'
          : '离线文件记录不存在';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          api: api,
          item: item.toEmbyItem(),
          offlineItem: item,
          downloads: downloads,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    DownloadTaskRecord task,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(task.isComplete ? '删除离线文件？' : '取消下载？'),
        content: Text(
          task.isComplete
              ? '将从此设备删除“${task.displayName}”。'
              : '将删除当前任务和已经下载的临时文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) unawaited(downloads.delete(task.id));
  }
}

class _DownloadStorageSummary extends StatelessWidget {
  const _DownloadStorageSummary({required this.tasks});

  final List<DownloadTaskRecord> tasks;

  @override
  Widget build(BuildContext context) {
    final completed = tasks.where((task) => task.isComplete).length;
    final incomplete = tasks.length - completed;
    final mediaBytes = tasks.fold<int>(
      0,
      (total, task) => total + task.downloadedBytes,
    );
    return ListTile(
      dense: true,
      leading: const Icon(Icons.storage_outlined),
      title: Text('媒体文件占用 ${_formatBytes(mediaBytes)}'),
      subtitle: Text(
        [
          '$completed 个可离线播放',
          if (incomplete > 0) '$incomplete 个未完成',
        ].join(' · '),
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.task,
    required this.downloads,
    required this.onPlay,
    required this.onDelete,
  });

  final DownloadTaskRecord task;
  final DownloadService downloads;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 8, 12),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 48,
              child: _DownloadThumbnail(task: task),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _statusText(task),
                    style: const TextStyle(
                      color: Color(0xFFAAB2B4),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: task.isComplete ? 1 : progress,
                    minHeight: 4,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (task.isComplete)
              IconButton(
                tooltip: '离线播放',
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              )
            else if (task.canPause)
              IconButton(
                tooltip: '暂停',
                onPressed: () => downloads.pause(task.id),
                icon: const Icon(Icons.pause),
              )
            else if (task.canResume)
              IconButton(
                tooltip: task.requiresFreshDownload ? '重新下载' : '继续',
                onPressed: () => task.requiresFreshDownload
                    ? downloads.redownload(task.id)
                    : downloads.resume(task.id),
                icon: Icon(
                  task.requiresFreshDownload
                      ? Icons.refresh_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
            IconButton(
              tooltip: task.isComplete ? '删除离线文件' : '取消下载',
              onPressed: task.status == DownloadStatus.cancelling
                  ? null
                  : onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadThumbnail extends StatelessWidget {
  const _DownloadThumbnail({required this.task});

  final DownloadTaskRecord task;

  @override
  Widget build(BuildContext context) {
    final imagePath = task.metadata.primaryImagePath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: ColoredBox(
        color: const Color(0xFF202629),
        child: imagePath != null && File(imagePath).existsSync()
            ? Image.file(
                File(imagePath),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(_statusIcon(task.status), size: 25),
              )
            : Icon(_statusIcon(task.status), size: 25),
      ),
    );
  }
}

IconData _statusIcon(DownloadStatus status) => switch (status) {
  DownloadStatus.queued => Icons.schedule,
  DownloadStatus.running => Icons.downloading,
  DownloadStatus.waitingForNetwork => Icons.wifi_off,
  DownloadStatus.waitingForStorage => Icons.sd_storage_outlined,
  DownloadStatus.paused => Icons.pause_circle_outline,
  DownloadStatus.completed => Icons.download_done,
  DownloadStatus.failed => Icons.error_outline,
  DownloadStatus.cancelling => Icons.hourglass_top,
};

String _statusText(DownloadTaskRecord task) {
  final bytes = _formatBytes(task.downloadedBytes);
  final total = task.expectedBytes;
  final size = total == null || total <= 0
      ? bytes
      : '$bytes / ${_formatBytes(total)}';
  return switch (task.status) {
    DownloadStatus.queued => '等待下载 · $size',
    DownloadStatus.running => '正在下载 · $size',
    DownloadStatus.waitingForNetwork =>
      '${_friendlyError(task.lastErrorCode)} · $size',
    DownloadStatus.waitingForStorage => '等待存储空间 · $size',
    DownloadStatus.paused => '已暂停 · $size',
    DownloadStatus.completed => '可离线播放 · $size',
    DownloadStatus.failed => '${_friendlyError(task.lastErrorCode)} · $size',
    DownloadStatus.cancelling => '正在删除',
  };
}

String _friendlyError(String? code) => switch (code) {
  'authenticationRequired' => '登录已失效',
  'sourceNotFound' => '下载源不存在',
  'rateLimited' => '服务器限制请求',
  'serverError' => '服务器错误',
  'storageError' => '存储写入失败',
  'insufficientStorage' => '可用空间不足',
  'networkUnavailable' => '当前没有网络',
  'wifiRequired' => '等待 Wi-Fi',
  'missingFile' => '本地文件丢失',
  'localMediaCorrupt' => '本地文件损坏',
  'invalidLocalPath' => '本地文件路径无效',
  'nonMediaContentType' || 'nonMediaPayload' => '服务器返回的不是媒体',
  'contentLengthMismatch' ||
  'rangeResumeRejected' ||
  'checksumMismatch' => '文件校验失败',
  'processInterrupted' => '应用退出后已暂停',
  _ => '下载失败',
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
