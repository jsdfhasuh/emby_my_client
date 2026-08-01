import 'dart:async';

import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../images/emby_image_request.dart';
import '../models/emby_models.dart';
import '../playback/playback_queue.dart';
import '../realtime/emby_event.dart';
import '../realtime/realtime_refresh_binding.dart';
import 'item_detail_screen.dart';
import 'player_screen.dart';
import 'photos/photo_library_screen.dart';
import 'widgets/media_widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api, this.downloads});

  final EmbyApi api;
  final DownloadService? downloads;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<EmbyItem>> _future;
  late final RealtimeRefreshBinding _realtimeRefresh;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getViews();
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
    final future = widget.api.getViews();
    setState(() {
      _future = future;
    });
    await future;
  }

  Future<void> _openView(EmbyItem view) {
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
    return FutureBuilder<List<EmbyItem>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(error: snapshot.error!, onRetry: () => _refresh());
        }
        final views = snapshot.data ?? const [];
        if (views.isEmpty) {
          return const EmptyState(
            icon: Icons.video_library_outlined,
            title: '没有可用的媒体库',
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              childAspectRatio: 1.65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: views.length,
            itemBuilder: (context, index) {
              final view = views[index];
              final request =
                  widget.api.imageRequest(
                    view,
                    type: 'Backdrop',
                    maxWidth: 700,
                  ) ??
                  widget.api.imageRequest(view, maxWidth: 700);
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _openView(view),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      EmbyImage(request: request),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x10000000), Color(0xD9000000)],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: Text(
                            view.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class LibraryBrowseScreen extends StatefulWidget {
  const LibraryBrowseScreen({
    super.key,
    required this.api,
    required this.view,
    this.downloads,
  }) : _facet = null;

  const LibraryBrowseScreen._facet({
    required this.api,
    required this.view,
    required _LibraryFacet facet,
    this.downloads,
  }) : _facet = facet;

  final EmbyApi api;
  final EmbyItem view;
  final DownloadService? downloads;
  final _LibraryFacet? _facet;

  @override
  State<LibraryBrowseScreen> createState() => _LibraryBrowseScreenState();
}

enum _LibrarySection { videos, folders, genres, tags, favorites }

extension on _LibrarySection {
  String get label => switch (this) {
    _LibrarySection.videos => '影片',
    _LibrarySection.folders => '文件夹',
    _LibrarySection.genres => '分类',
    _LibrarySection.tags => '标签',
    _LibrarySection.favorites => '收藏',
  };

  IconData get icon => switch (this) {
    _LibrarySection.videos => Icons.movie_outlined,
    _LibrarySection.folders => Icons.folder_outlined,
    _LibrarySection.genres => Icons.category_outlined,
    _LibrarySection.tags => Icons.label_outline,
    _LibrarySection.favorites => Icons.favorite_border,
  };

  String get emptyTitle => switch (this) {
    _LibrarySection.videos => '这个媒体库是空的',
    _LibrarySection.folders => '没有文件夹',
    _LibrarySection.genres => '没有分类',
    _LibrarySection.tags => '没有标签',
    _LibrarySection.favorites => '还没有收藏的媒体',
  };
}

enum _LibraryFacetKind { genre, tag }

class _LibraryFacet {
  const _LibraryFacet({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;
  final String name;
  final _LibraryFacetKind kind;
}

class _LibrarySectionBar extends StatelessWidget {
  const _LibrarySectionBar({required this.selected, required this.onSelected});

  final _LibrarySection selected;
  final ValueChanged<_LibrarySection> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('library-section-bar'),
      height: 58,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final section in _LibrarySection.values) ...[
              ChoiceChip(
                key: ValueKey('library-section-${section.name}'),
                label: Text(section.label),
                selected: selected == section,
                showCheckmark: false,
                onSelected: (_) => onSelected(section),
              ),
              if (section != _LibrarySection.values.last)
                const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

enum _LibraryMediaFilter { all, strm, regular }

extension on _LibraryMediaFilter {
  String get label => switch (this) {
    _LibraryMediaFilter.all => '全部',
    _LibraryMediaFilter.strm => 'STRM',
    _LibraryMediaFilter.regular => '普通媒体',
  };

  bool includes(EmbyItem item) => switch (this) {
    _LibraryMediaFilter.all => true,
    _LibraryMediaFilter.strm => item.isStrm,
    _LibraryMediaFilter.regular => !item.isStrm,
  };

  String get emptyTitle => switch (this) {
    _LibraryMediaFilter.all => '这个媒体库是空的',
    _LibraryMediaFilter.strm => '没有 STRM 媒体',
    _LibraryMediaFilter.regular => '没有普通媒体',
  };

  IconData get emptyIcon => switch (this) {
    _LibraryMediaFilter.all => Icons.movie_filter_outlined,
    _LibraryMediaFilter.strm => Icons.link_off_outlined,
    _LibraryMediaFilter.regular => Icons.movie_outlined,
  };
}

extension on LibrarySort {
  String get label => switch (this) {
    LibrarySort.nameAscending => '名称 A-Z',
    LibrarySort.nameDescending => '名称 Z-A',
    LibrarySort.dateAddedDescending => '最近添加',
    LibrarySort.productionYearDescending => '年份从新到旧',
    LibrarySort.communityRatingDescending => '评分从高到低',
  };
}

enum _LibraryMoreAction { refresh, reset }

class _LibraryActionBar extends StatelessWidget {
  const _LibraryActionBar({
    required this.filter,
    required this.sort,
    required this.canPlay,
    required this.onPlayAll,
    required this.onShuffle,
    required this.onFilterSelected,
    required this.onSortSelected,
    required this.onMoreSelected,
  });

  final _LibraryMediaFilter filter;
  final LibrarySort sort;
  final bool canPlay;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  final ValueChanged<_LibraryMediaFilter> onFilterSelected;
  final ValueChanged<LibrarySort> onSortSelected;
  final ValueChanged<_LibraryMoreAction> onMoreSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('library-action-bar'),
      height: 64,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: constraints.maxWidth > 28
                  ? constraints.maxWidth - 28
                  : 0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  key: const ValueKey('library-play-all-button'),
                  tooltip: '播放全部',
                  onPressed: canPlay ? onPlayAll : null,
                  icon: const Icon(Icons.play_arrow),
                ),
                IconButton(
                  key: const ValueKey('library-shuffle-button'),
                  tooltip: '随机播放',
                  onPressed: canPlay ? onShuffle : null,
                  icon: const Icon(Icons.shuffle),
                ),
                PopupMenuButton<LibrarySort>(
                  key: const ValueKey('library-sort-button'),
                  tooltip: '排序',
                  icon: const Icon(Icons.sort),
                  initialValue: sort,
                  onSelected: onSortSelected,
                  itemBuilder: (context) => [
                    for (final option in LibrarySort.values)
                      CheckedPopupMenuItem(
                        key: ValueKey('library-sort-${option.name}'),
                        value: option,
                        checked: option == sort,
                        child: Text(option.label),
                      ),
                  ],
                ),
                PopupMenuButton<_LibraryMediaFilter>(
                  key: const ValueKey('library-filter-button'),
                  tooltip: '筛选',
                  initialValue: filter,
                  onSelected: onFilterSelected,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        filter == _LibraryMediaFilter.all
                            ? Icons.filter_list
                            : Icons.filter_alt,
                      ),
                      if (filter != _LibraryMediaFilter.all)
                        const Positioned(
                          top: -2,
                          right: -3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xFF55B948),
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox.square(dimension: 7),
                          ),
                        ),
                    ],
                  ),
                  itemBuilder: (context) => [
                    for (final option in _LibraryMediaFilter.values)
                      CheckedPopupMenuItem(
                        key: ValueKey('library-filter-${option.name}'),
                        value: option,
                        checked: option == filter,
                        child: Text(option.label),
                      ),
                  ],
                ),
                PopupMenuButton<_LibraryMoreAction>(
                  key: const ValueKey('library-more-button'),
                  tooltip: '更多',
                  icon: const Icon(Icons.more_horiz),
                  onSelected: onMoreSelected,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      key: ValueKey('library-more-refresh'),
                      value: _LibraryMoreAction.refresh,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.refresh),
                        title: Text('刷新'),
                      ),
                    ),
                    PopupMenuItem(
                      key: ValueKey('library-more-reset'),
                      value: _LibraryMoreAction.reset,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.restart_alt),
                        title: Text('重置筛选和排序'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryGroupCard extends StatelessWidget {
  const _LibraryGroupCard({
    super.key,
    required this.item,
    required this.icon,
    required this.imageRequest,
    required this.onTap,
  });

  final EmbyItem item;
  final IconData icon;
  final EmbyImageRequest? imageRequest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageRequest != null)
              EmbyImage(request: imageRequest)
            else
              ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(icon, size: 42),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xD9000000)],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Row(
                children: [
                  Icon(icon, size: 20, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryBrowseScreenState extends State<LibraryBrowseScreen> {
  static const _pageSize = 60;
  final _controller = ScrollController();
  final List<EmbyItem> _items = [];
  late final RealtimeRefreshBinding _realtimeRefresh;
  final Set<String> _pendingRealtimeUserDataIds = {};
  bool _loading = false;
  bool _reloading = false;
  bool _hasMore = true;
  bool _pendingRealtimeLibraryRefresh = false;
  Object? _error;
  int _loadGeneration = 0;
  _LibrarySection _section = _LibrarySection.videos;
  _LibraryMediaFilter _filter = _LibraryMediaFilter.all;
  LibrarySort _sort = LibrarySort.nameAscending;

  bool get _isMediaView =>
      widget._facet != null ||
      _section == _LibrarySection.videos ||
      _section == _LibrarySection.favorites;

  List<EmbyItem> get _displayedItems => _isMediaView
      ? _items.where(_filter.includes).toList(growable: false)
      : List.unmodifiable(_items);

  List<EmbyItem> get _playableItems =>
      _displayedItems.where((item) => item.isPlayable).toList(growable: false);

  String get _emptyTitle => widget._facet == null
      ? _section.emptyTitle
      : '“${widget._facet!.name}”中没有媒体';

  IconData get _emptyIcon => widget._facet == null
      ? _section.icon
      : widget._facet!.kind == _LibraryFacetKind.genre
      ? Icons.category_outlined
      : Icons.label_outline;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _refreshRealtime,
      shouldRefresh: (event) {
        if (event is EmbyLibraryChanged) {
          _pendingRealtimeLibraryRefresh = true;
          return true;
        }
        if (event is EmbyUserDataChanged &&
            event.userId == widget.api.session.userId) {
          _pendingRealtimeUserDataIds.addAll(
            event.itemIds.isEmpty
                ? _items.map((item) => item.id)
                : event.itemIds,
          );
          return true;
        }
        return false;
      },
    );
    _loadMore();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    unawaited(_realtimeRefresh.dispose());
    super.dispose();
  }

  bool get _isCurrentRoute => ModalRoute.of(context)?.isCurrent == true;

  Future<void> _refreshRealtime() async {
    if (!_isCurrentRoute) return;
    final reloadLibrary = _pendingRealtimeLibraryRefresh;
    final userDataIds = Set<String>.of(_pendingRealtimeUserDataIds);
    _pendingRealtimeLibraryRefresh = false;
    _pendingRealtimeUserDataIds.clear();
    try {
      if (reloadLibrary) {
        await _reloadSilentlyPreservingPosition();
      } else {
        await _refreshUserData(userDataIds);
      }
    } catch (error) {
      _pendingRealtimeLibraryRefresh |= reloadLibrary;
      _pendingRealtimeUserDataIds.addAll(userDataIds);
      DiagnosticLog.instance.warning(
        'library',
        'Realtime update failed library=${widget.view.id}: $error',
      );
    }
  }

  Future<void> _refreshLoadedUserData() async {
    try {
      await _refreshUserData(_items.map((item) => item.id));
    } catch (error) {
      if (mounted && _isCurrentRoute) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _refreshUserData(Iterable<String> itemIds) async {
    if (!_isMediaView || _items.isEmpty) return;
    final loadedIds = _items.map((item) => item.id).toSet();
    final requestedIds = itemIds.where(loadedIds.contains).toSet();
    if (requestedIds.isEmpty) return;
    final generation = _loadGeneration;
    final updates = await widget.api.getUserDataForItems(requestedIds);
    if (!mounted || generation != _loadGeneration || updates.isEmpty) return;
    setState(() {
      for (var index = 0; index < _items.length; index++) {
        final userData = updates[_items[index].id];
        if (userData != null) {
          _items[index] = _items[index].copyWith(userData: userData);
        }
      }
      if (widget._facet == null && _section == _LibrarySection.favorites) {
        _items.removeWhere((item) => !item.userData.isFavorite);
      }
    });
  }

  Future<void> _reloadSilentlyPreservingPosition() async {
    if (!mounted || _reloading) return;
    final previousOffset = _controller.hasClients ? _controller.offset : null;
    final targetItemCount = _items.length > _pageSize
        ? _items.length
        : _pageSize;
    final generation = ++_loadGeneration;
    final refreshedItems = <EmbyItem>[];
    var refreshedHasMore = true;
    setState(() {
      _reloading = true;
      _loading = false;
      _error = null;
    });
    try {
      while (refreshedItems.length < targetItemCount && refreshedHasMore) {
        final page = await _requestPage(refreshedItems.length);
        if (!mounted || generation != _loadGeneration) return;
        refreshedItems.addAll(page);
        refreshedHasMore = page.length == _pageSize;
        if (page.isEmpty) break;
      }
      setState(() {
        _items
          ..clear()
          ..addAll(refreshedItems);
        _hasMore = refreshedHasMore;
      });
    } catch (error) {
      if (mounted && generation == _loadGeneration) rethrow;
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _reloading = false);
      }
    }
    if (previousOffset != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final offset = previousOffset
            .clamp(0.0, _controller.position.maxScrollExtent)
            .toDouble();
        _controller.jumpTo(offset);
      });
    }
  }

  void _onScroll() {
    if (!_reloading && _controller.position.extentAfter < 700) _loadMore();
  }

  Future<void> _loadMore() async {
    if (!mounted || _reloading || _loading || !_hasMore) return;
    final generation = _loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _requestPage(_items.length);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items.addAll(page);
        _hasMore = page.length == _pageSize;
      });
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
        _scheduleLoadIfNeeded();
      }
    }
  }

  Future<List<EmbyItem>> _requestPage(int startIndex) {
    final facet = widget._facet;
    if (facet != null) {
      return widget.api.getLibraryItems(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
        sort: _sort,
        genreId: facet.kind == _LibraryFacetKind.genre ? facet.id : null,
        tagId: facet.kind == _LibraryFacetKind.tag ? facet.id : null,
      );
    }
    return switch (_section) {
      _LibrarySection.videos => widget.api.getLibraryItems(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
        sort: _sort,
      ),
      _LibrarySection.folders => widget.api.getLibraryFolders(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
      ),
      _LibrarySection.genres => widget.api.getLibraryGenres(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
      ),
      _LibrarySection.tags => widget.api.getLibraryTags(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
      ),
      _LibrarySection.favorites => widget.api.getLibraryItems(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
        sort: _sort,
        favoritesOnly: true,
      ),
    };
  }

  void _scheduleLoadIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _reloading ||
          _loading ||
          !_hasMore ||
          !_controller.hasClients) {
        return;
      }
      if (_controller.position.extentAfter < 700) unawaited(_loadMore());
    });
  }

  void _selectFilter(_LibraryMediaFilter filter) {
    if (filter == _filter) return;
    setState(() => _filter = filter);
    _scheduleLoadIfNeeded();
  }

  void _selectSection(_LibrarySection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _filter = _LibraryMediaFilter.all;
    });
    unawaited(_refresh());
  }

  void _selectSort(LibrarySort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    unawaited(_refresh());
  }

  Future<void> _playAll({bool shuffle = false}) async {
    final items = _playableItems.toList(growable: false);
    if (items.isEmpty) return;
    if (shuffle) items.shuffle();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          api: widget.api,
          item: items.first,
          queue: PlaybackQueue(api: widget.api, initialItems: items),
        ),
      ),
    );
    if (mounted) {
      await _refreshLoadedUserData();
      await _refreshRealtime();
    }
  }

  void _selectMore(_LibraryMoreAction action) {
    switch (action) {
      case _LibraryMoreAction.refresh:
        unawaited(_refresh());
        return;
      case _LibraryMoreAction.reset:
        final changed =
            _filter != _LibraryMediaFilter.all ||
            _sort != LibrarySort.nameAscending;
        if (changed) {
          setState(() {
            _filter = _LibraryMediaFilter.all;
            _sort = LibrarySort.nameAscending;
          });
        }
        unawaited(_refresh());
        return;
    }
  }

  Future<void> _refresh() async {
    _loadGeneration++;
    _pendingRealtimeLibraryRefresh = false;
    _pendingRealtimeUserDataIds.clear();
    setState(() {
      _items.clear();
      _loading = false;
      _reloading = false;
      _hasMore = true;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _open(EmbyItem item) async {
    if (!_isMediaView) {
      await _openGroup(item);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ItemDetailScreen(
          api: widget.api,
          initialItem: item,
          downloads: widget.downloads,
        ),
      ),
    );
    if (!mounted) return;
    try {
      final refreshed = await widget.api.getItem(item.id);
      if (!mounted) return;
      final index = _items.indexWhere((candidate) => candidate.id == item.id);
      if (index >= 0) setState(() => _items[index] = refreshed);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
    if (mounted) await _refreshRealtime();
  }

  Future<void> _openGroup(EmbyItem item) async {
    switch (_section) {
      case _LibrarySection.folders:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LibraryBrowseScreen(
              api: widget.api,
              view: item,
              downloads: widget.downloads,
            ),
          ),
        );
        if (mounted) await _refreshRealtime();
        return;
      case _LibrarySection.genres:
      case _LibrarySection.tags:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LibraryBrowseScreen._facet(
              api: widget.api,
              view: widget.view,
              downloads: widget.downloads,
              facet: _LibraryFacet(
                id: item.id,
                name: item.name,
                kind: _section == _LibrarySection.genres
                    ? _LibraryFacetKind.genre
                    : _LibraryFacetKind.tag,
              ),
            ),
          ),
        );
        if (mounted) await _refreshRealtime();
        return;
      case _LibrarySection.videos:
      case _LibrarySection.favorites:
        return;
    }
  }

  Widget _buildMediaGrid(List<EmbyItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          childAspectRatio: 0.52,
          crossAxisSpacing: 12,
          mainAxisSpacing: 18,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = items[index];
          return MediaPosterCard(
            key: ValueKey('library-item-${item.id}'),
            item: item,
            width: double.infinity,
            imageRequest: widget.api.imageRequest(item),
            onTap: () => _open(item),
          );
        }, childCount: items.length),
      ),
    );
  }

  Widget _buildGroupGrid(List<EmbyItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          childAspectRatio: 1.45,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = items[index];
          return _LibraryGroupCard(
            key: ValueKey('library-group-${item.id}'),
            item: item,
            icon: _section.icon,
            imageRequest: widget.api.imageRequest(item, maxWidth: 500),
            onTap: () => _open(item),
          );
        }, childCount: items.length),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayedItems = _displayedItems;
    final facet = widget._facet;
    return Scaffold(
      appBar: AppBar(title: Text(facet?.name ?? widget.view.name)),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (facet == null)
              SliverToBoxAdapter(
                child: _LibrarySectionBar(
                  selected: _section,
                  onSelected: _selectSection,
                ),
              ),
            if (_isMediaView)
              SliverToBoxAdapter(
                child: _LibraryActionBar(
                  filter: _filter,
                  sort: _sort,
                  canPlay: _playableItems.isNotEmpty,
                  onPlayAll: () => unawaited(_playAll()),
                  onShuffle: () => unawaited(_playAll(shuffle: true)),
                  onFilterSelected: _selectFilter,
                  onSortSelected: _selectSort,
                  onMoreSelected: _selectMore,
                ),
              ),
            if (_items.isEmpty && _loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty && _error != null)
              SliverFillRemaining(
                child: ErrorState(error: _error!, onRetry: _loadMore),
              )
            else if (_items.isEmpty)
              SliverFillRemaining(
                child: EmptyState(icon: _emptyIcon, title: _emptyTitle),
              )
            else if (displayedItems.isEmpty && _error != null)
              SliverFillRemaining(
                child: ErrorState(error: _error!, onRetry: _loadMore),
              )
            else if (displayedItems.isEmpty && (_loading || _hasMore))
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (displayedItems.isEmpty)
              SliverFillRemaining(
                child: EmptyState(
                  icon: _filter.emptyIcon,
                  title: _filter.emptyTitle,
                ),
              )
            else
              _isMediaView
                  ? _buildMediaGrid(displayedItems)
                  : _buildGroupGrid(displayedItems),
            if (displayedItems.isNotEmpty && (_loading || _error != null))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: _error != null
                      ? Center(
                          child: TextButton.icon(
                            onPressed: _loadMore,
                            icon: const Icon(Icons.refresh),
                            label: const Text('加载失败，重试'),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
