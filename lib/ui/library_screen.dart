import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../images/emby_image_request.dart';
import '../library/library_grid_geometry.dart';
import '../library/library_scroll_position_controller.dart';
import '../models/emby_models.dart';
import '../playback/playback_queue.dart';
import '../realtime/emby_event.dart';
import '../realtime/realtime_refresh_binding.dart';
import '../settings/library_category_settings.dart';
import 'item_detail_screen.dart';
import 'player_screen.dart';
import 'photos/photo_library_screen.dart';
import 'widgets/library_position_overlay.dart';
import 'widgets/media_widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.api,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
  });

  final EmbyApi api;
  final DownloadService? downloads;
  final LibraryCategorySettings categorySettings;

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
    this.initialOptions = const LibraryBrowseOptions(),
    this.categorySettings = const LibraryCategorySettings(),
  }) : _facet = null;

  const LibraryBrowseScreen._facet({
    required this.api,
    required this.view,
    required _LibraryFacet facet,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
  }) : initialOptions = const LibraryBrowseOptions(),
       _facet = facet;

  final EmbyApi api;
  final EmbyItem view;
  final DownloadService? downloads;
  final LibraryBrowseOptions initialOptions;
  final LibraryCategorySettings categorySettings;
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
              FilterChip(
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
                  tooltip: 'STRM 筛选',
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
  late final LibraryScrollPositionController _positionController;
  final List<EmbyItem> _items = [];
  late final RealtimeRefreshBinding _realtimeRefresh;
  late LibraryBrowseOptions _options;
  bool _loading = false;
  bool _reloading = false;
  bool _hasMore = true;
  bool _pendingRealtimeLibraryRefresh = false;
  final Set<String> _pendingRealtimeUserDataIds = {};
  int? _totalCount;
  int _generation = 0;
  int _positionGeneration = 0;
  bool _suppressPositionNotifications = false;
  Object? _error;
  _LibrarySection _section = _LibrarySection.videos;
  _LibraryMediaFilter _filter = _LibraryMediaFilter.all;
  LibrarySort _sort = LibrarySort.nameAscending;

  bool get _isMediaView =>
      widget._facet != null ||
      _section == _LibrarySection.videos ||
      _section == _LibrarySection.favorites;

  bool get _positionEnabled =>
      _isMediaView && _options.itemType != LibraryItemType.folder;

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
    _options = widget.initialOptions;
    _positionController = LibraryScrollPositionController();
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
    _positionController.dispose();
    unawaited(_realtimeRefresh.dispose());
    super.dispose();
  }

  void _onScroll() {
    if (!_reloading && _controller.position.extentAfter < 700) _loadMore();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_suppressPositionNotifications ||
        !_positionEnabled ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _positionController.onScrollStart();
    } else if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _positionController.onScrollUpdate();
    } else if (notification is ScrollEndNotification) {
      _positionController.onScrollEnd();
    }
    return false;
  }

  void _schedulePositionUpdate({
    required SliverConstraints constraints,
    required int loadedCount,
    required int? totalCount,
  }) {
    final generation = _positionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _positionGeneration || !_positionEnabled) {
        return;
      }
      _positionController.updateLayout(
        constraints: constraints,
        loadedCount: loadedCount,
        totalCount: totalCount,
      );
    });
  }

  void _clearPosition({bool scrollToTop = false}) {
    _positionGeneration++;
    if (scrollToTop && _controller.hasClients && _controller.offset != 0) {
      _controller.jumpTo(0);
    }
    _positionController.clear();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final generation = _generation;
    final startIndex = _items.length;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _requestPage(startIndex);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _totalCount = page.totalRecordCount;
        _hasMore = page.totalRecordCount == null
            ? page.items.length == _pageSize
            : _items.length < page.totalRecordCount!;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<EmbyItemPage> _requestPage(int startIndex) {
    final facet = widget._facet;
    if (facet != null) {
      return widget.api.getLibraryItems(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
        options: _options,
        genreId: facet.kind == _LibraryFacetKind.genre ? facet.id : null,
        tagId: facet.kind == _LibraryFacetKind.tag ? facet.id : null,
        includeMediaSources: true,
      );
    }
    return switch (_section) {
      _LibrarySection.videos => widget.api.getLibraryItems(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
        options: _options,
        includeMediaSources: true,
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
        options: _options,
        favoritesFilter: true,
        includeMediaSources: true,
      ),
    };
  }

  Future<void> _refresh() =>
      _reload(targetItemCount: _pageSize, restoreScrollPosition: false);

  Future<void> _refreshPreservingPosition() => _reload(
    targetItemCount: _items.length > _pageSize ? _items.length : _pageSize,
    restoreScrollPosition: true,
  );

  Future<void> _refreshRealtime() async {
    final reloadLibrary = _pendingRealtimeLibraryRefresh;
    final userDataIds = Set<String>.of(_pendingRealtimeUserDataIds);
    _pendingRealtimeLibraryRefresh = false;
    _pendingRealtimeUserDataIds.clear();
    try {
      if (reloadLibrary) {
        await _refreshPreservingPosition();
      } else {
        await _refreshUserData(userDataIds);
      }
    } catch (error) {
      DiagnosticLog.instance.warning(
        'library',
        'Realtime refresh failed library=${widget.view.id}: $error',
      );
    }
  }

  Future<void> _refreshUserData(Iterable<String> itemIds) async {
    final loadedIds = _items.map((item) => item.id).toSet();
    final requestedIds = itemIds.where(loadedIds.contains).toSet();
    if (requestedIds.isEmpty) return;
    final generation = _generation;
    final userData = await widget.api.getUserDataForItems(requestedIds);
    if (!mounted || generation != _generation || userData.isEmpty) return;
    setState(() {
      for (var index = 0; index < _items.length; index++) {
        final updated = userData[_items[index].id];
        if (updated != null) {
          _items[index] = _items[index].copyWith(userData: updated);
        }
      }
      if (widget._facet == null && _section == _LibrarySection.favorites) {
        final previousCount = _items.length;
        _items.removeWhere((item) => !item.userData.isFavorite);
        final removedCount = previousCount - _items.length;
        if (_totalCount != null && removedCount > 0) {
          _totalCount = _totalCount! > removedCount
              ? _totalCount! - removedCount
              : 0;
        }
      }
    });
  }

  Future<void> _reload({
    required int targetItemCount,
    required bool restoreScrollPosition,
  }) async {
    if (_reloading) return;
    _reloading = true;
    final previousOffset = restoreScrollPosition && _controller.hasClients
        ? _controller.offset
        : null;
    _generation++;
    setState(() {
      _items.clear();
      _loading = false;
      _hasMore = true;
      _totalCount = null;
      _loading = false;
      _error = null;
    });
    _clearPosition(scrollToTop: !restoreScrollPosition);
    try {
      while (mounted && _items.length < targetItemCount && _hasMore) {
        final previousCount = _items.length;
        await _loadMore();
        if (_error != null || _items.length <= previousCount) break;
      }
    } finally {
      _reloading = false;
    }
    if (previousOffset != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final offset = previousOffset
            .clamp(0.0, _controller.position.maxScrollExtent)
            .toDouble();
        _suppressPositionNotifications = true;
        try {
          _controller.jumpTo(offset);
        } finally {
          _suppressPositionNotifications = false;
          _clearPosition();
        }
      });
    }
  }

  void _applyOptions(LibraryBrowseOptions options) {
    if (options == _options) return;
    _generation++;
    setState(() {
      _options = options;
      _items.clear();
      _hasMore = true;
      _totalCount = null;
      _loading = false;
      _error = null;
    });
    _clearPosition(scrollToTop: true);
    unawaited(_loadMore());
  }

  void _selectQuickCategory({
    required LibraryItemType itemType,
    bool favoriteOnly = false,
  }) {
    final folderView = itemType == LibraryItemType.folder;
    final changedSectionOrLocalFilter =
        _section != _LibrarySection.videos ||
        _filter != _LibraryMediaFilter.all;
    if (changedSectionOrLocalFilter) {
      setState(() {
        _section = _LibrarySection.videos;
        _filter = _LibraryMediaFilter.all;
      });
    }
    final options = _options.copyWith(
      itemType: itemType,
      favoriteOnly: favoriteOnly,
      playedFilter: folderView
          ? LibraryPlayedFilter.all
          : _options.playedFilter,
    );
    if (options == _options) {
      if (changedSectionOrLocalFilter) unawaited(_refresh());
      return;
    }
    _applyOptions(options);
  }

  Future<void> _showFilters() async {
    var draft = _options;
    final selected = await showModalBottomSheet<LibraryBrowseOptions>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(LibraryBrowseOptions value) {
            setSheetState(() => draft = value);
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '筛选',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text('播放状态', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<LibraryPlayedFilter>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: LibraryPlayedFilter.all,
                          label: Text('全部'),
                        ),
                        ButtonSegment(
                          value: LibraryPlayedFilter.unplayed,
                          label: Text('未播放'),
                        ),
                        ButtonSegment(
                          value: LibraryPlayedFilter.played,
                          label: Text('已播放'),
                        ),
                      ],
                      selected: {draft.playedFilter},
                      onSelectionChanged: (selection) =>
                          update(draft.copyWith(playedFilter: selection.first)),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text('项目类型', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<LibraryItemType>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: LibraryItemType.all,
                          label: Text('节目'),
                        ),
                        ButtonSegment(
                          value: LibraryItemType.movie,
                          label: Text('电影'),
                        ),
                        ButtonSegment(
                          value: LibraryItemType.series,
                          label: Text('剧集'),
                        ),
                        ButtonSegment(
                          value: LibraryItemType.video,
                          label: Text('视频'),
                        ),
                        ButtonSegment(
                          value: LibraryItemType.folder,
                          label: Text('文件夹'),
                        ),
                      ],
                      selected: {draft.itemType},
                      onSelectionChanged: (selection) =>
                          update(draft.copyWith(itemType: selection.first)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.favorite_outline),
                    title: const Text('只看收藏'),
                    value: draft.favoriteOnly,
                    onChanged: (value) =>
                        update(draft.copyWith(favoriteOnly: value)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => update(
                          draft.copyWith(
                            playedFilter: LibraryPlayedFilter.all,
                            itemType: LibraryItemType.all,
                            favoriteOnly: false,
                          ),
                        ),
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('重置'),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(sheetContext).pop(draft),
                        icon: const Icon(Icons.check),
                        label: const Text('查看结果'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (selected != null && mounted) _applyOptions(selected);
  }

  void _selectFilter(_LibraryMediaFilter filter) {
    if (filter == _filter) return;
    setState(() => _filter = filter);
    _clearPosition(scrollToTop: true);
    if (_displayedItems.isEmpty && _hasMore) {
      unawaited(_loadUntilFilterMatches());
    }
  }

  Future<void> _loadUntilFilterMatches() async {
    while (mounted && _displayedItems.isEmpty && _hasMore && _error == null) {
      final previousCount = _items.length;
      await _loadMore();
      if (_items.length <= previousCount) break;
    }
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
    final options = switch (sort) {
      LibrarySort.nameAscending => _options.copyWith(
        sortBy: LibrarySortBy.name,
        sortOrder: LibrarySortOrder.ascending,
      ),
      LibrarySort.nameDescending => _options.copyWith(
        sortBy: LibrarySortBy.name,
        sortOrder: LibrarySortOrder.descending,
      ),
      LibrarySort.dateAddedDescending => _options.copyWith(
        sortBy: LibrarySortBy.dateAdded,
        sortOrder: LibrarySortOrder.descending,
      ),
      LibrarySort.productionYearDescending => _options.copyWith(
        sortBy: LibrarySortBy.productionYear,
        sortOrder: LibrarySortOrder.descending,
      ),
      LibrarySort.communityRatingDescending => _options.copyWith(
        sortBy: LibrarySortBy.communityRating,
        sortOrder: LibrarySortOrder.descending,
      ),
    };
    _applyOptions(options);
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
    if (mounted) await _refreshUserData(items.map((item) => item.id));
  }

  void _selectMore(_LibraryMoreAction action) {
    switch (action) {
      case _LibraryMoreAction.refresh:
        unawaited(_refresh());
        return;
      case _LibraryMoreAction.reset:
        setState(() {
          _filter = _LibraryMediaFilter.all;
          _sort = LibrarySort.nameAscending;
        });
        final reset = _options.copyWith(
          sortBy: LibrarySortBy.name,
          sortOrder: LibrarySortOrder.ascending,
          playedFilter: LibraryPlayedFilter.all,
          itemType: LibraryItemType.all,
          favoriteOnly: false,
        );
        if (reset == _options) {
          unawaited(_refresh());
        } else {
          _applyOptions(reset);
        }
        return;
    }
  }

  Future<void> _open(EmbyItem item) async {
    if (!_isMediaView) {
      await _openGroup(item);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => item.isFolder
            ? LibraryBrowseScreen(
                api: widget.api,
                view: item,
                downloads: widget.downloads,
                categorySettings: widget.categorySettings,
                initialOptions: _options.copyWith(
                  itemType: LibraryItemType.folder,
                  playedFilter: LibraryPlayedFilter.all,
                  favoriteOnly: false,
                ),
              )
            : ItemDetailScreen(
                api: widget.api,
                initialItem: item,
                downloads: widget.downloads,
              ),
      ),
    );
    if (!mounted) return;
    try {
      await _refreshUserData([item.id]);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
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
              categorySettings: widget.categorySettings,
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
              categorySettings: widget.categorySettings,
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
    final positionTotalCount = _filter == _LibraryMediaFilter.all
        ? _totalCount
        : !_hasMore && !_loading
        ? items.length
        : null;
    final grid = SliverGrid(
      gridDelegate: libraryMediaGridGeometry,
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
    );
    return SliverPadding(
      padding: libraryMediaGridGeometry.padding,
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          if (_positionEnabled) {
            _schedulePositionUpdate(
              constraints: constraints,
              loadedCount: items.length,
              totalCount: positionTotalCount,
            );
          }
          return grid;
        },
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
      body: Stack(
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: RefreshIndicator(
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
                  if (facet == null && _section == _LibrarySection.videos)
                    SliverToBoxAdapter(child: _buildBrowseControls(context)),
                  if (_isMediaView &&
                      _options.itemType != LibraryItemType.folder)
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
                      child: EmptyState(
                        icon: _emptyIcon,
                        title: _options.activeFilterCount > 0 && _isMediaView
                            ? '没有符合筛选条件的项目'
                            : _emptyTitle,
                      ),
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
                  else if (_isMediaView)
                    _buildMediaGrid(displayedItems)
                  else
                    _buildGroupGrid(displayedItems),
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
          ),
          LibraryPositionOverlay(controller: _positionController),
        ],
      ),
    );
  }

  Widget _buildBrowseControls(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    final countLabel = _totalCount == null
        ? (_items.isEmpty ? '正在统计' : '已加载 ${_items.length} 项')
        : '共 $_totalCount 项';
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _quickChip(
                    label: '节目',
                    selected:
                        !_options.favoriteOnly &&
                        _options.itemType == LibraryItemType.all,
                    onSelected: () =>
                        _selectQuickCategory(itemType: LibraryItemType.all),
                  ),
                  if (widget.categorySettings.showMovies)
                    _quickChip(
                      label: '电影',
                      selected:
                          !_options.favoriteOnly &&
                          _options.itemType == LibraryItemType.movie,
                      onSelected: () =>
                          _selectQuickCategory(itemType: LibraryItemType.movie),
                    ),
                  if (widget.categorySettings.showSeries)
                    _quickChip(
                      label: '剧集',
                      selected:
                          !_options.favoriteOnly &&
                          _options.itemType == LibraryItemType.series,
                      onSelected: () => _selectQuickCategory(
                        itemType: LibraryItemType.series,
                      ),
                    ),
                  if (widget.categorySettings.showVideos)
                    _quickChip(
                      label: '视频',
                      selected:
                          !_options.favoriteOnly &&
                          _options.itemType == LibraryItemType.video,
                      onSelected: () =>
                          _selectQuickCategory(itemType: LibraryItemType.video),
                    ),
                  if (widget.categorySettings.showFavorites)
                    _quickChip(
                      label: '收藏',
                      selected: _options.favoriteOnly,
                      onSelected: () => _selectQuickCategory(
                        itemType: LibraryItemType.all,
                        favoriteOnly: true,
                      ),
                    ),
                  if (widget.categorySettings.showFolders)
                    _quickChip(
                      label: '文件夹',
                      selected:
                          !_options.favoriteOnly &&
                          _options.itemType == LibraryItemType.folder,
                      onSelected: () => _selectQuickCategory(
                        itemType: LibraryItemType.folder,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  countLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<LibrarySortBy>(
                  tooltip: '排序方式',
                  initialValue: _options.sortBy,
                  onSelected: (sortBy) =>
                      _applyOptions(_options.copyWith(sortBy: sortBy)),
                  itemBuilder: (context) => LibrarySortBy.values
                      .map(
                        (sortBy) => PopupMenuItem(
                          value: sortBy,
                          child: Text(_sortLabel(sortBy)),
                        ),
                      )
                      .toList(growable: false),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sort, size: 18),
                        const SizedBox(width: 7),
                        Text(_sortLabel(_options.sortBy)),
                        const SizedBox(width: 3),
                        const Icon(Icons.arrow_drop_down, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                IconButton(
                  tooltip: _options.sortOrder == LibrarySortOrder.ascending
                      ? '当前升序，点击切换为降序'
                      : '当前降序，点击切换为升序',
                  onPressed: () => _applyOptions(
                    _options.copyWith(
                      sortOrder:
                          _options.sortOrder == LibrarySortOrder.ascending
                          ? LibrarySortOrder.descending
                          : LibrarySortOrder.ascending,
                    ),
                  ),
                  icon: Icon(
                    _options.sortOrder == LibrarySortOrder.ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                  ),
                ),
                IconButton(
                  tooltip: '筛选',
                  onPressed: _showFilters,
                  icon: _filterIcon(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(),
    ),
  );

  Widget _filterIcon() {
    final count = _options.activeFilterCount;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.filter_list),
        if (count > 0)
          Positioned(
            right: -7,
            top: -7,
            child: Container(
              width: 17,
              height: 17,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _sortLabel(LibrarySortBy sortBy) => switch (sortBy) {
    LibrarySortBy.name => '名称',
    LibrarySortBy.dateAdded => '加入日期',
    LibrarySortBy.premiereDate => '首映日期',
    LibrarySortBy.productionYear => '年份',
    LibrarySortBy.communityRating => '评分',
    LibrarySortBy.runtime => '时长',
  };
}
