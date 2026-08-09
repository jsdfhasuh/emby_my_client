import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/emby_api.dart';
import '../models/emby_models.dart';
import '../playback/playback_queue.dart';
import 'library_browse_state.dart';
import 'library_content_profile.dart';
import 'library_local_media_scan_cache.dart';

typedef LibraryPlaybackPageLoader =
    Future<EmbyItemPage> Function({
      required int startIndex,
      required int limit,
    });

typedef LibraryPlaybackProgressCallback =
    void Function(LibraryPlaybackPreparationProgress progress);

@immutable
class LibraryPlaybackQuerySnapshot {
  const LibraryPlaybackQuerySnapshot({
    required this.libraryId,
    required this.state,
    required this.profile,
    required this.fingerprint,
  });

  final String libraryId;
  final LibraryBrowseState state;
  final LibraryContentProfile profile;
  final String fingerprint;
}

@immutable
class LibraryPlaybackPreparationProgress {
  const LibraryPlaybackPreparationProgress({
    required this.rawScannedCount,
    required this.totalCount,
  });

  final int rawScannedCount;
  final int? totalCount;
}

class LibraryPlaybackCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const LibraryPlaybackCancelled();
  }
}

class LibraryPlaybackCancelled implements Exception {
  const LibraryPlaybackCancelled();
}

class LazyLibraryPlaybackQueue extends PlaybackQueue {
  LazyLibraryPlaybackQueue._({
    required super.api,
    required super.initialItems,
    required this.query,
    required _LibraryPlaybackPageSource source,
  }) : _source = source;

  final LibraryPlaybackQuerySnapshot query;
  final _LibraryPlaybackPageSource _source;

  int get rawCursor => _source.rawCursor;

  int? get totalCount => _source.totalCount;

  @override
  bool get hasDeferredItems => _source.hasMore;

  @override
  bool canPotentiallyAdvance(EmbyItem item) =>
      super.canPotentiallyAdvance(item) || _source.hasMore;

  @override
  Future<EmbyItem?> next(EmbyItem item) async {
    final loaded = await super.next(item);
    if (loaded != null) return loaded;

    while (_source.hasMore) {
      appendUnique(await _source.loadNextPlayableBatch());
      final nextIndex = indexOf(item) + 1;
      if (nextIndex > 0 && nextIndex < items.length) return items[nextIndex];
    }
    return null;
  }

  static Future<LazyLibraryPlaybackQueue?> prepare({
    required EmbyApi api,
    required LibraryPlaybackQuerySnapshot query,
    required List<EmbyItem> initialItems,
    required int initialRawCursor,
    required int? totalCount,
    required LibraryPlaybackPageLoader loadPage,
    bool shuffle = false,
    int pageSize = 60,
    LibraryPlaybackCancellation? cancellation,
    LibraryPlaybackProgressCallback? onProgress,
    Random? random,
  }) async {
    assert(initialRawCursor >= 0);
    assert(totalCount == null || totalCount >= 0);
    assert(pageSize > 0);
    final token = cancellation ?? LibraryPlaybackCancellation();
    final source = _LibraryPlaybackPageSource(
      initialItems: initialItems,
      initialRawCursor: initialRawCursor,
      initialTotalCount: totalCount,
      pageSize: pageSize,
      loadPage: loadPage,
      shuffle: shuffle,
      random: random ?? Random(),
      cancellation: token,
      onProgress: onProgress,
    );
    await source.initialize();
    token.throwIfCancelled();

    final firstItems = <EmbyItem>[];
    if (!shuffle) {
      firstItems.addAll(_uniquePlayable(initialItems));
    }
    while (firstItems.isEmpty && source.hasMore) {
      firstItems.addAll(await source.loadNextPlayableBatch());
    }
    token.throwIfCancelled();
    if (firstItems.isEmpty) return null;
    return LazyLibraryPlaybackQueue._(
      api: api,
      initialItems: firstItems,
      query: query,
      source: source,
    );
  }
}

bool canPlayCompleteLibraryResult({
  required LibraryBrowseState state,
  required LibraryContentProfile profile,
  required int playableLoadedCount,
  required bool hasMore,
  LibraryLocalScanSnapshot? localScan,
}) {
  if (!state.scope.supportsMediaFilters ||
      !profile.supportsPlayAll ||
      state.mediaType == LibraryMediaType.photo) {
    return false;
  }
  if (state.localFilter == LibraryLocalMediaFilter.all) {
    return playableLoadedCount > 0 || hasMore;
  }
  final scan = localScan;
  if (scan == null ||
      !scan.complete ||
      scan.status != LibraryScanStatus.complete ||
      scan.safeError != null ||
      scan.dirty ||
      playableLoadedCount == 0) {
    return false;
  }
  return state.localFilter != LibraryLocalMediaFilter.regular ||
      scan.unknownCount == 0;
}

