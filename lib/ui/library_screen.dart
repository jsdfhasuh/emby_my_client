import 'dart:async';

import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../realtime/emby_event.dart';
import '../realtime/realtime_refresh_binding.dart';
import '../settings/library_category_settings.dart';
import 'item_detail_screen.dart';
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
              final url =
                  widget.api.imageUrl(view, type: 'Backdrop', maxWidth: 700) ??
                  widget.api.imageUrl(view, maxWidth: 700);
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LibraryBrowseScreen(
                        api: widget.api,
                        view: view,
                        downloads: widget.downloads,
                        categorySettings: widget.categorySettings,
                      ),
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      EmbyImage(url: url, httpHeaders: widget.api.imageHeaders),
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
  });

  final EmbyApi api;
  final EmbyItem view;
  final DownloadService? downloads;
  final LibraryBrowseOptions initialOptions;
  final LibraryCategorySettings categorySettings;

  @override
  State<LibraryBrowseScreen> createState() => _LibraryBrowseScreenState();
}

class _LibraryBrowseScreenState extends State<LibraryBrowseScreen> {
  static const _pageSize = 60;
  final _controller = ScrollController();
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
  Object? _error;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions;
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

  void _onScroll() {
    if (!_reloading && _controller.position.extentAfter < 700) _loadMore();
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
      final page = await widget.api.getLibraryItems(
        parentId: widget.view.id,
        startIndex: startIndex,
        limit: _pageSize,
        options: _options,
      );
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
      _hasMore = true;
      _totalCount = null;
      _loading = false;
      _error = null;
    });
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
        _controller.jumpTo(offset);
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
    unawaited(_loadMore());
  }

  void _selectQuickCategory({
    required LibraryItemType itemType,
    bool favoriteOnly = false,
  }) {
    final folderView = itemType == LibraryItemType.folder;
    _applyOptions(
      _options.copyWith(
        itemType: itemType,
        favoriteOnly: favoriteOnly,
        playedFilter: folderView
            ? LibraryPlayedFilter.all
            : _options.playedFilter,
      ),
    );
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

  Future<void> _open(EmbyItem item) async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.view.name)),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildBrowseControls(context)),
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
                  icon: Icons.movie_filter_outlined,
                  title: _options.activeFilterCount > 0
                      ? '没有符合筛选条件的项目'
                      : '这个媒体库是空的',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    childAspectRatio: 0.52,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 18,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = _items[index];
                    return MediaPosterCard(
                      item: item,
                      width: double.infinity,
                      imageUrl: widget.api.imageUrl(item),
                      imageHeaders: widget.api.imageHeaders,
                      onTap: () => _open(item),
                    );
                  }, childCount: _items.length),
                ),
              ),
            if (_items.isNotEmpty && (_loading || _error != null))
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
