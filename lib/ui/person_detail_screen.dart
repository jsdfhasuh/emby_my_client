import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../people/person_detail_controller.dart';
import 'item_detail_screen.dart';
import 'widgets/media_widgets.dart';
import 'widgets/person_widgets.dart';

class PersonDetailScreen extends StatefulWidget {
  const PersonDetailScreen({
    super.key,
    required this.api,
    required this.personId,
    required this.initialPerson,
    this.downloads,
  });

  final EmbyApi api;
  final String personId;
  final EmbyPerson initialPerson;
  final DownloadService? downloads;

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _worksKey = GlobalKey();
  late final PersonDetailController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PersonDetailController(
      personId: widget.personId,
      loadPerson: widget.api.getItem,
      loadItems: widget.api.getPersonItems,
      loadUserData: widget.api.getUserDataForItems,
    );
    _scrollController.addListener(_onScroll);
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 700) {
      unawaited(_controller.loadMore());
    }
  }

  void _selectFilter(PersonMediaFilter filter) {
    unawaited(_controller.selectFilter(filter));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final worksContext = _worksKey.currentContext;
      if (!mounted || worksContext == null) return;
      Scrollable.ensureVisible(worksContext, alignment: 0);
    });
  }

  Future<void> _openItem(EmbyItem item) async {
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
      await _controller.refreshItemUserData(item.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;
        return Scaffold(
          body: CustomScrollView(
            key: const Key('person-detail-scroll'),
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                pinned: true,
                title: Text(state.person?.name ?? widget.initialPerson.name),
              ),
              SliverToBoxAdapter(child: _buildPersonHeader(state)),
              SliverToBoxAdapter(
                key: _worksKey,
                child: _buildWorksControls(state),
              ),
              ..._buildWorks(state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPersonHeader(PersonDetailState state) {
    final person = state.person;
    final overview = person?.overview?.trim();
    final imageRequest = widget.api.imageRequestForTag(
      itemId: person?.id ?? widget.personId,
      type: 'Primary',
      tag: person?.imageTags['Primary'] ?? widget.initialPerson.primaryImageTag,
      maxWidth: 700,
      maxHeight: 1050,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 112,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: PersonAvatar(imageRequest: imageRequest),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person?.name ?? widget.initialPerson.name,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if (state.loadingPerson) ...[
                      const SizedBox(height: 14),
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (overview != null && overview.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              '简介',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              overview,
              style: const TextStyle(
                color: Color(0xFFC4CACC),
                fontSize: 15,
                height: 1.65,
              ),
            ),
          ],
          if (state.personError != null) ...[
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '人物资料加载失败',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        state.personError.toString(),
                        style: const TextStyle(color: Color(0xFF9DA6A9)),
                      ),
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: _controller.retryPerson,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试人物资料'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWorksControls(PersonDetailState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '作品',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                '共 ${state.totalRecordCount ?? state.items.length} 部',
                key: const Key('person-work-count'),
                style: const TextStyle(color: Color(0xFF9DA6A9)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<PersonMediaFilter>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PersonMediaFilter.all, label: Text('全部')),
                ButtonSegment(
                  value: PersonMediaFilter.movie,
                  label: Text('电影', key: Key('person-filter-movie')),
                ),
                ButtonSegment(
                  value: PersonMediaFilter.series,
                  label: Text('电视剧', key: Key('person-filter-series')),
                ),
              ],
              selected: {state.filter},
              onSelectionChanged: (selection) =>
                  _selectFilter(selection.single),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildWorks(PersonDetailState state) {
    if (state.items.isEmpty && state.loadingFirstPage) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (state.items.isEmpty && state.itemsError != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorState(
            error: state.itemsError!,
            onRetry: _controller.retryItems,
          ),
        ),
      ];
    }
    if (state.items.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.movie_filter_outlined,
            title: '当前服务器没有收录此人物的电影或电视剧',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.52,
            crossAxisSpacing: 12,
            mainAxisSpacing: 18,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final item = state.items[index];
            return MediaPosterCard(
              key: ValueKey('person-work-${item.id}'),
              item: item,
              width: double.infinity,
              imageRequest: widget.api.imageRequest(item, maxWidth: 360),
              onTap: () => _openItem(item),
            );
          }, childCount: state.items.length),
        ),
      ),
      if (state.loadingMore || state.itemsError != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: state.itemsError == null
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: TextButton.icon(
                      onPressed: _controller.retryItems,
                      icon: const Icon(Icons.refresh),
                      label: const Text('加载失败，重试'),
                    ),
                  ),
          ),
        ),
    ];
  }
}