class _LibraryPlaybackPageSource {
  _LibraryPlaybackPageSource({
    required List<EmbyItem> initialItems,
    required int initialRawCursor,
    required int? initialTotalCount,
    required this.pageSize,
    required this.loadPage,
    required this.shuffle,
    required this.random,
    required this.cancellation,
    required this.onProgress,
  }) : _initialItems = List<EmbyItem>.of(initialItems),
       rawCursor = initialRawCursor,
       totalCount = initialTotalCount,
       _sequentialHasMore = initialTotalCount == null
           ? true
           : initialRawCursor < initialTotalCount;

  final List<EmbyItem> _initialItems;
  final int pageSize;
  final LibraryPlaybackPageLoader loadPage;
  final bool shuffle;
  final Random random;
  final LibraryPlaybackCancellation cancellation;
  final LibraryPlaybackProgressCallback? onProgress;
  final List<_LibraryPlaybackChunk> _chunks = [];

  int rawCursor;
  int? totalCount;
  bool _sequentialHasMore;
  int _chunkIndex = 0;
  bool _initialized = false;

  bool get hasMore => shuffle
      ? _chunkIndex < _chunks.length || _sequentialHasMore
      : _sequentialHasMore;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    cancellation.throwIfCancelled();
    onProgress?.call(
      LibraryPlaybackPreparationProgress(
        rawScannedCount: rawCursor,
        totalCount: totalCount,
      ),
    );
    if (!shuffle) return;

    if (totalCount == null && _sequentialHasMore) {
      final prefetched = await _loadSequentialChunk();
      if (prefetched != null) _chunks.add(prefetched);
    }
    if (_initialItems.isNotEmpty || rawCursor > 0) {
      _chunks.add(
        _LibraryPlaybackChunk.buffered(
          startIndex: 0,
          rawItemCount:
              rawCursor -
              _chunks.fold<int>(0, (sum, chunk) => sum + chunk.rawItemCount),
          items: _initialItems,
        ),
      );
    }
    final total = totalCount;
    if (total != null) {
      for (var start = rawCursor; start < total; start += pageSize) {
        _chunks.add(_LibraryPlaybackChunk.remote(startIndex: start));
      }
      _sequentialHasMore = false;
    }
    _shuffle(_chunks, random);
  }

  Future<List<EmbyItem>> loadNextPlayableBatch() async {
    cancellation.throwIfCancelled();
    if (shuffle && _chunkIndex < _chunks.length) {
      final chunk = _chunks[_chunkIndex++];
      final loadedChunk = chunk.items == null
          ? await _loadRemoteChunk(chunk.startIndex)
          : chunk;
      if (chunk.items == null) {
        rawCursor += loadedChunk.rawItemCount;
        _reportProgress();
      }
      final items = loadedChunk.items ?? const <EmbyItem>[];
      final playable = _uniquePlayable(items);
      _shuffle(playable, random);
      cancellation.throwIfCancelled();
      return playable;
    }
    final chunk = await _loadSequentialChunk();
    if (chunk == null) return const [];
    final playable = _uniquePlayable(chunk.items ?? const []);
    if (shuffle) _shuffle(playable, random);
    cancellation.throwIfCancelled();
    return playable;
  }

  Future<_LibraryPlaybackChunk?> _loadSequentialChunk() async {
    if (!_sequentialHasMore) return null;
    final startIndex = rawCursor;
    final chunk = await _loadRemoteChunk(startIndex);
    final rawItemCount = chunk.rawItemCount;
    rawCursor += rawItemCount;
    _reportProgress();
    _sequentialHasMore =
        rawItemCount != 0 &&
        (totalCount == null
            ? rawItemCount == pageSize
            : rawCursor < totalCount!);
    return chunk;
  }

  Future<_LibraryPlaybackChunk> _loadRemoteChunk(int startIndex) async {
    cancellation.throwIfCancelled();
    final page = await loadPage(startIndex: startIndex, limit: pageSize);
    cancellation.throwIfCancelled();
    if (page.totalRecordCount != null) totalCount = page.totalRecordCount;
    return _LibraryPlaybackChunk.buffered(
      startIndex: startIndex,
      rawItemCount: page.rawItemCount,
      items: page.items,
    );
  }

  void _reportProgress() {
    onProgress?.call(
      LibraryPlaybackPreparationProgress(
        rawScannedCount: rawCursor,
        totalCount: totalCount,
      ),
    );
  }
}

class _LibraryPlaybackChunk {
  const _LibraryPlaybackChunk.remote({required this.startIndex})
    : rawItemCount = 0,
      items = null;

  const _LibraryPlaybackChunk.buffered({
    required this.startIndex,
    required this.rawItemCount,
    required this.items,
  });

  final int startIndex;
  final int rawItemCount;
  final List<EmbyItem>? items;
}

List<EmbyItem> _uniquePlayable(Iterable<EmbyItem> items) {
  final ids = <String>{};
  return items
      .where(
        (item) => item.isPlayable && item.id.isNotEmpty && ids.add(item.id),
      )
      .toList(growable: false);
}

void _shuffle<T>(List<T> values, Random random) {
  for (var index = values.length - 1; index > 0; index--) {
    final other = random.nextInt(index + 1);
    final value = values[index];
    values[index] = values[other];
    values[other] = value;
  }
}
