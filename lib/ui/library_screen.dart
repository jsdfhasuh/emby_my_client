import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../images/emby_image_request.dart';
import '../library/library_alphabet_filter.dart';
import '../library/library_browse_state.dart';
import '../library/library_content_profile.dart';
import '../library/library_entry_action.dart';
import '../library/library_grid_geometry.dart';
import '../library/library_item_membership.dart';
import '../library/library_local_media_scan_cache.dart';
import '../library/library_local_media_scan_service.dart';
import '../library/library_playback_queue.dart';
import '../library/library_raw_page_cursor.dart';
import '../library/library_result_statistics.dart';
import '../library/library_scroll_position_controller.dart';
import '../models/emby_models.dart';
import '../photos/photo_sequence_source.dart';
import '../platform/platform_capabilities.dart';
import '../playback/playback_queue.dart';
import '../realtime/emby_event.dart';
import '../realtime/realtime_refresh_binding.dart';
import '../settings/library_category_settings.dart';
import 'item_detail_screen.dart';
import 'home_shell_navigation.dart';
import 'photos/photo_viewer_screen.dart';
import 'player_screen.dart';
import 'widgets/library_alphabet_navigation.dart';
import 'widgets/library_directory_entry_card.dart';
import 'widgets/library_mixed_entry_card.dart';
import 'widgets/library_photo_card.dart';
import 'widgets/library_position_overlay.dart';
import 'widgets/media_widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.api,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
    this.libraryScanService,
    this.navigationActions,
    this.platformCapabilities,
  });

  final EmbyApi api;
  final DownloadService? downloads;
  final LibraryCategorySettings categorySettings;
  final LibraryLocalMediaScanService? libraryScanService;
  final HomeShellNavigationActions? navigationActions;
  final PlatformCapabilities? platformCapabilities;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<EmbyItem>> _future;
  late final RealtimeRefreshBinding _realtimeRefresh;

  @override
  void initState() {
    super.initState();
    _future = _loadViews();
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _refresh,
      shouldRefresh: (event) =>
          isLibraryRefreshEvent(event, userId: widget.api.session.userId),
    );
  }

  Future<List<EmbyItem>> _loadViews() async {
    try {
      return await widget.api.getViews();
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'library',
        'Library roots failed to load',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    unawaited(_realtimeRefresh.dispose());
    super.dispose();
  }

  Future<void> _refresh() async {
    final future = _loadViews();
    setState(() => _future = future);
    await future;
  }

  Future<void> _openView(EmbyItem view) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LibraryBrowseScreen.root(
          api: widget.api,
          view: view,
          downloads: widget.downloads,
          categorySettings: widget.categorySettings,
          libraryScanService: widget.libraryScanService,
          navigationActions: widget.navigationActions,
          platformCapabilities: widget.platformCapabilities,
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
          return _FixedLibraryErrorState(onRetry: () => _refresh());
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

enum _LibraryBrowsePageKind { root, directory, facet }

class _LibraryQuerySnapshot {
  const _LibraryQuerySnapshot({
    required this.items,
    required this.seenItemIds,
    required this.nextStartIndex,
    required this.totalCount,
    required this.totalDirty,
    required this.reportedTotalBelowLoaded,
    required this.hasMore,
    required this.loadFailed,
  });

  final List<EmbyItem> items;
  final Set<String> seenItemIds;
  final int nextStartIndex;
  final int? totalCount;
  final bool totalDirty;
  final bool reportedTotalBelowLoaded;
  final bool hasMore;
  final bool loadFailed;
}

Future<EmbyItemPage> _loadLibraryMediaPage({
  required EmbyApi api,
  required String parentId,
  required LibraryContentProfile profile,
  required LibraryBrowseState state,
  required int startIndex,
  required int limit,
}) => api.getLibraryMediaItems(
  parentId: parentId,
  profile: profile,
  startIndex: startIndex,
  limit: limit,
  mediaType: state.mediaType,
  playedFilter: state.playedFilter,
  favorites: state.scope == LibraryBrowseScope.favorites,
  sortBy: state.sortBy,
  sortOrder: state.sortOrder,
  alphabetFilter: state.alphabetFilter,
  genreId: state.facet?.kind == LibraryFacetKind.genre ? state.facet!.id : null,
  tagId: state.facet?.kind == LibraryFacetKind.tag ? state.facet!.id : null,
);

class LibraryBrowseScreen extends StatefulWidget {
  LibraryBrowseScreen.root({
    super.key,
    required this.api,
    required this.view,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
    this.libraryScanService,
    this.navigationActions,
    this.platformCapabilities,
    this.initialState = const LibraryBrowseState(),
    LibraryContentProfile? profile,
  }) : profile =
           profile ??
           LibraryContentProfile.fromCollectionType(view.collectionType),
       _pageKind = _LibraryBrowsePageKind.root;

  LibraryBrowseScreen.directory({
    super.key,
    required this.api,
    required this.view,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
    this.libraryScanService,
    this.navigationActions,
    this.platformCapabilities,
    this.initialState = const LibraryBrowseState.directory(),
    LibraryContentProfile? profile,
  }) : assert(initialState.scope == LibraryBrowseScope.directory),
       profile =
           profile ??
           LibraryContentProfile.fromCollectionType(view.collectionType),
       _pageKind = _LibraryBrowsePageKind.directory;

  LibraryBrowseScreen.facet({
    super.key,
    required this.api,
    required this.view,
    required LibraryFacet facet,
    this.downloads,
    this.categorySettings = const LibraryCategorySettings(),
    this.libraryScanService,
    this.navigationActions,
    this.platformCapabilities,
    LibraryBrowseState? initialState,
    LibraryContentProfile? profile,
  }) : initialState = initialState ?? LibraryBrowseState.facet(facet),
       profile =
           profile ??
           LibraryContentProfile.fromCollectionType(view.collectionType),
       assert(
         initialState == null || initialState.scope == LibraryBrowseScope.facet,
       ),
       _pageKind = _LibraryBrowsePageKind.facet;

  final EmbyApi api;
  final EmbyItem view;
  final DownloadService? downloads;
  final LibraryCategorySettings categorySettings;
  final LibraryContentProfile profile;
  final LibraryLocalMediaScanService? libraryScanService;
  final HomeShellNavigationActions? navigationActions;
  final PlatformCapabilities? platformCapabilities;
  final LibraryBrowseState initialState;
  final _LibraryBrowsePageKind _pageKind;

  @override
  State<LibraryBrowseScreen> createState() => _LibraryBrowseScreenState();
}

extension on LibraryBrowseScope {
  String get label => switch (this) {
    LibraryBrowseScope.media => '媒体',
    LibraryBrowseScope.directory => '目录',
    LibraryBrowseScope.genres => '分类',
    LibraryBrowseScope.tags => '标签',
    LibraryBrowseScope.favorites => '收藏',
    LibraryBrowseScope.facet => '媒体',
  };

  IconData get icon => switch (this) {
    LibraryBrowseScope.media => Icons.movie_outlined,
    LibraryBrowseScope.directory => Icons.folder_outlined,
    LibraryBrowseScope.genres => Icons.category_outlined,
    LibraryBrowseScope.tags => Icons.label_outline,
    LibraryBrowseScope.favorites => Icons.favorite_border,
    LibraryBrowseScope.facet => Icons.movie_outlined,
  };

  String get emptyTitle => switch (this) {
    LibraryBrowseScope.media => '这个媒体库是空的',
    LibraryBrowseScope.directory => '没有目录或媒体',
    LibraryBrowseScope.genres => '没有分类',
    LibraryBrowseScope.tags => '没有标签',
    LibraryBrowseScope.favorites => '还没有收藏的媒体',
    LibraryBrowseScope.facet => '该分类中没有媒体',
  };
}

extension on LibraryMediaType {
  String get label => switch (this) {
    LibraryMediaType.all => '全部',
    LibraryMediaType.movie => '电影',
    LibraryMediaType.series => '剧集',
    LibraryMediaType.video => '视频',
    LibraryMediaType.photo => '图片',
  };
}

extension on LibraryLocalMediaFilter {
  String get label => switch (this) {
    LibraryLocalMediaFilter.all => '全部',
    LibraryLocalMediaFilter.strm => 'STRM',
    LibraryLocalMediaFilter.regular => '普通媒体',
  };

  String get emptyTitle => switch (this) {
    LibraryLocalMediaFilter.all => '这个媒体库是空的',
    LibraryLocalMediaFilter.strm => '没有 STRM 媒体',
    LibraryLocalMediaFilter.regular => '没有普通媒体',
  };

  IconData get emptyIcon => switch (this) {
    LibraryLocalMediaFilter.all => Icons.movie_filter_outlined,
    LibraryLocalMediaFilter.strm => Icons.link_off_outlined,
    LibraryLocalMediaFilter.regular => Icons.movie_outlined,
  };
}

enum _LibraryMoreAction { refresh, reset, clearScan }

class _LibraryScopeBar extends StatelessWidget {
  const _LibraryScopeBar({
    required this.selected,
    required this.scopes,
    required this.onSelected,
  });

  final LibraryBrowseScope selected;
  final Set<LibraryBrowseScope> scopes;
  final ValueChanged<LibraryBrowseScope> onSelected;

  @override
  Widget build(BuildContext context) {
    final visibleScopes = LibraryBrowseScope.values
        .where(scopes.contains)
        .where((scope) => scope != LibraryBrowseScope.facet)
        .toList(growable: false);
    return Padding(
      key: const ValueKey('library-section-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('浏览方式', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final scope in visibleScopes) ...[
                  FilterChip(
                    key: ValueKey(
                      'library-section-${scope == LibraryBrowseScope.directory ? 'directories' : scope.name}',
                    ),
                    label: Text(scope.label),
                    selected: selected == scope,
                    showCheckmark: false,
                    onSelected: (isSelected) {
                      if (isSelected) onSelected(scope);
                    },
                  ),
                  if (scope != visibleScopes.last) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryBrowseToolbar extends StatelessWidget {
  const _LibraryBrowseToolbar({
    required this.primaryResultLabel,
    required this.scanProgressLabel,
    required this.sortBy,
    required this.sortOrder,
    required this.showPlaybackActions,
    required this.canPlay,
    required this.showFilter,
    required this.filterSummary,
    required this.canReset,
    required this.canClearScan,
    required this.largeLayout,
    required this.videoOnly,
    required this.onPlayAll,
    required this.onShuffle,
    required this.onSortSelected,
    required this.onToggleSortOrder,
    required this.onShowFilter,
    required this.onMoreSelected,
  });

  final String primaryResultLabel;
  final String? scanProgressLabel;
  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
  final bool showPlaybackActions;
  final bool canPlay;
  final bool showFilter;
  final String filterSummary;
  final bool canReset;
  final bool canClearScan;
  final bool largeLayout;
  final bool videoOnly;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  final ValueChanged<LibrarySortBy> onSortSelected;
  final VoidCallback onToggleSortOrder;
  final VoidCallback onShowFilter;
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
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: largeLayout ? 150 : 56,
                    maxWidth: largeLayout ? 230 : 88,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        primaryResultLabel,
                        key: const ValueKey('library-result-summary'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (scanProgressLabel case final progress?)
                        Text(
                          progress,
                          key: const ValueKey('library-scan-progress'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                    .withValues(alpha: 0.78),
                              ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (showPlaybackActions) ...[
                  _toolbarCommand(
                    key: const ValueKey('library-play-all-button'),
                    icon: Icons.play_arrow,
                    label: videoOnly ? '播放视频' : '播放全部',
                    enabled: canPlay,
                    onPressed: onPlayAll,
                  ),
                  _toolbarCommand(
                    key: const ValueKey('library-shuffle-button'),
                    icon: Icons.shuffle,
                    label: videoOnly ? '随机视频' : '随机播放',
                    enabled: canPlay,
                    onPressed: onShuffle,
                  ),
                ],
                PopupMenuButton<LibrarySortBy>(
                  key: const ValueKey('library-sort-button'),
                  tooltip: '排序方式',
                  initialValue: sortBy,
                  onSelected: onSortSelected,
                  itemBuilder: (context) => [
                    for (final option in LibrarySortBy.values)
                      PopupMenuItem(
                        key: ValueKey('library-sort-${option.name}'),
                        value: option,
                        child: Text(_sortLabel(option)),
                      ),
                  ],
                  child: _toolbarChild(
                    icon: Icons.sort,
                    label: _sortLabel(sortBy),
                  ),
                ),
                IconButton(
                  key: const ValueKey('library-sort-direction-button'),
                  tooltip: sortOrder == LibrarySortOrder.ascending
                      ? '当前升序，点击切换为降序'
                      : '当前降序，点击切换为升序',
                  onPressed: onToggleSortOrder,
                  icon: Icon(
                    sortOrder == LibrarySortOrder.ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                  ),
                ),
                if (showFilter)
                  _toolbarCommand(
                    key: const ValueKey('library-filter-button'),
                    icon: filterSummary == '筛选'
                        ? Icons.filter_list
                        : Icons.filter_alt,
                    label: filterSummary,
                    enabled: true,
                    onPressed: onShowFilter,
                  ),
                PopupMenuButton<_LibraryMoreAction>(
                  key: const ValueKey('library-more-button'),
                  tooltip: '更多',
                  icon: const Icon(Icons.more_horiz),
                  onSelected: onMoreSelected,
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      key: ValueKey('library-more-refresh'),
                      value: _LibraryMoreAction.refresh,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.refresh),
                        title: Text('刷新'),
                      ),
                    ),
                    if (canReset)
                      const PopupMenuItem(
                        key: ValueKey('library-more-reset'),
                        value: _LibraryMoreAction.reset,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.restart_alt),
                          title: Text('重置筛选和排序'),
                        ),
                      ),
                    if (canClearScan)
                      const PopupMenuItem(
                        key: ValueKey('library-more-clear-scan'),
                        value: _LibraryMoreAction.clearScan,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.cleaning_services_outlined),
                          title: Text('清理扫描缓存'),
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

  Widget _toolbarCommand({
    required Key key,
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    if (largeLayout) {
      return TextButton.icon(
        key: key,
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon),
        label: Text(label, maxLines: 1),
      );
    }
    return IconButton(
      key: key,
      tooltip: enabled ? label : '统计完成后可用',
      onPressed: enabled ? onPressed : null,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      icon: Icon(icon),
    );
  }

  Widget _toolbarChild({required IconData icon, required String label}) {
    if (!largeLayout) {
      return const SizedBox.square(dimension: 40, child: Icon(Icons.sort));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          const SizedBox(width: 6),
          Text(label, maxLines: 1),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

class _LibraryFilterSheet extends StatefulWidget {
  const _LibraryFilterSheet({
    required this.initialDraft,
    required this.mediaTypes,
    required this.supportsLocalSource,
    required this.supportsPlayed,
  });

  final LibraryFilterDraft initialDraft;
  final List<LibraryMediaType> mediaTypes;
  final bool supportsLocalSource;
  final bool supportsPlayed;

  @override
  State<_LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<_LibraryFilterSheet> {
  late LibraryFilterDraft _draft = widget.initialDraft;

  bool get _isPhoto => _draft.mediaType == LibraryMediaType.photo;

  void _update(LibraryFilterDraft draft) => setState(() => _draft = draft);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '筛选',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (widget.mediaTypes.length > 1) ...[
              const SizedBox(height: 20),
              Text('媒体类型', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              _choiceRow<LibraryMediaType>(
                values: widget.mediaTypes,
                selected: _draft.mediaType,
                keyFor: (value) => ValueKey('library-media-type-${value.name}'),
                labelFor: (value) => value.label,
                onSelected: (value) =>
                    _update(_draft.copyWith(mediaType: value)),
              ),
            ],
            if (widget.supportsLocalSource && !_isPhoto) ...[
              const SizedBox(height: 20),
              Text('来源', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              _choiceRow<LibraryLocalMediaFilter>(
                values: LibraryLocalMediaFilter.values,
                selected: _draft.localFilter,
                keyFor: (value) => ValueKey('library-filter-${value.name}'),
                labelFor: (value) => value.label,
                onSelected: (value) =>
                    _update(_draft.copyWith(localFilter: value)),
              ),
            ],
            if (widget.supportsPlayed && !_isPhoto) ...[
              const SizedBox(height: 20),
              Text('播放状态', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              _choiceRow<LibraryPlayedFilter>(
                values: LibraryPlayedFilter.values,
                selected: _draft.playedFilter,
                keyFor: (value) => ValueKey('library-played-${value.name}'),
                labelFor: (value) => switch (value) {
                  LibraryPlayedFilter.all => '全部',
                  LibraryPlayedFilter.unplayed => '未播放',
                  LibraryPlayedFilter.played => '已播放',
                },
                onSelected: (value) =>
                    _update(_draft.copyWith(playedFilter: value)),
              ),
            ],
            const SizedBox(height: 20),
            OverflowBar(
              spacing: 8,
              overflowSpacing: 8,
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('library-filter-reset'),
                  onPressed: () => _update(_draft.reset()),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('重置'),
                ),
                TextButton(
                  key: const ValueKey('library-filter-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  key: const ValueKey('library-filter-apply'),
                  onPressed: () => Navigator.of(context).pop(_draft),
                  icon: const Icon(Icons.check),
                  label: const Text('查看结果'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _choiceRow<T>({
    required Iterable<T> values,
    required T selected,
    required Key Function(T value) keyFor,
    required String Function(T value) labelFor,
    required ValueChanged<T> onSelected,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          ChoiceChip(
            key: keyFor(value),
            label: Text(labelFor(value)),
            selected: selected == value,
            showCheckmark: false,
            onSelected: (isSelected) {
              if (isSelected) onSelected(value);
            },
          ),
      ],
    );
  }
}

enum _LibraryPlaybackPreparationStatus { ready, cancelled, empty, failed }

class _LibraryPlaybackPreparationResult {
  const _LibraryPlaybackPreparationResult(this.status, [this.queue]);

  final _LibraryPlaybackPreparationStatus status;
  final LazyLibraryPlaybackQueue? queue;
}

class _LibraryPlaybackPreparationDialog extends StatefulWidget {
  const _LibraryPlaybackPreparationDialog({
    required this.prepare,
    required this.onFailure,
  });

  final Future<LazyLibraryPlaybackQueue?> Function(
    LibraryPlaybackCancellation cancellation,
    LibraryPlaybackProgressCallback onProgress,
  )
  prepare;
  final void Function(Object error, StackTrace stackTrace) onFailure;

  @override
  State<_LibraryPlaybackPreparationDialog> createState() =>
      _LibraryPlaybackPreparationDialogState();
}

class _LibraryPlaybackPreparationDialogState
    extends State<_LibraryPlaybackPreparationDialog> {
  final _cancellation = LibraryPlaybackCancellation();
  LibraryPlaybackPreparationProgress? _progress;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final queue = await widget.prepare(_cancellation, (progress) {
        if (mounted) setState(() => _progress = progress);
      });
      if (!mounted) return;
      Navigator.of(context).pop(
        _LibraryPlaybackPreparationResult(
          queue == null
              ? _LibraryPlaybackPreparationStatus.empty
              : _LibraryPlaybackPreparationStatus.ready,
          queue,
        ),
      );
    } on LibraryPlaybackCancelled {
      if (mounted) {
        Navigator.of(context).pop(
          const _LibraryPlaybackPreparationResult(
            _LibraryPlaybackPreparationStatus.cancelled,
          ),
        );
      }
    } catch (error, stackTrace) {
      widget.onFailure(error, stackTrace);
      if (mounted) {
        Navigator.of(context).pop(
          const _LibraryPlaybackPreparationResult(
            _LibraryPlaybackPreparationStatus.failed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final total = progress?.totalCount;
    final scanned = progress?.rawScannedCount ?? 0;
    return AlertDialog(
      title: const Text('正在准备播放队列'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(total == null ? '正在读取完整结果' : '已读取 $scanned/$total 项'),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('library-playback-prepare-cancel'),
          onPressed: _cancelling
              ? null
              : () {
                  setState(() => _cancelling = true);
                  _cancellation.cancel();
                },
          child: Text(_cancelling ? '正在取消' : '取消'),
        ),
      ],
    );
  }
}

class _LibraryFacetCard extends StatelessWidget {
  const _LibraryFacetCard({
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
    return Semantics(
      button: true,
      label: '打开${item.name}',
      child: Card(
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
      ),
    );
  }
}

class _LibraryBrowseScreenState extends State<LibraryBrowseScreen> {
  static const _pageSize = 60;

  final _controller = ScrollController();
  final List<EmbyItem> _items = [];
  final Set<String> _seenItemIds = {};
  late final LibraryScrollPositionController _positionController;
  late final RealtimeRefreshBinding _realtimeRefresh;
  late LibraryBrowseState _state;

  bool _loading = false;
  Future<void>? _activeLoad;
  int? _activeLoadGeneration;
  Future<void>? _activeReload;
  int? _reloadGeneration;
  bool _hasMore = true;
  bool _loadFailed = false;
  bool _pendingRealtimeLibraryRefresh = false;
  final Set<String> _pendingRealtimeUserDataIds = {};
  int _nextStartIndex = 0;
  int? _totalCount;
  bool _resultTotalDirty = false;
  bool _reportedTotalBelowLoaded = false;
  int _generation = 0;
  int _positionGeneration = 0;
  bool _suppressPositionNotifications = false;
  LibraryScanKey? _activeScanKey;
  LibraryLocalScanSnapshot? _scanSnapshot;
  bool _preparingPlaybackQueue = false;

  bool get _isRoot => widget._pageKind == _LibraryBrowsePageKind.root;

  Set<LibraryBrowseScope> get _visibleScopes =>
      widget.profile.visibleScopes(widget.categorySettings);

  Set<LibraryBrowseScope> get _allowedScopesForPage =>
      widget._pageKind == _LibraryBrowsePageKind.directory
      ? const {LibraryBrowseScope.directory}
      : _visibleScopes;

  Set<LibraryMediaType> get _visibleMediaTypes =>
      widget.profile.visibleMediaTypes(widget.categorySettings);

  bool get _isMediaScope => _state.scope.supportsMediaFilters;

  bool get _usesLocalScan => _state.localFilter != LibraryLocalMediaFilter.all;

  bool get _isReloadingCurrentGeneration => _reloadGeneration == _generation;

  bool get _positionEnabled => _items.isNotEmpty;

  bool get _alphabetEnabled => _state.alphabetEnabled;

  PlatformCapabilities get _platformCapabilities =>
      widget.platformCapabilities ?? PlatformCapabilities.current();

  List<LibraryMediaType> get _filterMediaTypes =>
      widget.profile.kind == LibraryContentProfileKind.photos
      ? const [LibraryMediaType.all]
      : LibraryMediaType.values
            .where(_visibleMediaTypes.contains)
            .toList(growable: false);

  bool get _showFilter =>
      _isMediaScope &&
      (_filterMediaTypes.length > 1 ||
          widget.profile.supportsLocalSourceFilter ||
          widget.profile.supportsPlayedFilter);

  String get _filterSummary {
    final labels = <String>[
      if (_state.mediaType != LibraryMediaType.all) _state.mediaType.label,
      if (_state.localFilter != LibraryLocalMediaFilter.all)
        _state.localFilter.label,
      if (_state.playedFilter != LibraryPlayedFilter.all)
        switch (_state.playedFilter) {
          LibraryPlayedFilter.unplayed => '未播放',
          LibraryPlayedFilter.played => '已播放',
          LibraryPlayedFilter.all => '',
        },
    ];
    return labels.isEmpty ? '筛选' : '筛选 · ${labels.join(' · ')}';
  }

  bool _isLargeIPadLandscape(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return _platformCapabilities.targetDeviceFamily == 'iPad' &&
        size.width > size.height &&
        size.shortestSide >= 600;
  }

  List<EmbyItem> get _playableItems =>
      _items.where((item) => item.isPlayable).toList(growable: false);

  bool get _canPlayCompleteResult =>
      !_preparingPlaybackQueue &&
      !_loadFailed &&
      !_resultTotalDirty &&
      canPlayCompleteLibraryResult(
        state: _state,
        profile: widget.profile,
        playableLoadedCount: _playableItems.length,
        hasMore: _hasMore,
        localScan: _scanSnapshot,
      );

  LibraryLocalScanStatus get _scanStatus {
    if (!_usesLocalScan) {
      return LibraryLocalScanStatus.inactive;
    }
    final snapshot = _scanSnapshot;
    if (snapshot?.safeError == LibraryScanErrorKind.paginationStalled) {
      return LibraryLocalScanStatus.paginationStalled;
    }
    if (snapshot == null || snapshot.safeError != null) {
      return LibraryLocalScanStatus.interrupted;
    }
    return switch (snapshot.status) {
      LibraryScanStatus.complete => LibraryLocalScanStatus.complete,
      LibraryScanStatus.queued ||
      LibraryScanStatus.scanning ||
      LibraryScanStatus.paused => LibraryLocalScanStatus.scanning,
      LibraryScanStatus.cancelled => LibraryLocalScanStatus.interrupted,
    };
  }

  LibraryResultStatistics get _statistics => LibraryResultStatistics(
    state: _state,
    loadedCount: _items.length,
    totalCount: _usesLocalScan && _scanStatus == LibraryLocalScanStatus.complete
        ? _items.length
        : _totalCount,
    scannedCount: _scanSnapshot?.scannedRawCount ?? _nextStartIndex,
    sourceTotalCount: _scanSnapshot?.sourceTotalCount,
    scanStatus: _scanStatus,
    dirty: _usesLocalScan ? _scanSnapshot?.dirty ?? false : _resultTotalDirty,
    unknownClassificationCount: _scanSnapshot?.unknownCount ?? 0,
  );

  bool get _usesPhotoCards =>
      _isMediaScope &&
      (_state.mediaType == LibraryMediaType.photo ||
          widget.profile.kind == LibraryContentProfileKind.photos);

  bool get _usesMixedCards =>
      _isMediaScope &&
      !_usesPhotoCards &&
      _state.mediaType == LibraryMediaType.all &&
      widget.profile.allowedMediaTypes.contains(LibraryMediaType.photo);

  LibraryGridGeometry _mediaGridGeometry(bool largeIPadLandscape) {
    if (_usesPhotoCards) {
      return largeIPadLandscape
          ? libraryIPadPhotoGridGeometry
          : libraryPhotoGridGeometry;
    }
    if (_usesMixedCards) {
      return largeIPadLandscape
          ? libraryIPadMixedGridGeometry
          : libraryMixedGridGeometry;
    }
    return largeIPadLandscape
        ? libraryIPadMediaGridGeometry
        : libraryMediaGridGeometry;
  }

  LibraryGridGeometry _gridGeometry(bool largeIPadLandscape) =>
      switch (_state.scope) {
        LibraryBrowseScope.directory =>
          largeIPadLandscape
              ? libraryIPadDirectoryGridGeometry
              : libraryDirectoryGridGeometry,
        LibraryBrowseScope.genres || LibraryBrowseScope.tags =>
          largeIPadLandscape
              ? libraryIPadFacetGridGeometry
              : libraryFacetGridGeometry,
        LibraryBrowseScope.media ||
        LibraryBrowseScope.favorites ||
        LibraryBrowseScope.facet => _mediaGridGeometry(largeIPadLandscape),
      };

  @override
  void initState() {
    super.initState();
    _state = reduceLibraryBrowseState(
      widget.initialState,
      _capabilitiesEvent(),
    );
    _positionController = LibraryScrollPositionController();
    _controller.addListener(_onScroll);
    widget.libraryScanService?.addListener(_onLibraryScanChanged);
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
    _startCurrentResultLoad();
  }

  @override
  void didUpdateWidget(covariant LibraryBrowseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.libraryScanService, widget.libraryScanService)) {
      oldWidget.libraryScanService?.removeListener(_onLibraryScanChanged);
      widget.libraryScanService?.addListener(_onLibraryScanChanged);
      final previousState = _state;
      _dispatch(_capabilitiesEvent());
      if (_state == previousState) {
        _activeScanKey = null;
        _scanSnapshot = null;
        _startCurrentResultLoad();
      }
      return;
    }
    if (!_isRoot || oldWidget.categorySettings == widget.categorySettings) {
      return;
    }
    final settings = widget.categorySettings;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isRoot || widget.categorySettings != settings) return;
      _dispatch(_capabilitiesEvent());
    });
  }

  LibraryCapabilitiesChanged _capabilitiesEvent() => LibraryCapabilitiesChanged(
    allowedScopes: _allowedScopesForPage,
    allowedMediaTypes: _visibleMediaTypes,
    supportsPlayedFilter: widget.profile.supportsPlayedFilter,
    supportsLocalSourceFilter:
        widget.profile.supportsLocalSourceFilter &&
        widget.libraryScanService != null,
  );

  @override
  void dispose() {
    _generation++;
    _reloadGeneration = null;
    _activeReload = null;
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    widget.libraryScanService?.removeListener(_onLibraryScanChanged);
    _positionController.dispose();
    unawaited(_realtimeRefresh.dispose());
    super.dispose();
  }

  void _onScroll() {
    if (_usesLocalScan || _isReloadingCurrentGeneration || _loadFailed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_controller.hasClients ||
          _usesLocalScan ||
          _isReloadingCurrentGeneration ||
          _loadFailed ||
          _controller.position.extentAfter >= 700) {
        return;
      }
      unawaited(_loadMore());
    });
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
    required LibraryGridGeometry geometry,
  }) {
    final generation = _positionGeneration;
    final statistics = _statistics;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _positionGeneration || !_positionEnabled) {
        return;
      }
      _positionController.updateLayout(
        constraints: constraints,
        loadedCount: _items.length,
        totalCount: statistics.effectiveTotal,
        geometry: geometry,
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

  Future<void> _loadMore({int? expectedGeneration}) {
    final generation = expectedGeneration ?? _generation;
    if (!mounted || generation != _generation || !_hasMore) {
      return Future.value();
    }
    final activeLoad = _activeLoad;
    if (_loading && _activeLoadGeneration == generation && activeLoad != null) {
      return activeLoad;
    }
    final load = _performLoadMore(generation);
    _activeLoad = load;
    _activeLoadGeneration = generation;
    return load;
  }

  Future<void> _performLoadMore(int generation) async {
    if (_usesLocalScan) return;
    final startIndex = _nextStartIndex;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final page = await _requestPage(startIndex);
      if (!mounted || generation != _generation) return;
      final cursor = advanceLibraryRawPageCursor(
        currentStartIndex: startIndex,
        currentTotalCount: _totalCount,
        reportedTotalCount: page.totalRecordCount,
        rawItemCount: page.rawItemCount,
        pageSize: _pageSize,
        dirty: _resultTotalDirty,
      );
      setState(() {
        _nextStartIndex = cursor.nextStartIndex;
        _totalCount = cursor.totalCount;
        _resultTotalDirty = cursor.dirty;
        for (final item in page.items) {
          if (!_seenItemIds.add(item.id)) continue;
          _items.add(item);
        }
        _hasMore = cursor.hasMore || cursor.paginationStalled;
        _loadFailed = cursor.paginationStalled;
        _loading = false;
      });
      _recordCursorDiagnostics(cursor);
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      DiagnosticLog.instance.error(
        'library',
        'Library page load failed scope=${_state.scope.name}',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _recordCursorDiagnostics(LibraryRawPageCursorUpdate cursor) {
    if (cursor.totalChanged) {
      DiagnosticLog.instance.warning(
        'library',
        'Library total changed scope=${_state.scope.name}; '
            'statistics require refresh',
      );
    }
    final total = cursor.totalCount;
    if (!_reportedTotalBelowLoaded && total != null && total < _items.length) {
      _reportedTotalBelowLoaded = true;
      DiagnosticLog.instance.warning(
        'library',
        'Library total below loaded count scope=${_state.scope.name} '
            'total=$total loaded=${_items.length}',
      );
    }
    if (cursor.paginationStalled) {
      DiagnosticLog.instance.warning(
        'library',
        'Library pagination stalled scope=${_state.scope.name}',
      );
    }
  }

  Future<void> _loadUntilDisplayCapacity({int? expectedGeneration}) async {
    final generation = expectedGeneration ?? _generation;
    do {
      final previousCursor = _nextStartIndex;
      await _loadMore(expectedGeneration: generation);
      if (!mounted || generation != _generation || _loadFailed) return;
      if (_nextStartIndex <= previousCursor) return;
    } while (_hasMore && _items.isEmpty);
  }

  Future<EmbyItemPage> _requestMediaPage(
    LibraryBrowseState state,
    int startIndex, [
    int limit = _pageSize,
  ]) => _loadLibraryMediaPage(
    api: widget.api,
    parentId: widget.view.id,
    profile: widget.profile,
    state: state,
    startIndex: startIndex,
    limit: limit,
  );

  Future<EmbyItemPage> _requestPage(int startIndex) => switch (_state.scope) {
    LibraryBrowseScope.media ||
    LibraryBrowseScope.favorites ||
    LibraryBrowseScope.facet => _requestMediaPage(_state, startIndex),
    LibraryBrowseScope.directory => widget.api.getDirectoryChildren(
      parentId: widget.view.id,
      startIndex: startIndex,
      limit: _pageSize,
      sortBy: _state.sortBy,
      sortOrder: _state.sortOrder,
    ),
    LibraryBrowseScope.genres => widget.api.getLibraryGenres(
      parentId: widget.view.id,
      profile: widget.profile,
      startIndex: startIndex,
      limit: _pageSize,
    ),
    LibraryBrowseScope.tags => widget.api.getLibraryTags(
      parentId: widget.view.id,
      profile: widget.profile,
      startIndex: startIndex,
      limit: _pageSize,
    ),
  };

  Future<void> _refresh() {
    if (_usesLocalScan) return _restartLocalScan();
    return _restartQuery(
      targetStartIndex: _pageSize,
      restoreScrollPosition: false,
    );
  }

  Future<void> _refreshPreservingPosition() {
    if (_usesLocalScan) return _restartLocalScan();
    return _restartQuery(
      targetStartIndex: _nextStartIndex > _pageSize
          ? _nextStartIndex
          : _pageSize,
      restoreScrollPosition: true,
    );
  }

  LibraryScanKey _scanKeyForState(LibraryBrowseState state) =>
      LibraryScanKey.fromBrowseState(
        scopeNamespace: widget.libraryScanService!.scope.cacheNamespace,
        libraryId: widget.view.id,
        state: state,
      );

  LibraryLocalMediaScanRequest _scanRequestForState(LibraryBrowseState state) {
    final key = _scanKeyForState(state);
    final api = widget.api;
    final parentId = widget.view.id;
    final profile = widget.profile;
    return LibraryLocalMediaScanRequest(
      key: key,
      loadPage: ({required startIndex, required limit}) =>
          _loadLibraryMediaPage(
            api: api,
            parentId: parentId,
            profile: profile,
            state: state,
            startIndex: startIndex,
            limit: limit,
          ),
    );
  }

  void _startCurrentResultLoad() {
    if (_usesLocalScan) {
      _subscribeToLocalScan();
    } else {
      _activeScanKey = null;
      _scanSnapshot = null;
      unawaited(_loadUntilDisplayCapacity());
    }
  }

  void _subscribeToLocalScan({bool restart = false}) {
    final service = widget.libraryScanService;
    if (service == null) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return;
    }
    final request = _scanRequestForState(_state);
    _activeScanKey = request.key;
    try {
      final snapshot = restart
          ? service.restartScan(request)
          : service.ensureScan(request);
      _applyLocalScanSnapshot(snapshot);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'library-scan',
        'Local media scan subscription failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _restartLocalScan() async {
    if (!mounted) return;
    _clearPosition(scrollToTop: true);
    setState(() {
      _items.clear();
      _seenItemIds.clear();
      _nextStartIndex = 0;
      _totalCount = null;
      _resultTotalDirty = false;
      _reportedTotalBelowLoaded = false;
      _hasMore = false;
      _loadFailed = false;
      _loading = true;
      _scanSnapshot = null;
    });
    _subscribeToLocalScan(restart: true);
  }

  void _onLibraryScanChanged() {
    if (!mounted || !_usesLocalScan) return;
    final key = _activeScanKey;
    if (key == null) return;
    final snapshot = widget.libraryScanService?.snapshotFor(key);
    if (snapshot != null) _applyLocalScanSnapshot(snapshot);
  }

  void _applyLocalScanSnapshot(LibraryLocalScanSnapshot snapshot) {
    if (!mounted || !_usesLocalScan) return;
    final service = widget.libraryScanService;
    final key = _activeScanKey;
    if (service == null || key == null) return;
    final items = service.itemsFor(key, _state.localFilter);
    setState(() {
      _scanSnapshot = snapshot;
      _items
        ..clear()
        ..addAll(items);
      _seenItemIds
        ..clear()
        ..addAll(items.map((item) => item.id));
      _nextStartIndex = snapshot.rawCursor;
      _totalCount = null;
      _resultTotalDirty = snapshot.dirty;
      _reportedTotalBelowLoaded = false;
      _hasMore = false;
      _loading = switch (snapshot.status) {
        LibraryScanStatus.queued || LibraryScanStatus.scanning => true,
        LibraryScanStatus.paused ||
        LibraryScanStatus.complete ||
        LibraryScanStatus.cancelled => false,
      };
      _loadFailed = snapshot.safeError != null;
    });
  }

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
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'library',
        'Realtime library refresh failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _refreshUserData(Iterable<String> itemIds) async {
    final generation = _generation;
    final state = _state;
    final requestedIds = itemIds.where((id) => id.isNotEmpty).toSet();
    if (requestedIds.isEmpty) return;
    final loadedItems = {for (final item in _items) item.id: item};
    final hasUnknownId = requestedIds.any((id) => !loadedItems.containsKey(id));
    if (hasUnknownId && libraryBrowseHasServerMembershipCondition(state)) {
      await _refreshPreservingPosition();
      return;
    }
    final loadedRequestedIds = requestedIds
        .where(loadedItems.containsKey)
        .toSet();
    if (loadedRequestedIds.isEmpty) return;
    final userData = await widget.api.getUserDataForItems(loadedRequestedIds);
    if (!mounted || generation != _generation || userData.isEmpty) return;
    final membershipChanged = userData.entries.any((entry) {
      final item = loadedItems[entry.key];
      return item != null &&
          libraryItemMatchesServerMembership(state, item.userData) !=
              libraryItemMatchesServerMembership(state, entry.value);
    });
    if (membershipChanged) {
      await _refreshPreservingPosition();
      return;
    }
    final scanKey = _activeScanKey;
    if (_usesLocalScan && scanKey != null) {
      widget.libraryScanService?.updateUserData(scanKey, userData);
      return;
    }
    setState(() {
      for (var index = 0; index < _items.length; index++) {
        final item = _items[index];
        final updated = userData[item.id];
        if (updated == null) continue;
        _items[index] = item.copyWith(userData: updated);
      }
    });
  }

  Future<void> _restartQuery({
    required int targetStartIndex,
    required bool restoreScrollPosition,
  }) {
    if (!mounted) return Future.value();
    if (_isReloadingCurrentGeneration) {
      return _activeReload ?? Future.value();
    }
    final failureSnapshot = restoreScrollPosition
        ? _LibraryQuerySnapshot(
            items: List<EmbyItem>.of(_items),
            seenItemIds: Set<String>.of(_seenItemIds),
            nextStartIndex: _nextStartIndex,
            totalCount: _totalCount,
            totalDirty: _resultTotalDirty,
            reportedTotalBelowLoaded: _reportedTotalBelowLoaded,
            hasMore: _hasMore,
            loadFailed: _loadFailed,
          )
        : null;
    final previousOffset = restoreScrollPosition && _controller.hasClients
        ? _controller.offset
        : null;
    final generation = ++_generation;
    _reloadGeneration = generation;
    late final Future<void> trackedReload;
    trackedReload =
        _runRestartQuery(
          generation: generation,
          targetStartIndex: targetStartIndex,
          restoreScrollPosition: restoreScrollPosition,
          previousOffset: previousOffset,
          failureSnapshot: failureSnapshot,
        ).whenComplete(() {
          if (_reloadGeneration == generation) _reloadGeneration = null;
          if (identical(_activeReload, trackedReload)) _activeReload = null;
        });
    _activeReload = trackedReload;
    return trackedReload;
  }

  Future<void> _runRestartQuery({
    required int generation,
    required int targetStartIndex,
    required bool restoreScrollPosition,
    required double? previousOffset,
    required _LibraryQuerySnapshot? failureSnapshot,
  }) async {
    if (!mounted || generation != _generation) return;
    setState(() {
      _items.clear();
      _seenItemIds.clear();
      _nextStartIndex = 0;
      _totalCount = null;
      _resultTotalDirty = false;
      _reportedTotalBelowLoaded = false;
      _hasMore = true;
      _loading = false;
      _loadFailed = false;
    });
    _clearPosition(scrollToTop: !restoreScrollPosition);
    while (mounted &&
        generation == _generation &&
        _nextStartIndex < targetStartIndex &&
        _hasMore &&
        !_loadFailed) {
      final previousCursor = _nextStartIndex;
      await _loadMore(expectedGeneration: generation);
      if (_nextStartIndex <= previousCursor) break;
    }
    if (mounted &&
        generation == _generation &&
        _state.localFilter != LibraryLocalMediaFilter.all &&
        _items.isEmpty &&
        _hasMore &&
        !_loadFailed) {
      await _loadUntilDisplayCapacity(expectedGeneration: generation);
    }
    var restoredAfterFailure = false;
    if (failureSnapshot != null &&
        mounted &&
        generation == _generation &&
        _loadFailed) {
      setState(() {
        _items
          ..clear()
          ..addAll(failureSnapshot.items);
        _seenItemIds
          ..clear()
          ..addAll(failureSnapshot.seenItemIds);
        _nextStartIndex = failureSnapshot.nextStartIndex;
        _totalCount = failureSnapshot.totalCount;
        _resultTotalDirty = failureSnapshot.totalDirty;
        _reportedTotalBelowLoaded = failureSnapshot.reportedTotalBelowLoaded;
        _hasMore = failureSnapshot.hasMore;
        _loading = false;
        _loadFailed = failureSnapshot.loadFailed;
      });
      restoredAfterFailure = true;
    }
    if (previousOffset != null && mounted && generation == _generation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation || !_controller.hasClients) {
          return;
        }
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
    if (restoredAfterFailure && mounted && generation == _generation) {
      _showUserDataRefreshFailure();
    }
  }

  void _dispatch(LibraryBrowseEvent event) {
    final next = reduceLibraryBrowseState(_state, event);
    if (identical(next, _state) || next == _state) return;
    _generation++;
    _reloadGeneration = null;
    _activeReload = null;
    setState(() {
      _state = next;
      _items.clear();
      _seenItemIds.clear();
      _nextStartIndex = 0;
      _totalCount = null;
      _resultTotalDirty = false;
      _reportedTotalBelowLoaded = false;
      _hasMore = true;
      _loading = false;
      _loadFailed = false;
      _activeScanKey = null;
      _scanSnapshot = null;
    });
    _clearPosition(scrollToTop: true);
    _startCurrentResultLoad();
  }

  Future<void> _showFilters() async {
    final selected = await showModalBottomSheet<LibraryFilterDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LibraryFilterSheet(
        initialDraft: LibraryFilterDraft.fromState(_state),
        mediaTypes: _filterMediaTypes,
        supportsLocalSource: widget.profile.supportsLocalSourceFilter,
        supportsPlayed: widget.profile.supportsPlayedFilter,
      ),
    );
    if (selected != null && mounted) _dispatch(LibraryFiltersApplied(selected));
  }

  void _retryLoad() {
    if (_usesLocalScan) {
      final key = _activeScanKey;
      if (key != null) unawaited(widget.libraryScanService?.retry(key));
      return;
    }
    if (_loadFailed) setState(() => _loadFailed = false);
    unawaited(_loadUntilDisplayCapacity());
  }

  Future<void> _playAll({bool shuffle = false}) async {
    if (!_canPlayCompleteResult) return;
    setState(() => _preparingPlaybackQueue = true);
    final state = _state;
    late final PlaybackQueue queue;
    try {
      if (_usesLocalScan) {
        final items = _playableItems.toList(growable: false);
        if (shuffle) items.shuffle();
        if (items.isEmpty) return;
        queue = PlaybackQueue(api: widget.api, initialItems: items);
      } else {
        final initialItems = List<EmbyItem>.of(_items);
        final initialRawCursor = _nextStartIndex;
        final initialTotalCount = _totalCount;
        final query = LibraryPlaybackQuerySnapshot(
          libraryId: widget.view.id,
          state: state,
          profile: widget.profile,
          fingerprint:
              'library:${Object.hash(widget.view.id, state, widget.profile.kind).toUnsigned(32)}',
        );
        final result = await showDialog<_LibraryPlaybackPreparationResult>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _LibraryPlaybackPreparationDialog(
            prepare: (cancellation, onProgress) =>
                LazyLibraryPlaybackQueue.prepare(
                  api: widget.api,
                  query: query,
                  initialItems: initialItems,
                  initialRawCursor: initialRawCursor,
                  totalCount: initialTotalCount,
                  loadPage: ({required startIndex, required limit}) =>
                      _requestMediaPage(state, startIndex, limit),
                  shuffle: shuffle,
                  pageSize: _pageSize,
                  cancellation: cancellation,
                  onProgress: onProgress,
                ),
            onFailure: (error, stackTrace) => DiagnosticLog.instance.error(
              'library',
              'Library playback queue preparation failed',
              error: error,
              stackTrace: stackTrace,
            ),
          ),
        );
        if (!mounted ||
            result == null ||
            result.status == _LibraryPlaybackPreparationStatus.cancelled) {
          return;
        }
        if (result.status == _LibraryPlaybackPreparationStatus.failed) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('播放队列准备失败，请稍后重试')));
          return;
        }
        final preparedQueue = result.queue;
        if (result.status == _LibraryPlaybackPreparationStatus.empty ||
            preparedQueue == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前筛选结果没有可播放项目')));
          return;
        }
        queue = preparedQueue;
      }
    } finally {
      if (mounted) setState(() => _preparingPlaybackQueue = false);
    }
    if (!mounted || queue.items.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          api: widget.api,
          item: queue.items.first,
          queue: queue,
        ),
      ),
    );
    if (!mounted) return;
    try {
      await _refreshUserData(queue.items.map((item) => item.id));
    } catch (error, stackTrace) {
      _reportUserDataRefreshFailure(error, stackTrace);
    }
  }

  void _selectMore(_LibraryMoreAction action) {
    switch (action) {
      case _LibraryMoreAction.refresh:
        unawaited(_refresh());
      case _LibraryMoreAction.reset:
        if (_isRoot) _dispatch(const LibraryBrowseReset());
      case _LibraryMoreAction.clearScan:
        final key = _activeScanKey;
        if (key == null) return;
        widget.libraryScanService?.clearScan(key);
        if (_usesLocalScan) unawaited(_restartLocalScan());
    }
  }

  PhotoSequenceSource _photoSequenceSource(EmbyItem initialItem) {
    final state = _state;
    final api = widget.api;
    final viewId = widget.view.id;
    final profile = widget.profile;
    Future<EmbyItemPage> loadPage({
      required int startIndex,
      required int limit,
    }) => switch (state.scope) {
      LibraryBrowseScope.directory => api.getDirectoryChildren(
        parentId: viewId,
        startIndex: startIndex,
        limit: limit,
        sortBy: state.sortBy,
        sortOrder: state.sortOrder,
      ),
      LibraryBrowseScope.media ||
      LibraryBrowseScope.favorites ||
      LibraryBrowseScope.facet => api.getLibraryMediaItems(
        parentId: viewId,
        profile: profile,
        startIndex: startIndex,
        limit: limit,
        mediaType: state.mediaType,
        playedFilter: state.playedFilter,
        favorites: state.scope == LibraryBrowseScope.favorites,
        sortBy: state.sortBy,
        sortOrder: state.sortOrder,
        alphabetFilter: state.alphabetFilter,
        genreId: state.facet?.kind == LibraryFacetKind.genre
            ? state.facet!.id
            : null,
        tagId: state.facet?.kind == LibraryFacetKind.tag
            ? state.facet!.id
            : null,
      ),
      LibraryBrowseScope.genres || LibraryBrowseScope.tags => Future.value(
        const EmbyItemPage(items: [], totalRecordCount: 0),
      ),
    };

    final fingerprint =
        'library:${Object.hash(viewId, state, profile.kind).toUnsigned(32)}';
    final initialItems = List<EmbyItem>.of(_items);
    return state.scope == LibraryBrowseScope.directory
        ? DirectoryPhotoSource(
            queryFingerprint: fingerprint,
            initialItems: initialItems,
            initialItemId: initialItem.id,
            initialRawCursor: _nextStartIndex,
            initialTotalCount: _totalCount,
            initialHasMore: _hasMore,
            loadPage: loadPage,
          )
        : FilteredLibraryPhotoSource(
            queryFingerprint: fingerprint,
            initialItems: initialItems,
            initialItemId: initialItem.id,
            initialRawCursor: _nextStartIndex,
            initialTotalCount: _totalCount,
            initialHasMore: _hasMore,
            loadPage: loadPage,
          );
  }

  Future<void> _open(EmbyItem item) async {
    switch (resolveLibraryEntryAction(widget.profile, _state.scope, item)) {
      case LibraryEntryAction.openDirectory:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LibraryBrowseScreen.directory(
              api: widget.api,
              view: item,
              downloads: widget.downloads,
              categorySettings: widget.categorySettings,
              libraryScanService: widget.libraryScanService,
              navigationActions: widget.navigationActions,
              platformCapabilities: widget.platformCapabilities,
              profile: widget.profile,
              initialState: _state.scope == LibraryBrowseScope.directory
                  ? LibraryBrowseState.directory(
                      sortBy: _state.sortBy,
                      sortOrder: _state.sortOrder,
                    )
                  : const LibraryBrowseState.directory(),
            ),
          ),
        );
      case LibraryEntryAction.openFacet:
        final kind = _state.scope == LibraryBrowseScope.genres
            ? LibraryFacetKind.genre
            : LibraryFacetKind.tag;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LibraryBrowseScreen.facet(
              api: widget.api,
              view: widget.view,
              downloads: widget.downloads,
              categorySettings: widget.categorySettings,
              libraryScanService: widget.libraryScanService,
              navigationActions: widget.navigationActions,
              platformCapabilities: widget.platformCapabilities,
              profile: widget.profile,
              facet: LibraryFacet(id: item.id, name: item.name, kind: kind),
            ),
          ),
        );
      case LibraryEntryAction.openDetail:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ItemDetailScreen(
              api: widget.api,
              initialItem: item,
              downloads: widget.downloads,
              navigationActions: widget.navigationActions,
              platformCapabilities: widget.platformCapabilities,
            ),
          ),
        );
        if (!mounted) return;
        try {
          await _refreshUserData([item.id]);
        } catch (error, stackTrace) {
          _reportUserDataRefreshFailure(error, stackTrace);
        }
      case LibraryEntryAction.openPhoto:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PhotoViewerScreen(
              api: widget.api,
              source: _photoSequenceSource(item),
            ),
          ),
        );
      case LibraryEntryAction.unsupported:
        DiagnosticLog.instance.warning(
          'library',
          'Unsupported library entry type=${item.type}',
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂不支持打开这个项目')));
        }
    }
  }

  void _reportUserDataRefreshFailure(Object error, StackTrace stackTrace) {
    DiagnosticLog.instance.error(
      'library',
      'Library item user data refresh failed',
      error: error,
      stackTrace: stackTrace,
    );
    _showUserDataRefreshFailure();
  }

  void _showUserDataRefreshFailure() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('状态刷新失败，可稍后重试')));
  }

  Widget _buildGrid(LibraryGridGeometry geometry) {
    final grid = SliverGrid(
      gridDelegate: geometry,
      delegate: SliverChildBuilderDelegate((context, index) {
        final item = _items[index];
        return switch (_state.scope) {
          LibraryBrowseScope.directory => LibraryDirectoryEntryCard(
            key: ValueKey('library-group-${item.id}'),
            item: item,
            imageRequest: widget.api.imageRequest(item, maxWidth: 600),
            onTap: () => _open(item),
          ),
          LibraryBrowseScope.genres ||
          LibraryBrowseScope.tags => _LibraryFacetCard(
            key: ValueKey('library-group-${item.id}'),
            item: item,
            icon: _state.scope.icon,
            imageRequest: widget.api.imageRequest(item, maxWidth: 500),
            onTap: () => _open(item),
          ),
          LibraryBrowseScope.media ||
          LibraryBrowseScope.favorites ||
          LibraryBrowseScope.facet => _buildMediaEntryCard(item),
        };
      }, childCount: _items.length),
    );
    return SliverPadding(
      padding: geometry.padding,
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          _schedulePositionUpdate(constraints: constraints, geometry: geometry);
          return grid;
        },
      ),
    );
  }

  Widget _buildMediaEntryCard(EmbyItem item) {
    final key = ValueKey('library-item-${item.id}');
    if (_usesPhotoCards && item.isPhoto) {
      return LibraryPhotoCard(
        key: key,
        item: item,
        imageRequest: widget.api.imageRequest(item, maxWidth: 600),
        onTap: () => _open(item),
      );
    }
    if (_usesPhotoCards || _usesMixedCards) {
      return LibraryMixedEntryCard(
        key: key,
        item: item,
        imageRequest: widget.api.imageRequest(item, maxWidth: 600),
        onTap: () => _open(item),
      );
    }
    return MediaPosterCard(
      key: key,
      item: item,
      width: double.infinity,
      imageRequest: widget.api.imageRequest(item),
      onTap: () => _open(item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final largeIPadLandscape = _isLargeIPadLandscape(context);
    final geometry = _gridGeometry(largeIPadLandscape);
    final title = _state.facet?.name ?? widget.view.name;
    final navigationActions = widget.navigationActions;
    return Scaffold(
      appBar: largeIPadLandscape && navigationActions != null
          ? LargeScreenPageChrome(
              title: title,
              navigationActions: navigationActions,
            )
          : AppBar(title: Text(title)),
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
                  if (_isRoot)
                    SliverToBoxAdapter(
                      child: _LibraryScopeBar(
                        selected: _state.scope,
                        scopes: _visibleScopes,
                        onSelected: (scope) =>
                            _dispatch(LibraryScopeSelected(scope)),
                      ),
                    ),
                  if (_state.scope.supportsSorting || _isMediaScope)
                    SliverToBoxAdapter(
                      child: _LibraryBrowseToolbar(
                        primaryResultLabel: _countLabel,
                        scanProgressLabel: _statistics.scanProgressLabel,
                        sortBy: _state.sortBy,
                        sortOrder: _state.sortOrder,
                        showPlaybackActions:
                            _isMediaScope && widget.profile.supportsPlayAll,
                        canPlay: _canPlayCompleteResult,
                        showFilter: _showFilter,
                        filterSummary: _filterSummary,
                        canReset: _isRoot,
                        canClearScan: _activeScanKey != null,
                        largeLayout: largeIPadLandscape,
                        videoOnly:
                            _state.mediaType == LibraryMediaType.all &&
                            widget.profile.allowedMediaTypes.contains(
                              LibraryMediaType.photo,
                            ),
                        onPlayAll: () => unawaited(_playAll()),
                        onShuffle: () => unawaited(_playAll(shuffle: true)),
                        onSortSelected: (sortBy) => _dispatch(
                          LibrarySortChanged(
                            sortBy: sortBy,
                            sortOrder: _state.sortOrder,
                          ),
                        ),
                        onToggleSortOrder: () => _dispatch(
                          LibrarySortChanged(
                            sortBy: _state.sortBy,
                            sortOrder:
                                _state.sortOrder == LibrarySortOrder.ascending
                                ? LibrarySortOrder.descending
                                : LibrarySortOrder.ascending,
                          ),
                        ),
                        onShowFilter: _showFilters,
                        onMoreSelected: _selectMore,
                      ),
                    )
                  else
                    SliverToBoxAdapter(child: _buildSectionSummary(context)),
                  if (_alphabetEnabled && !_state.alphabetFilter.isAll)
                    SliverToBoxAdapter(
                      child: LibraryAlphabetFilterChip(
                        filter: _state.alphabetFilter,
                        onClear: () => _dispatch(
                          const LibraryAlphabetFilterSelected(AllItems()),
                        ),
                      ),
                    ),
                  if (_items.isEmpty && _loading)
                    const SliverFillRemaining(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_items.isEmpty && _loadFailed)
                    SliverFillRemaining(
                      child: _FixedLibraryErrorState(onRetry: _retryLoad),
                    )
                  else if (_items.isEmpty)
                    SliverFillRemaining(
                      child: EmptyState(icon: _emptyIcon, title: _emptyTitle),
                    )
                  else
                    _buildGrid(geometry),
                  if (_items.isNotEmpty && (_loading || _loadFailed))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: _loadFailed
                            ? Center(
                                child: TextButton.icon(
                                  key: const ValueKey('library-scan-retry'),
                                  onPressed: _retryLoad,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('统计中断，重试'),
                                ),
                              )
                            : const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
            ),
          ),
          LibraryPositionOverlay(
            controller: _positionController,
            statistics: _statistics,
          ),
          if (_alphabetEnabled)
            LibraryAlphabetNavigation(
              selected: _state.alphabetFilter,
              onSelected: (filter) =>
                  _dispatch(LibraryAlphabetFilterSelected(filter)),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionSummary(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
    child: Text(
      _countLabel,
      key: const ValueKey('library-section-total'),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  String get _countLabel => _statistics.primaryResultLabel;

  IconData get _emptyIcon => _state.localFilter != LibraryLocalMediaFilter.all
      ? _state.localFilter.emptyIcon
      : _state.scope.icon;

  String get _emptyTitle {
    if (_state.localFilter != LibraryLocalMediaFilter.all) {
      return _state.localFilter.emptyTitle;
    }
    if (_isMediaScope &&
        (_state.activeFilterCount > 0 ||
            _state.mediaType != LibraryMediaType.all)) {
      return '没有符合筛选条件的项目';
    }
    return _state.scope.emptyTitle;
  }
}

String _sortLabel(LibrarySortBy sortBy) => switch (sortBy) {
  LibrarySortBy.name => '名称',
  LibrarySortBy.dateAdded => '加入日期',
  LibrarySortBy.premiereDate => '首映日期',
  LibrarySortBy.productionYear => '年份',
  LibrarySortBy.communityRating => '评分',
  LibrarySortBy.runtime => '时长',
};

class _FixedLibraryErrorState extends StatelessWidget {
  const _FixedLibraryErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('library-load-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44),
            const SizedBox(height: 12),
            const Text('加载失败，请重试'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
