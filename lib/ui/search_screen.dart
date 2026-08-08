import 'dart:async';

import 'package:flutter/material.dart';

import '../core/server_scope.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../realtime/realtime_refresh_binding.dart';
import '../search/search_history_store.dart';
import '../settings/library_category_settings.dart';
import 'item_detail_screen.dart';
import 'library_screen.dart';
import 'widgets/media_widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.api,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
    this.historyStore,
  });

  final EmbyApi api;
  final DownloadService? downloads;
  final LibraryCategorySettings categorySettings;
  final SearchHistoryStore? historyStore;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _pageSize = 60;

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _debounce;
  final List<EmbyItem> _results = [];
  List<String> _recentSearches = const [];
  SearchItemType _itemType = SearchItemType.all;
  bool _waitingForDebounce = false;
  bool _loading = false;
  bool _hasSearched = false;
  bool _hasMore = false;
  Object? _error;
  int? _totalCount;
  int _generation = 0;
  int _nextStartIndex = 0;
  String _activeQuery = '';
  late final RealtimeRefreshBinding _realtimeRefresh;
  late final SearchHistoryStore _historyStore;
  late final ServerScope _scope;

  @override
  void initState() {
    super.initState();
    _historyStore =
        widget.historyStore ?? SharedPreferencesSearchHistoryStore();
    _scope = ServerScope.fromSession(widget.api.session);
    _scrollController.addListener(_onScroll);
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _refreshRealtime,
      shouldRefresh: (event) =>
          isLibraryRefreshEvent(event, userId: widget.api.session.userId),
    );
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    unawaited(_realtimeRefresh.dispose());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final recent = await _historyStore.load(_scope);
    if (mounted) setState(() => _recentSearches = recent);
  }

  Future<void> _rememberSearch(String query) async {
    await _historyStore.add(_scope, query);
    await _loadHistory();
  }

  Future<void> _clearHistory() async {
    await _historyStore.clear(_scope);
    if (mounted) setState(() => _recentSearches = const []);
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 700) {
      unawaited(_loadMore());
    }
  }

  Future<void> _refreshRealtime() async {
    if (_activeQuery.isNotEmpty) await _startSearch(_activeQuery);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      _resetToIdle();
      return;
    }

    final generation = _prepareSearch(query, waitingForDebounce: true);
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _performSearch(query, generation),
    );
  }

  int _prepareSearch(String query, {bool waitingForDebounce = false}) {
    final generation = ++_generation;
    setState(() {
      _activeQuery = query;
      _results.clear();
      _hasSearched = true;
      _hasMore = true;
      _totalCount = null;
      _nextStartIndex = 0;
      _waitingForDebounce = waitingForDebounce;
      _loading = false;
      _error = null;
    });
    return generation;
  }

  void _resetToIdle() {
    _generation++;
    setState(() {
      _activeQuery = '';
      _results.clear();
      _hasSearched = false;
      _hasMore = false;
      _totalCount = null;
      _nextStartIndex = 0;
      _waitingForDebounce = false;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _startSearch(String query, {bool remember = false}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _resetToIdle();
      return;
    }
    _debounce?.cancel();
    final generation = _prepareSearch(trimmed);
    if (remember) unawaited(_rememberSearch(trimmed));
    await _performSearch(trimmed, generation);
  }

  Future<void> _performSearch(String query, int generation) async {
    if (!mounted || generation != _generation || _loading) return;
    setState(() {
      _waitingForDebounce = false;
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.search(
        query,
        startIndex: _nextStartIndex,
        limit: _pageSize,
        itemType: _itemType,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final knownIds = _results.map((item) => item.id).toSet();
        _results.addAll(page.items.where((item) => knownIds.add(item.id)));
        _nextStartIndex += page.items.length;
        _totalCount = page.totalRecordCount;
        _hasMore =
            page.items.isNotEmpty &&
            (page.totalRecordCount == null
                ? page.items.length == _pageSize
                : _nextStartIndex < page.totalRecordCount!);
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

  Future<void> _loadMore() async {
    if (_loading ||
        _waitingForDebounce ||
        !_hasSearched ||
        !_hasMore ||
        _activeQuery.isEmpty) {
      return;
    }
    await _performSearch(_activeQuery, _generation);
  }

  Future<void> _refresh() => _startSearch(_activeQuery);

  void _selectRecent(String query) {
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    unawaited(_startSearch(query, remember: true));
  }

  void _selectItemType(SearchItemType itemType) {
    if (_itemType == itemType) return;
    setState(() => _itemType = itemType);
    if (_controller.text.trim().isNotEmpty) {
      unawaited(_startSearch(_controller.text));
    }
  }

  Future<void> _open(EmbyItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => item.isFolder
            ? LibraryBrowseScreen.directory(
                api: widget.api,
                view: item,
                downloads: widget.downloads,
                categorySettings: widget.categorySettings,
              )
            : ItemDetailScreen(
                api: widget.api,
                initialItem: item,
                downloads: widget.downloads,
              ),
      ),
    );
    if (mounted && _activeQuery.isNotEmpty) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = _waitingForDebounce || _loading;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: TextField(
            controller: _controller,
            autofocus: false,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (value) => _startSearch(value, remember: true),
            decoration: InputDecoration(
              hintText: '搜索媒体和文件夹',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 2,
          child: isBusy
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox.shrink(),
        ),
        _buildTypeFilters(),
        Expanded(child: _buildResult()),
      ],
    );
  }

  Widget _buildTypeFilters() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        scrollDirection: Axis.horizontal,
        itemCount: SearchItemType.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final itemType = SearchItemType.values[index];
          return ChoiceChip(
            selected: _itemType == itemType,
            onSelected: (_) => _selectItemType(itemType),
            avatar: Icon(itemType.icon, size: 17),
            label: Text(itemType.label),
          );
        },
      ),
    );
  }

  Widget _buildResult() {
    if (!_hasSearched) return _buildSearchLanding();
    if ((_waitingForDebounce || _loading) && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _results.isEmpty) {
      return ErrorState(
        error: _error!,
        onRetry: () => _performSearch(_activeQuery, _generation),
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有找到匹配的${_itemType.label}',
        message: '可以换一个关键词或媒体类型',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                childAspectRatio: 0.52,
                crossAxisSpacing: 12,
                mainAxisSpacing: 18,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = _results[index];
                return MediaPosterCard(
                  item: item,
                  width: double.infinity,
                  imageRequest: widget.api.imageRequest(item),
                  onTap: () => _open(item),
                );
              }, childCount: _results.length),
            ),
          ),
          SliverToBoxAdapter(child: _buildResultFooter()),
        ],
      ),
    );
  }

  Widget _buildSearchLanding() {
    if (_recentSearches.isEmpty) {
      return const EmptyState(
        icon: Icons.manage_search,
        title: '搜索你的媒体库',
        message: '支持电影、剧集、单集、视频和文件夹',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '最近搜索',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '清空最近搜索',
              onPressed: _clearHistory,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final query in _recentSearches)
              ActionChip(
                avatar: const Icon(Icons.history, size: 17),
                label: Text(query),
                onPressed: () => _selectRecent(query),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildResultFooter() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 28),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 28),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.refresh),
            label: const Text('继续加载'),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 28),
        child: Center(
          child: Text(
            _totalCount == null ? '已显示全部结果' : '共 ${_totalCount!} 项结果',
            style: const TextStyle(color: Color(0xFF9DA6A9)),
          ),
        ),
      );
    }
    return const SizedBox(height: 28);
  }
}

extension on SearchItemType {
  String get label => switch (this) {
    SearchItemType.all => '全部',
    SearchItemType.movie => '电影',
    SearchItemType.series => '剧集',
    SearchItemType.episode => '单集',
    SearchItemType.video => '视频',
    SearchItemType.folder => '文件夹',
  };

  IconData get icon => switch (this) {
    SearchItemType.all => Icons.apps,
    SearchItemType.movie => Icons.movie_outlined,
    SearchItemType.series => Icons.tv_outlined,
    SearchItemType.episode => Icons.play_circle_outline,
    SearchItemType.video => Icons.video_library_outlined,
    SearchItemType.folder => Icons.folder_outlined,
  };
}
