import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/emby_api.dart';
import '../../models/emby_models.dart';
import '../../photos/photo_browser_controller.dart';
import '../../realtime/realtime_refresh_binding.dart';
import '../widgets/media_widgets.dart';
import 'photo_viewer_screen.dart';

class PhotoLibraryScreen extends StatefulWidget {
  const PhotoLibraryScreen({
    super.key,
    required this.api,
    required this.directory,
  });

  final EmbyApi api;
  final EmbyItem directory;

  @override
  State<PhotoLibraryScreen> createState() => _PhotoLibraryScreenState();
}

class _PhotoLibraryScreenState extends State<PhotoLibraryScreen> {
  final ScrollController _scrollController = ScrollController();
  late final PhotoBrowserController _controller;
  late final RealtimeRefreshBinding _realtimeRefresh;

  @override
  void initState() {
    super.initState();
    _controller = PhotoBrowserController(
      parentId: widget.directory.id,
      loadPage: widget.api.getPhotoChildren,
    );
    _scrollController.addListener(_onScroll);
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _controller.refresh,
      shouldRefresh: (event) =>
          isLibraryRefreshEvent(event, userId: widget.api.session.userId),
    );
    unawaited(_controller.loadMore());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    unawaited(_realtimeRefresh.dispose());
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 700) {
      unawaited(_controller.loadMore());
    }
  }

  Future<void> _open(EmbyItem item) async {
    if (item.isPhotoContainer) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoLibraryScreen(api: widget.api, directory: item),
        ),
      );
      return;
    }
    if (!item.isPhoto) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoViewerScreen(
          api: widget.api,
          parentId: widget.directory.id,
          initialDirectoryItems: _controller.items,
          initialItemId: item.id,
          initialHasMore: _controller.hasMore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.directory.name)),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final items = _controller.items;
          return RefreshIndicator(
            onRefresh: _controller.refresh,
            child: CustomScrollView(
              key: const Key('photo-library-grid'),
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (items.isEmpty && _controller.isLoading)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (items.isEmpty && _controller.error != null)
                  SliverFillRemaining(
                    child: ErrorState(
                      error: _controller.error!,
                      onRetry: _controller.loadMore,
                    ),
                  )
                else if (items.isEmpty)
                  const SliverFillRemaining(
                    child: EmptyState(
                      icon: Icons.photo_library_outlined,
                      title: '这个图片目录是空的',
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(12),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            childAspectRatio: 1,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final item = items[index];
                        return _PhotoTile(
                          key: ValueKey('photo-tile-${item.id}'),
                          item: item,
                          api: widget.api,
                          onTap: () => _open(item),
                        );
                      }, childCount: items.length),
                    ),
                  ),
                if (items.isNotEmpty &&
                    (_controller.isLoading || _controller.error != null))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: _controller.error == null
                          ? const Center(child: CircularProgressIndicator())
                          : Center(
                              child: TextButton.icon(
                                onPressed: _controller.loadMore,
                                icon: const Icon(Icons.refresh),
                                label: const Text('加载失败，重试'),
                              ),
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.item,
    required this.api,
    required this.onTap,
  });

  final EmbyItem item;
  final EmbyApi api;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isContainer = item.isPhotoContainer;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            EmbyImage(
              request: api.imageRequest(item, maxWidth: 512, maxHeight: 512),
              icon: isContainer ? Icons.folder_outlined : Icons.photo_outlined,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xD9000000)],
                ),
              ),
            ),
            if (isContainer)
              const Positioned(
                top: 8,
                right: 8,
                child: Icon(Icons.folder_rounded, color: Colors.white),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 9,
              child: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
