import 'package:flutter/material.dart';

import '../core/diagnostic_log.dart';
import '../images/emby_image_cache.dart';
import '../library/library_genre_resolver.dart';
import '../library/library_navigation_context.dart';
import '../library/library_root_resolver.dart';
import '../models/emby_models.dart';
import '../platform/platform_capabilities.dart';
import '../state/app_controller.dart';
import 'diagnostic_log_screen.dart';
import 'downloads/downloads_screen.dart';
import 'home_screen.dart';
import 'home_shell_navigation.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final Set<String> _openingGenreRequests = {};

  late final LibraryRootResolver _libraryRootResolver = LibraryRootResolver(
    api: widget.controller.api,
  );
  late final LibraryGenreResolver _libraryGenreResolver = LibraryGenreResolver(
    api: widget.controller.api,
  );

  late final HomeShellNavigationActions _navigationActions =
      HomeShellNavigationActions(
        showHome: () => _showShellTab(0),
        showSearch: () => _showShellTab(2),
        openSettings: _openSettingsFromRoute,
        openAccount: _openAccountFromRoute,
        openGenre: _openGenre,
      );

  Future<void> _openGenre(
    BuildContext sourceContext,
    EmbyItem item,
    String genreName,
    LibraryBrowseOrigin? knownOrigin,
    PlatformCapabilities? platformCapabilities,
  ) async {
    final normalizedName = normalizeLibraryGenreName(genreName);
    final requestKey =
        '${item.id}\u0000${knownOrigin?.rootView.id ?? 'unknown'}\u0000$normalizedName';
    if (normalizedName.isEmpty || !_openingGenreRequests.add(requestKey)) {
      return;
    }

    try {
      final origin = await _libraryRootResolver.resolve(
        item: item,
        knownOrigin: knownOrigin,
      );
      final facet = await _libraryGenreResolver.resolve(
        origin: origin,
        genreName: genreName,
      );
      if (!sourceContext.mounted) return;
      await Navigator.of(sourceContext).push(
        MaterialPageRoute(
          builder: (_) => LibraryBrowseScreen.facet(
            api: widget.controller.api,
            view: origin.rootView,
            facet: facet,
            downloads: widget.controller.downloads,
            categorySettings: widget.controller.libraryCategorySettings,
            libraryScanService: widget.controller.libraryScanService,
            navigationActions: _navigationActions,
            platformCapabilities: platformCapabilities,
            profile: origin.profile,
            libraryRoot: origin.rootView,
          ),
        ),
      );
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'library',
        'Media detail genre navigation failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!sourceContext.mounted) return;
      ScaffoldMessenger.of(sourceContext).showSnackBar(
        SnackBar(content: Text(genreNavigationErrorMessage(error))),
      );
    } finally {
      _openingGenreRequests.remove(requestKey);
    }
  }

  void _showShellTab(int index) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (mounted && _index != index) setState(() => _index = index);
  }

  Future<void> _openSettingsFromRoute() async {
    Navigator.of(context).popUntil((route) => route.isFirst);
    await Future<void>.delayed(Duration.zero);
    if (mounted) await _handleAccountAction('settings');
  }

  Future<void> _openAccountFromRoute() async {
    Navigator.of(context).popUntil((route) => route.isFirst);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(widget.controller.session!.username),
              subtitle: Text(widget.controller.session!.serverName),
            ),
            const Divider(height: 1),
            for (final item in const [
              ('settings', Icons.settings_outlined, '设置'),
              ('logs', Icons.description_outlined, '诊断日志'),
              ('clear-image-cache', Icons.delete_sweep_outlined, '清理图片缓存'),
              ('logout', Icons.logout, '退出登录'),
            ])
              ListTile(
                leading: Icon(item.$2),
                title: Text(item.$3),
                onTap: () => Navigator.of(sheetContext).pop(item.$1),
              ),
          ],
        ),
      ),
    );
    if (action != null && mounted) await _handleAccountAction(action);
  }

  Future<void> _handleAccountAction(String value) async {
    if (value == 'logout') {
      await widget.controller.signOut();
      return;
    }
    if (value == 'logs') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DiagnosticLogScreen(
            playbackTestOverrides:
                widget.controller.playbackDiagnosticsTestOverrides,
          ),
        ),
      );
      return;
    }
    if (value == 'settings') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SettingsScreen(
            settings: widget.controller.libraryCategorySettings,
            accountName: widget.controller.session!.username,
            session: widget.controller.session!,
            playbackSettingsRepository:
                widget.controller.playbackSettingsRepository,
            playbackCacheStorage: widget.controller.playbackCacheStorage,
            onLibraryCategorySettingsChanged:
                widget.controller.updateLibraryCategorySettings,
            onDeleteAccountData: widget.controller.deleteCurrentAccountData,
          ),
        ),
      );
      return;
    }
    if (value != 'clear-image-cache') return;
    try {
      final usage = await embyImageCacheManager.inspectUsage();
      await embyImageCacheManager.clearAll();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (!mounted) return;
      final megabytes = usage.bytes / (1024 * 1024);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清理图片缓存（${megabytes.toStringAsFixed(1)} MB）')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('图片缓存清理失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.controller.api;
    final downloads = widget.controller.downloads;
    final pages = [
      HomeScreen(
        api: api,
        downloads: downloads,
        categorySettings: widget.controller.libraryCategorySettings,
        sortPreferenceStore: widget.controller.librarySortPreferenceStore,
        libraryScanService: widget.controller.libraryScanService,
        navigationActions: _navigationActions,
      ),
      LibraryScreen(
        api: api,
        downloads: downloads,
        categorySettings: widget.controller.libraryCategorySettings,
        sortPreferenceStore: widget.controller.librarySortPreferenceStore,
        libraryScanService: widget.controller.libraryScanService,
        navigationActions: _navigationActions,
      ),
      SearchScreen(
        api: api,
        downloads: downloads,
        categorySettings: widget.controller.libraryCategorySettings,
        libraryScanService: widget.controller.libraryScanService,
        navigationActions: _navigationActions,
      ),
    ];
    const titles = ['首页', '媒体库', '搜索'];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.black,
                size: 23,
              ),
            ),
            const SizedBox(width: 11),
            Text(
              titles[_index],
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          if (downloads != null)
            IconButton(
              tooltip: '离线下载',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DownloadsScreen(api: api, downloads: downloads),
                ),
              ),
              icon: const Icon(Icons.download_outlined),
            ),
          PopupMenuButton<String>(
            tooltip: '账号',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: _handleAccountAction,
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.controller.session!.username,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      widget.controller.session!.serverName,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9DA6A9),
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings_outlined),
                  title: Text('设置'),
                ),
              ),
              const PopupMenuItem(
                value: 'logs',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.description_outlined),
                  title: Text('诊断日志'),
                ),
              ),
              const PopupMenuItem(
                value: 'clear-image-cache',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_sweep_outlined),
                  title: Text('清理图片缓存'),
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout),
                  title: Text('退出登录'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: '媒体库',
          ),
          NavigationDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.manage_search),
            label: '搜索',
          ),
        ],
      ),
    );
  }
}

String genreNavigationErrorMessage(Object error) {
  if (error is LibraryRootResolutionException) {
    return switch (error.failure) {
      LibraryRootResolutionFailure.requestFailed => '分类加载失败，请重试',
      LibraryRootResolutionFailure.rootUnavailable ||
      LibraryRootResolutionFailure.ancestorLoop ||
      LibraryRootResolutionFailure.ancestorDepthExceeded => '无法确定该媒体所属的媒体库',
    };
  }
  if (error is LibraryGenreResolutionException) {
    return switch (error.failure) {
      LibraryGenreResolutionFailure.requestFailed ||
      LibraryGenreResolutionFailure.paginationStalled => '分类加载失败，请重试',
      LibraryGenreResolutionFailure.notFound ||
      LibraryGenreResolutionFailure.ambiguous ||
      LibraryGenreResolutionFailure.unsupportedProfile => '当前媒体库没有找到该分类',
    };
  }
  return '分类加载失败，请重试';
}
