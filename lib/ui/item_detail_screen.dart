import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../downloads/download_models.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../playback/playback_queue.dart';
import '../realtime/realtime_refresh_binding.dart';
import 'player_screen.dart';
import 'widgets/media_widgets.dart';

class ItemDetailScreen extends StatefulWidget {
  const ItemDetailScreen({
    super.key,
    required this.api,
    required this.initialItem,
    this.downloads,
  });

  final EmbyApi api;
  final EmbyItem initialItem;
  final DownloadService? downloads;

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  EmbyItem? _item;
  List<EmbyItem> _seasons = const [];
  List<EmbyItem> _episodes = const [];
  final Set<String> _updatingUserData = {};
  final Set<String> _startingDownloads = {};
  late final RealtimeRefreshBinding _realtimeRefresh;
  String? _seasonId;
  Object? _error;
  bool _loading = true;
  bool _loadingEpisodes = false;

  @override
  void initState() {
    super.initState();
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _refreshCurrentData,
      shouldRefresh: (event) =>
          isLibraryRefreshEvent(event, userId: widget.api.session.userId),
    );
    _load();
  }

  @override
  void dispose() {
    unawaited(_realtimeRefresh.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final item = await widget.api.getItem(widget.initialItem.id);
      var seasons = <EmbyItem>[];
      var episodes = <EmbyItem>[];
      String? seasonId;
      if (item.isSeries) {
        seasons = await widget.api.getSeasons(item.id);
        seasonId = seasons.firstOrNull?.id;
        episodes = await widget.api.getEpisodes(item.id, seasonId: seasonId);
      }
      if (!mounted) return;
      setState(() {
        _item = item;
        _seasons = seasons;
        _episodes = episodes;
        _seasonId = seasonId;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectSeason(String seasonId) async {
    final item = _item;
    if (item == null || seasonId == _seasonId) return;
    setState(() {
      _seasonId = seasonId;
      _loadingEpisodes = true;
    });
    try {
      final episodes = await widget.api.getEpisodes(
        item.id,
        seasonId: seasonId,
      );
      if (mounted) setState(() => _episodes = episodes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _loadingEpisodes = false);
    }
  }

  Future<void> _play(EmbyItem item) async {
    final series = _item;
    final queue = item.type == 'Episode' && series?.isSeries == true
        ? PlaybackQueue(
            api: widget.api,
            initialItems: _episodes,
            seriesId: series!.id,
            seasons: _seasons,
            currentSeasonId: _seasonId,
          )
        : PlaybackQueue.single(widget.api, item);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(api: widget.api, item: item, queue: queue),
      ),
    );
    await _refreshCurrentData();
  }

  Future<void> _handleDownload(EmbyItem item, DownloadTaskRecord? task) async {
    final downloads = widget.downloads;
    if (downloads == null || _startingDownloads.contains(item.id)) return;
    try {
      if (task == null) {
        setState(() => _startingDownloads.add(item.id));
        await downloads.enqueue(item);
      } else {
        switch (task.status) {
          case DownloadStatus.queued:
          case DownloadStatus.running:
          case DownloadStatus.waitingForNetwork:
          case DownloadStatus.waitingForStorage:
            await downloads.pause(task.id);
          case DownloadStatus.paused:
          case DownloadStatus.failed:
            if (task.requiresFreshDownload) {
              await downloads.redownload(task.id);
            } else {
              await downloads.resume(task.id);
            }
          case DownloadStatus.completed:
            await _playOffline(task);
          case DownloadStatus.cancelling:
            break;
        }
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _startingDownloads.remove(item.id));
    }
  }

  Future<void> _playOffline(DownloadTaskRecord task) async {
    final downloads = widget.downloads;
    if (downloads == null) return;
    final offlineItem = await downloads.offlineItem(task.itemId);
    if (!mounted) return;
    if (offlineItem == null) {
      final current = downloads.taskForItem(task.itemId);
      final message = switch (current?.lastErrorCode) {
        'localMediaCorrupt' => '本地文件损坏，请重新下载',
        'missingFile' => '本地文件丢失，请重新下载',
        _ => '离线文件记录不存在',
      };
      _showError(StateError(message));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          api: widget.api,
          item: offlineItem.toEmbyItem(),
          offlineItem: offlineItem,
          downloads: downloads,
        ),
      ),
    );
  }

  Future<void> _refreshCurrentData() async {
    final current = _item;
    if (current == null) return;
    final seasonId = _seasonId;
    try {
      final refreshedItem = await widget.api.getItem(current.id);
      final refreshedEpisodes = current.isSeries
          ? await widget.api.getEpisodes(current.id, seasonId: seasonId)
          : _episodes;
      if (!mounted || seasonId != _seasonId) return;
      setState(() {
        _item = refreshedItem;
        _episodes = refreshedEpisodes;
      });
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _toggleFavorite(EmbyItem item) async {
    await _updateUserData(
      item,
      action: () => widget.api.userData.setFavorite(
        item.id,
        favorite: !item.userData.isFavorite,
      ),
      successMessage: item.userData.isFavorite ? '已取消收藏' : '已添加收藏',
    );
  }

  Future<void> _togglePlayed(EmbyItem item) async {
    await _updateUserData(
      item,
      action: () => widget.api.userData.setPlayed(
        item.id,
        played: !item.userData.isPlayed,
      ),
      successMessage: item.userData.isPlayed ? '已标记为未观看' : '已标记为已观看',
      refreshEpisodes: item.isSeries,
    );
  }

  Future<void> _updateUserData(
    EmbyItem item, {
    required Future<void> Function() action,
    required String successMessage,
    bool refreshEpisodes = false,
  }) async {
    if (_updatingUserData.contains(item.id)) return;
    setState(() => _updatingUserData.add(item.id));
    try {
      await action();
      final refreshed = await widget.api.getItem(item.id);
      List<EmbyItem>? refreshedEpisodes;
      final seasonId = _seasonId;
      if (refreshEpisodes && seasonId != null) {
        refreshedEpisodes = await widget.api.getEpisodes(
          item.id,
          seasonId: seasonId,
        );
      }
      if (!mounted) return;
      setState(() {
        if (_item?.id == refreshed.id) {
          _item = refreshed;
          if (refreshedEpisodes != null && seasonId == _seasonId) {
            _episodes = refreshedEpisodes;
          }
        } else {
          _episodes = [
            for (final episode in _episodes)
              if (episode.id == refreshed.id) refreshed else episode,
          ];
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _updatingUserData.remove(item.id));
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: ErrorState(error: _error!, onRetry: _load),
      );
    }

    final item = _item!;
    final backdrop =
        widget.api.imageRequest(item, type: 'Backdrop', maxWidth: 1400) ??
        widget.api.imageRequest(item, maxWidth: 900);
    final poster = widget.api.imageRequest(item, maxWidth: 500);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 260,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  EmbyImage(request: backdrop),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x22000000),
                          Color(0x990D1012),
                          Color(0xFF0D1012),
                        ],
                        stops: [0, 0.7, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 104,
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: EmbyImage(request: poster),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      height: 1.08,
                                    ),
                              ),
                              const SizedBox(height: 9),
                              Text(
                                [
                                  item.subtitle,
                                  item.runtimeLabel,
                                  item.officialRating,
                                  item.communityRating == null
                                      ? null
                                      : '★ ${item.communityRating!.toStringAsFixed(1)}',
                                ].whereType<String>().join(' · '),
                                style: const TextStyle(
                                  color: Color(0xFFB6BDBF),
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 14),
                              _buildPrimaryActions(item),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (item.genres.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: item.genres
                          .map((genre) => Chip(label: Text(genre)))
                          .toList(),
                    ),
                  ],
                  if (item.overview != null && item.overview!.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      '简介',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      item.overview!,
                      style: const TextStyle(
                        color: Color(0xFFC4CACC),
                        fontSize: 15,
                        height: 1.65,
                      ),
                    ),
                  ],
                  if (item.isSeries) ...[
                    const SizedBox(height: 28),
                    _buildEpisodes(item),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodes(EmbyItem series) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '剧集',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (_seasons.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxWidth: 180),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1F21),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF343C3F)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _seasonId,
                    isExpanded: true,
                    items: _seasons
                        .map(
                          (season) => DropdownMenuItem(
                            value: season.id,
                            child: Text(
                              season.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _loadingEpisodes
                        ? null
                        : (value) {
                            if (value != null) _selectSeason(value);
                          },
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_loadingEpisodes)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_episodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: EmptyState(icon: Icons.playlist_remove, title: '这一季没有剧集'),
          )
        else
          ..._episodes.map((episode) {
            final imageRequest = widget.api.imageRequest(
              episode,
              maxWidth: 420,
            );
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: const Color(0xFF151A1C),
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _play(episode),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 132,
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              EmbyImage(request: imageRequest),
                              const Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Color(0x99000000),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(5),
                                    child: Icon(
                                      Icons.play_arrow_rounded,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                              if (episode.progress > 0 && episode.progress < 1)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: LinearProgressIndicator(
                                    value: episode.progress,
                                    minHeight: 3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                episode.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                [
                                  episode.indexNumber == null
                                      ? null
                                      : '第 ${episode.indexNumber} 集',
                                  episode.runtimeLabel,
                                ].whereType<String>().join(' · '),
                                style: const TextStyle(
                                  color: Color(0xFF9DA6A9),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _buildEpisodeStatusMenu(episode),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildPrimaryActions(EmbyItem item) {
    final updating = _updatingUserData.contains(item.id);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (item.isPlayable)
          FilledButton.icon(
            onPressed: () => _play(item),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              item.resumePosition > const Duration(seconds: 30) ? '继续播放' : '播放',
            ),
          )
        else if (item.isSeries && _episodes.isNotEmpty)
          FilledButton.icon(
            onPressed: () => _play(
              _episodes.firstWhere(
                (episode) => !episode.userData.isPlayed,
                orElse: () => _episodes.first,
              ),
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('播放剧集'),
          ),
        IconButton.filledTonal(
          tooltip: item.userData.isFavorite ? '取消收藏' : '收藏',
          onPressed: updating ? null : () => _toggleFavorite(item),
          icon: Icon(
            item.userData.isFavorite ? Icons.favorite : Icons.favorite_border,
          ),
        ),
        IconButton.filledTonal(
          tooltip: item.userData.isPlayed ? '标记为未观看' : '标记为已观看',
          onPressed: updating ? null : () => _togglePlayed(item),
          icon: Icon(
            item.userData.isPlayed
                ? Icons.check_circle
                : Icons.check_circle_outline,
          ),
        ),
        _buildDownloadAction(item, filled: true),
        if (updating)
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildEpisodeStatusMenu(EmbyItem episode) {
    if (_updatingUserData.contains(episode.id)) {
      return const SizedBox.square(
        dimension: 44,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDownloadAction(episode),
        if (episode.userData.isFavorite)
          const Icon(Icons.favorite, size: 18, color: Color(0xFFE57373)),
        if (episode.userData.isPlayed)
          const Padding(
            padding: EdgeInsets.only(left: 5),
            child: Icon(Icons.check_circle, size: 19, color: Color(0xFF55B948)),
          ),
        PopupMenuButton<_UserDataAction>(
          tooltip: '剧集状态',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case _UserDataAction.favorite:
                _toggleFavorite(episode);
              case _UserDataAction.played:
                _togglePlayed(episode);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _UserDataAction.favorite,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  episode.userData.isFavorite
                      ? Icons.favorite
                      : Icons.favorite_border,
                ),
                title: Text(episode.userData.isFavorite ? '取消收藏' : '收藏'),
              ),
            ),
            PopupMenuItem(
              value: _UserDataAction.played,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  episode.userData.isPlayed
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                ),
                title: Text(episode.userData.isPlayed ? '标记为未观看' : '标记为已观看'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownloadAction(EmbyItem item, {bool filled = false}) {
    final downloads = widget.downloads;
    if (downloads == null || !item.isPlayable) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        final task = downloads.taskForItem(item.id);
        final starting = _startingDownloads.contains(item.id);
        final status = task?.status;
        final tooltip = starting
            ? '准备下载'
            : switch (status) {
                null => '下载',
                DownloadStatus.queued ||
                DownloadStatus.running ||
                DownloadStatus.waitingForNetwork ||
                DownloadStatus.waitingForStorage => '暂停下载',
                DownloadStatus.failed
                    when task?.requiresFreshDownload == true =>
                  '重新下载',
                DownloadStatus.paused || DownloadStatus.failed => '继续下载',
                DownloadStatus.completed => '离线播放',
                DownloadStatus.cancelling => '正在删除',
              };
        final icon = starting
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(switch (status) {
                null => Icons.download_outlined,
                DownloadStatus.queued ||
                DownloadStatus.running ||
                DownloadStatus.waitingForNetwork ||
                DownloadStatus.waitingForStorage => Icons.pause,
                DownloadStatus.paused ||
                DownloadStatus.failed => Icons.download_outlined,
                DownloadStatus.completed => Icons.offline_pin,
                DownloadStatus.cancelling => Icons.hourglass_top,
              });
        final onPressed = starting || status == DownloadStatus.cancelling
            ? null
            : () => _handleDownload(item, task);
        return filled
            ? IconButton.filledTonal(
                tooltip: tooltip,
                onPressed: onPressed,
                icon: icon,
              )
            : IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon);
      },
    );
  }
}

enum _UserDataAction { favorite, played }
