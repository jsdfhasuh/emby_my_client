import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../realtime/realtime_refresh_binding.dart';
import '../settings/library_category_settings.dart';
import 'item_detail_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'widgets/media_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.api,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
  });

  final EmbyApi api;
  final DownloadService? downloads;
  final LibraryCategorySettings categorySettings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<HomeData> _future;
  late final RealtimeRefreshBinding _realtimeRefresh;
  final Map<String, HomeLatestSection> _latestSections = {};
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _future = _loadHome(_loadGeneration);
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
    final generation = ++_loadGeneration;
    final future = _loadHome(generation);
    setState(() {
      _latestSections.clear();
      _future = future;
    });
    await future;
  }

  Future<HomeData> _loadHome(int generation) async {
    final data = await widget.api.getHomeBase();
    if (mounted && generation == _loadGeneration) {
      unawaited(_loadLatestSections(data.views, generation));
    }
    return data;
  }

  Future<void> _loadLatestSections(List<EmbyItem> views, int generation) async {
    const concurrency = 4;
    for (var start = 0; start < views.length; start += concurrency) {
      if (!mounted || generation != _loadGeneration) return;
      final end = (start + concurrency).clamp(0, views.length);
      await Future.wait(
        views.sublist(start, end).map((library) async {
          final section = await widget.api.getHomeLatestSection(library);
          if (!mounted || generation != _loadGeneration || section == null) {
            return;
          }
          setState(() => _latestSections[library.id] = section);
        }),
      );
    }
  }

  List<HomeLatestSection> _orderedLatestSections(HomeData data) {
    final sections = <String, HomeLatestSection>{
      for (final section in data.latestSections) section.library.id: section,
      ..._latestSections,
    };
    return data.views
        .map((view) => sections[view.id])
        .whereType<HomeLatestSection>()
        .toList(growable: false);
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

  Future<void> _openLibrary(EmbyItem library) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LibraryBrowseScreen(
          api: widget.api,
          view: library,
          downloads: widget.downloads,
          categorySettings: widget.categorySettings,
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
        final latestSections = _orderedLatestSections(data);
        if (data.views.isEmpty &&
            data.resume.isEmpty &&
            latestSections.isEmpty) {
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

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 6, bottom: 30),
            children: [
              if (data.views.isNotEmpty)
                _LibraryShelf(
                  items: data.views,
                  api: widget.api,
                  onTap: _openLibrary,
                ),
              if (data.resume.isNotEmpty)
                _LandscapeShelf(
                  title: '继续观看',
                  items: data.resume,
                  api: widget.api,
                  onTap: _openDetail,
                  onPlay: _play,
                ),
              for (final section in latestSections)
                if (_prefersLandscape(section))
                  _LandscapeShelf(
                    title: '最新${section.library.name}',
                    items: section.items,
                    api: widget.api,
                    onTap: _openDetail,
                    onTitleTap: () => _openLibrary(section.library),
                  )
                else
                  _PosterShelf(
                    title: '最新${section.library.name}',
                    items: section.items,
                    api: widget.api,
                    onTap: _openDetail,
                    onTitleTap: () => _openLibrary(section.library),
                  ),
            ],
          ),
        );
      },
    );
  }

  bool _prefersLandscape(HomeLatestSection section) {
    var landscape = 0;
    var portrait = 0;
    for (final item in section.items) {
      final ratio = item.primaryImageAspectRatio;
      if (ratio == null || ratio <= 0) continue;
      if (ratio >= 1.2) {
        landscape++;
      } else {
        portrait++;
      }
    }
    if (landscape + portrait > 0) return landscape > portrait;
    return switch (section.library.collectionType?.toLowerCase()) {
      'homevideos' || 'musicvideos' => true,
      _ => false,
    };
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: content,
    );
  }
}

class _LibraryShelf extends StatelessWidget {
  const _LibraryShelf({
    required this.items,
    required this.api,
    required this.onTap,
  });

