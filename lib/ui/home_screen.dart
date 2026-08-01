import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../realtime/realtime_refresh_binding.dart';
import 'item_detail_screen.dart';
import 'library_screen.dart';
import 'photos/photo_library_screen.dart';
import 'player_screen.dart';
import 'widgets/media_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, this.downloads});

  final EmbyApi api;
  final DownloadService? downloads;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<HomeData> _future;
  late final RealtimeRefreshBinding _realtimeRefresh;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getHome();
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _refresh,
      shouldRefresh: (event) =>
          isLibraryRefreshEvent(event, userId: widget.api.session.userId),
    );
  }

  @override
  void dispose() {
    unawaited(_realtimeRefresh.dispose());
    super.dispose();
  }

  Future<void> _refresh() async {
    final future = widget.api.getHome();
    setState(() {
      _future = future;
    });
    await future;
  }

  Future<void> _openDetail(EmbyItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ItemDetailScreen(
          api: widget.api,
          initialItem: item,
          downloads: widget.downloads,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _play(EmbyItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(api: widget.api, item: item),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openLibrary(EmbyItem view) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => view.isPhotoLibrary
            ? PhotoLibraryScreen(api: widget.api, directory: view)
            : LibraryBrowseScreen(
                api: widget.api,
                view: view,
                downloads: widget.downloads,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HomeData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(error: snapshot.error!, onRetry: () => _refresh());
        }
        final data = snapshot.data!;
        if (data.views.isEmpty && data.resume.isEmpty && data.latest.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: const CustomScrollView(
              physics: AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverFillRemaining(
                  child: EmptyState(
                    icon: Icons.video_library_outlined,
                    title: '媒体库是空的',
                    message: '在 Emby 服务器添加媒体后，下拉刷新即可看到。',
                  ),
                ),
              ],
            ),
          );
        }

        final featured = data.latest.firstOrNull ?? data.resume.firstOrNull;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              if (featured != null)
                _FeaturedMedia(
                  api: widget.api,
                  item: featured,
                  onOpen: () => _openDetail(featured),
                  onPlay: featured.isPlayable ? () => _play(featured) : null,
                ),
              if (data.resume.isNotEmpty)
                _PosterSection(
                  title: '继续观看',
                  items: data.resume,
                  api: widget.api,
                  onTap: _openDetail,
                ),
              if (data.latest.isNotEmpty)
                _PosterSection(
                  title: '最近添加',
                  items: data.latest,
                  api: widget.api,
                  onTap: _openDetail,
                ),
              if (data.views.isNotEmpty)
                _LibrarySection(
                  items: data.views,
                  api: widget.api,
                  onTap: _openLibrary,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _FeaturedMedia extends StatelessWidget {
  const _FeaturedMedia({
    required this.api,
    required this.item,
    required this.onOpen,
    required this.onPlay,
  });

  final EmbyApi api;
  final EmbyItem item;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final imageRequest =
        api.imageRequest(item, type: 'Backdrop', maxWidth: 1200) ??
        api.imageRequest(item, maxWidth: 900);
    return SizedBox(
      height: 236,
      child: Stack(
        fit: StackFit.expand,
        children: [
          EmbyImage(request: imageRequest),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x18000000), Color(0xEE0D1012)],
                stops: [0.25, 1],
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 26,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  [
                    item.subtitle,
                    item.runtimeLabel,
                    item.officialRating,
                  ].whereType<String>().join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFD1D6D7)),
                ),
                const SizedBox(height: 13),
                Row(
                  children: [
                    if (onPlay != null)
                      FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('播放'),
                      ),
                    if (onPlay != null) const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.info_outline),
                      label: const Text('详情'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterSection extends StatelessWidget {
  const _PosterSection({
    required this.title,
    required this.items,
    required this.api,
    required this.onTap,
  });

  final String title;
  final List<EmbyItem> items;
  final EmbyApi api;
  final ValueChanged<EmbyItem> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 266,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return MediaPosterCard(
                  item: item,
                  imageRequest: api.imageRequest(item),
                  onTap: () => onTap(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({
    required this.items,
    required this.api,
    required this.onTap,
  });

  final List<EmbyItem> items;
  final EmbyApi api;
  final ValueChanged<EmbyItem> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '媒体库',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 116,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                final request =
                    api.imageRequest(item, type: 'Backdrop', maxWidth: 500) ??
                    api.imageRequest(item, maxWidth: 500);
                return SizedBox(
                  width: 210,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onTap(item),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          EmbyImage(request: request),
                          const ColoredBox(color: Color(0x66000000)),
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              child: Text(
                                item.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
