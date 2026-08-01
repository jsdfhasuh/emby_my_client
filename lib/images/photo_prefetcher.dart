import 'dart:async';
import 'dart:collection';

import 'emby_image_request.dart';

typedef PhotoImageLoader = Future<void> Function(EmbyImageRequest request);

class PhotoPrefetcher {
  PhotoPrefetcher({required PhotoImageLoader load, this.maxConcurrent = 2})
    : assert(maxConcurrent > 0),
      _load = load;

  final int maxConcurrent;
  final PhotoImageLoader _load;
  final ListQueue<_QueuedRequest> _queue = ListQueue();
  final Set<String> _activeKeys = {};
  final Set<String> _queuedKeys = {};
  final Set<String> _completedKeys = {};

  int _generation = 0;
  bool _disposed = false;

  int get activeCount => _activeKeys.length;
  int get completedCount => _completedKeys.length;

  void schedule(Iterable<EmbyImageRequest> requests) {
    if (_disposed) return;
    final generation = ++_generation;
    _queue.clear();
    _queuedKeys.clear();
    for (final request in requests) {
      final key = request.cacheKey;
      if (_activeKeys.contains(key) ||
          _completedKeys.contains(key) ||
          !_queuedKeys.add(key)) {
        continue;
      }
      _queue.add(_QueuedRequest(request, generation));
    }
    _drain();
  }

  void _drain() {
    if (_disposed) return;
    while (_activeKeys.length < maxConcurrent && _queue.isNotEmpty) {
      final queued = _queue.removeFirst();
      _queuedKeys.remove(queued.request.cacheKey);
      if (queued.generation != _generation) continue;
      _activeKeys.add(queued.request.cacheKey);
      unawaited(_run(queued));
    }
  }

  Future<void> _run(_QueuedRequest queued) async {
    var completed = false;
    try {
      await _load(queued.request);
      completed = true;
    } catch (_) {
      // A visible image load owns user-facing retry behavior.
    } finally {
      _activeKeys.remove(queued.request.cacheKey);
      if (completed) _completedKeys.add(queued.request.cacheKey);
      _drain();
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _queue.clear();
    _queuedKeys.clear();
  }
}

class _QueuedRequest {
  const _QueuedRequest(this.request, this.generation);

  final EmbyImageRequest request;
  final int generation;
}
