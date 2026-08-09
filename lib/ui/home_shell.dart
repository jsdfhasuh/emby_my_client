import 'package:flutter/material.dart';

import '../images/emby_image_cache.dart';
import '../state/app_controller.dart';
import 'diagnostic_log_screen.dart';
import 'downloads/downloads_screen.dart';
import 'home_screen.dart';
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

  Future<void> _handleAccountAction(String value) async {
    if (value == 'logout') {
      await widget.controller.signOut();
      return;
    }
    if (value == 'logs') {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const DiagnosticLogScreen()));
      return;
    }
    if (value == 'settings') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SettingsScreen(
            settings: widget.controller.libraryCategorySettings,
            accountName: widget.controller.session!.username,
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
        libraryScanService: widget.controller.libraryScanService,
      ),
      LibraryScreen(
        api: api,
        downloads: downloads,
        categorySettings: widget.controller.libraryCategorySettings,
        libraryScanService: widget.controller.libraryScanService,
      ),
      SearchScreen(
        api: api,
        downloads: downloads,
        categorySettings: widget.controller.libraryCategorySettings,
        libraryScanService: widget.controller.libraryScanService,
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
