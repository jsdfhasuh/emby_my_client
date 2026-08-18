import 'dart:async';

import 'package:flutter/material.dart';

import '../library/library_navigation_context.dart';
import '../models/emby_models.dart';
import '../platform/platform_capabilities.dart';

@immutable
class HomeShellNavigationActions {
  const HomeShellNavigationActions({
    required this.showHome,
    required this.showSearch,
    required this.openSettings,
    required this.openAccount,
    this.openGenre,
  });

  final VoidCallback showHome;
  final VoidCallback showSearch;
  final Future<void> Function() openSettings;
  final Future<void> Function() openAccount;
  final Future<void> Function(
    BuildContext sourceContext,
    EmbyItem item,
    String genreName,
    LibraryBrowseOrigin? knownOrigin,
    PlatformCapabilities? platformCapabilities,
  )?
  openGenre;
}

class LargeScreenPageChrome extends StatelessWidget
    implements PreferredSizeWidget {
  const LargeScreenPageChrome({
    super.key,
    required this.title,
    required this.navigationActions,
  });

  final String title;
  final HomeShellNavigationActions navigationActions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          key: const ValueKey('large-screen-home'),
          tooltip: '首页',
          onPressed: navigationActions.showHome,
          icon: const Icon(Icons.home_outlined),
        ),
        IconButton(
          key: const ValueKey('large-screen-search'),
          tooltip: '搜索',
          onPressed: navigationActions.showSearch,
          icon: const Icon(Icons.search),
        ),
        IconButton(
          key: const ValueKey('large-screen-settings'),
          tooltip: '设置',
          onPressed: () => unawaited(navigationActions.openSettings()),
          icon: const Icon(Icons.settings_outlined),
        ),
        IconButton(
          key: const ValueKey('large-screen-account'),
          tooltip: '账号',
          onPressed: () => unawaited(navigationActions.openAccount()),
          icon: const Icon(Icons.account_circle_outlined),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