  final List<EmbyItem> items;
  final EmbyApi api;
  final ValueChanged<EmbyItem> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 600
            ? (constraints.maxWidth * 0.68).clamp(210.0, 250.0)
            : 270.0;
        final labelHeight =
            7 + MediaQuery.textScalerOf(context).scale(13) * 1.2 + 8;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _SectionHeader(title: '我的媒体'),
              ),
              const SizedBox(height: 9),
              SizedBox(
                height: width * 9 / 16 + labelHeight,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final imageUrl =
                        api.imageUrl(item, maxWidth: 700) ??
                        api.imageUrl(item, type: 'Backdrop', maxWidth: 700);
                    return SizedBox(
                      width: width,
                      child: InkWell(
                        onTap: () => onTap(item),
                        borderRadius: BorderRadius.circular(6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AspectRatio(
                              aspectRatio: 16 / 9,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: EmbyImage(
                                  url: imageUrl,
                                  httpHeaders: api.imageHeaders,
                                  icon: Icons.video_library_outlined,
                                ),
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LandscapeShelf extends StatelessWidget {
  const _LandscapeShelf({
    required this.title,
    required this.items,
    required this.api,
    required this.onTap,
    this.onPlay,
    this.onTitleTap,
  });

  final String title;
  final List<EmbyItem> items;
  final EmbyApi api;
  final ValueChanged<EmbyItem> onTap;
  final ValueChanged<EmbyItem>? onPlay;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 600
            ? (constraints.maxWidth * 0.76).clamp(250.0, 320.0)
            : (constraints.maxWidth * 0.43).clamp(320.0, 380.0);
        return _ShelfFrame(
          title: title,
          onTitleTap: onTitleTap,
          height:
              width * 9 / 16 +
              MediaLandscapeCard.minimumMetadataHeight(context),
          children: [
            for (final item in items)
              MediaLandscapeCard(
                item: item,
                width: width,
                imageUrl: _landscapeImageUrl(api, item),
                imageHeaders: api.imageHeaders,
                onTap: () => onTap(item),
                onPlay: onPlay == null ? null : () => onPlay!(item),
              ),
          ],
        );
      },
    );
  }

  String? _landscapeImageUrl(EmbyApi api, EmbyItem item) {
    if (item.type == 'Movie' || item.type == 'Series') {
      return api.imageUrl(item, type: 'Backdrop', maxWidth: 900) ??
          api.imageUrl(item, maxWidth: 900);
    }
    return api.imageUrl(item, maxWidth: 900) ??
        api.imageUrl(item, type: 'Backdrop', maxWidth: 900);
  }
}

class _PosterShelf extends StatelessWidget {
  const _PosterShelf({
    required this.title,
    required this.items,
    required this.api,
    required this.onTap,
    required this.onTitleTap,
  });

  final String title;
  final List<EmbyItem> items;
  final EmbyApi api;
  final ValueChanged<EmbyItem> onTap;
  final VoidCallback onTitleTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 600
            ? (constraints.maxWidth * 0.31).clamp(112.0, 132.0)
            : constraints.maxWidth < 1000
            ? 142.0
            : 154.0;
        return _ShelfFrame(
          title: title,
          onTitleTap: onTitleTap,
          height: width * 1.5 + MediaPosterCard.minimumMetadataHeight(context),
          children: [
            for (final item in items)
              MediaPosterCard(
                item: item,
                width: width,
                imageUrl: api.imageUrl(item, maxWidth: 500),
                imageHeaders: api.imageHeaders,
                onTap: () => onTap(item),
              ),
          ],
        );
      },
    );
  }
}

class _ShelfFrame extends StatelessWidget {
  const _ShelfFrame({
    required this.title,
    required this.height,
    required this.children,
    this.onTitleTap,
  });

  final String title;
  final double height;
  final List<Widget> children;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _SectionHeader(title: title, onTap: onTitleTap),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: height,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: children.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, index) => children[index],
            ),
          ),
        ],
      ),
    );
  }
}
