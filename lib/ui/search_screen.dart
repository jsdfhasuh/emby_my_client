import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emby_api.dart';
import '../downloads/download_service.dart';
import '../models/emby_models.dart';
import '../realtime/realtime_refresh_binding.dart';
import 'item_detail_screen.dart';
import 'widgets/media_widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.api, this.downloads});

  final EmbyApi api;
  final DownloadService? downloads;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<EmbyItem> _results = const [];
  bool _loading = false;
  bool _hasSearched = false;
  Object? _error;
  int _requestId = 0;
  late final RealtimeRefreshBinding _realtimeRefresh;

  @override
  void initState() {
    super.initState();
    _realtimeRefresh = RealtimeRefreshBinding(
      client: widget.api.realtime,
      refresh: _refreshRealtime,
      shouldRefresh: (event) =>
          isLibraryRefreshEvent(event, userId: widget.api.session.userId),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_realtimeRefresh.dispose());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refreshRealtime() async {
    final query = _controller.text.trim();
    if (query.isNotEmpty) await _search(query);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _hasSearched = false;
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 420), () => _search(query));
  }

  Future<void> _search(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _hasSearched = true;
      _error = null;
    });
    try {
      final results = await widget.api.search(query);
      if (!mounted || requestId != _requestId) return;
      setState(() => _results = results);
    } catch (error) {
      if (mounted && requestId == _requestId) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(EmbyItem item) async {
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
    final query = _controller.text.trim();
    if (query.isNotEmpty) await _search(query);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: TextField(
            controller: _controller,
            autofocus: false,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (value) {
              _debounce?.cancel();
              if (value.trim().isNotEmpty) _search(value.trim());
            },
            decoration: InputDecoration(
              hintText: '电影、剧集或单集',
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
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildResult()),
      ],
    );
  }

  Widget _buildResult() {
    if (_error != null) {
      return ErrorState(
        error: _error!,
        onRetry: () => _search(_controller.text.trim()),
      );
    }
    if (!_hasSearched) {
      return const EmptyState(icon: Icons.manage_search, title: '搜索你的媒体库');
    }
    if (!_loading && _results.isEmpty) {
      return const EmptyState(icon: Icons.search_off, title: '没有找到匹配的媒体');
    }
    return MediaGrid(
      items: _results,
      imageRequestFor: widget.api.imageRequest,
      onTap: _open,
    );
  }
}
