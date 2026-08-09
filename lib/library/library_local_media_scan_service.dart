import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../core/diagnostic_log.dart';
import '../core/server_scope.dart';
import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'library_browse_state.dart';
import 'library_local_media_scan_cache.dart';

typedef LibraryScanPageLoader =
    Future<EmbyItemPage> Function({
      required int startIndex,
      required int limit,
    });

typedef LibraryScanDelay = Future<void> Function(Duration duration);

typedef LibraryScanServiceFactory =
    LibraryLocalMediaScanService Function(EmbyApi api, ServerScope scope);

@immutable
class LibraryLocalMediaScanRequest {
  const LibraryLocalMediaScanRequest({
    required this.key,
    required this.loadPage,
  });

  final LibraryScanKey key;
  final LibraryScanPageLoader loadPage;
}

class LibraryLocalMediaScanService extends ChangeNotifier {
  LibraryLocalMediaScanService({
    required this.api,
    required this.scope,
    this.pageSize = 60,
    this.maxCandidateItems = 20000,
    LibraryScanDelay? delay,
    LibraryLocalMediaScanCache? cache,
  }) : _delay = delay ?? Future<void>.delayed,
       _cache = cache ?? LibraryLocalMediaScanCache();

  final EmbyApi api;
  final ServerScope scope;
  final int pageSize;
  final int maxCandidateItems;
  final LibraryScanDelay _delay;
  final LibraryLocalMediaScanCache _cache;
  final Map<LibraryScanKey, LibraryScanPageLoader> _loaders = {};
  final Queue<LibraryScanKey> _pending = Queue();
  final Set<LibraryScanKey> _pendingSet = {};
  final Completer<void> _cancelled = Completer<void>();

  Future<void>? _activeOperation;
  bool _foreground = true;
  bool _acceptingScans = true;
  bool _disposed = false;

  LibraryLocalScanSnapshot? snapshotFor(LibraryScanKey key) =>
      _cache[key]?.snapshot;

  List<EmbyItem> itemsFor(LibraryScanKey key, LibraryLocalMediaFilter filter) =>
      _cache[key]?.itemsFor(filter) ?? const [];

  LibraryLocalScanSnapshot ensureScan(LibraryLocalMediaScanRequest request) {
    if (!_acceptingScans || _disposed) {
      throw StateError('Library scan service is shutting down');
    }
    if (request.key.scopeNamespace != scope.cacheNamespace) {
      throw StateError('Library scan key belongs to a different server scope');
    }
    final entry = _cache.putIfAbsent(request.key);
    _loaders.putIfAbsent(request.key, () => request.loadPage);
    if (entry.status == LibraryScanStatus.queued) {
      _enqueue(request.key);
    }
    return entry.snapshot;
  }

  LibraryLocalScanSnapshot restartScan(LibraryLocalMediaScanRequest request) {
    if (!_acceptingScans || _disposed) {
      throw StateError('Library scan service is shutting down');
    }
    _removeScan(request.key);
    return ensureScan(request);
  }

  void clearScan(LibraryScanKey key) {
    if (!_acceptingScans || _disposed) return;
    _removeScan(key);
    _notify();
  }

  void updateUserData(
    LibraryScanKey key,
    Map<String, EmbyUserData> userDataById,
  ) {
    if (_disposed || userDataById.isEmpty) return;
    if (_cache[key]?.updateUserData(userDataById) ?? false) _notify();
  }

  Future<void> retry(LibraryScanKey key) async {
    final entry = _cache[key];
    if (!_acceptingScans ||
        entry == null ||
        entry.status != LibraryScanStatus.paused) {
      return;
    }
    entry
      ..status = LibraryScanStatus.queued
      ..safeError = null;
    entry.generation++;
    _enqueue(key);
    _notify();
  }

  void pauseAll() {
    if (!_acceptingScans || !_foreground) return;
    _foreground = false;
  }

  void resumeAll() {
    if (!_acceptingScans || _foreground) return;
    _foreground = true;
    for (final entry in _cache.entries) {
      if (entry.status == LibraryScanStatus.paused && entry.safeError == null) {
        entry.status = LibraryScanStatus.queued;
        _enqueue(entry.key);
      }
    }
    _pump();
  }

  void clearCompleted() {
    final keys = _cache.entries
        .where((entry) => entry.status == LibraryScanStatus.complete)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keys) {
      _cache.remove(key);
      _loaders.remove(key);
      _pendingSet.remove(key);
      _pending.remove(key);
    }
    if (keys.isNotEmpty) _notify();
  }

  void _removeScan(LibraryScanKey key) {
    final entry = _cache[key];
    if (entry != null) entry.generation++;
    _cache.remove(key);
    _loaders.remove(key);
    _pendingSet.remove(key);
    _pending.remove(key);
  }

  Future<void> cancelAll() async {
    if (!_acceptingScans) {
      await _activeOperation;
      return;
    }
    _acceptingScans = false;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _pending.clear();
    _pendingSet.clear();
    for (final entry in _cache.entries) {
      entry.generation++;
      entry
        ..status = LibraryScanStatus.cancelled
        ..safeError = null;
    }
    _notify();
    await _activeOperation;
  }

  void _enqueue(LibraryScanKey key) {
    if (!_acceptingScans || !_pendingSet.add(key)) return;
    _pending.addLast(key);
    _pump();
  }

  void _pump() {
    if (!_acceptingScans ||
        !_foreground ||
        _activeOperation != null ||
        _pending.isEmpty) {
      return;
    }
    final key = _pending.removeFirst();
    _pendingSet.remove(key);
    final entry = _cache[key];
    final loader = _loaders[key];
    if (entry == null ||
        loader == null ||
        entry.status != LibraryScanStatus.queued) {
      scheduleMicrotask(_pump);
      return;
    }
    late final Future<void> operation;
    operation = _run(entry, loader).whenComplete(() {
      if (identical(_activeOperation, operation)) {
        _activeOperation = null;
        if (_acceptingScans) _pump();
      }
    });
    _activeOperation = operation;
  }

  Future<void> _run(
    LibraryLocalMediaScanCacheEntry entry,
    LibraryScanPageLoader loader,
  ) async {
    final generation = entry.generation;
    final permitFuture = _GlobalLibraryScanLimiter.acquire();
    final permit = await Future.any<bool>([
      permitFuture.then((_) => true),
      _cancelled.future.then((_) => false),
    ]);
    if (!permit) {
      unawaited(permitFuture.then((_) => _GlobalLibraryScanLimiter.release()));
      return;
    }
    try {
      if (!_isCurrent(entry, generation)) return;
      entry
        ..status = LibraryScanStatus.scanning
        ..safeError = null;
      _notify();
      while (_isCurrent(entry, generation) && _foreground) {
        final page = await _loadWithRetry(entry, loader, generation);
        if (page == null || !_isCurrent(entry, generation)) return;
        if (!_applyPage(entry, page)) {
          _notify();
          return;
        }
        _notify();
        if (entry.status == LibraryScanStatus.complete) {
          _cache.touchCompleted(entry.key);
          return;
        }
        if (entry.status != LibraryScanStatus.scanning) return;
      }
      if (_isCurrent(entry, generation) && !_foreground) {
        entry
          ..status = LibraryScanStatus.paused
          ..safeError = null;
        _notify();
      }
    } finally {
      _GlobalLibraryScanLimiter.release();
    }
  }

  Future<EmbyItemPage?> _loadWithRetry(
    LibraryLocalMediaScanCacheEntry entry,
    LibraryScanPageLoader loader,
    int generation,
  ) async {
    const retryDelays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    for (var attempt = 0; ; attempt++) {
      try {
        return await loader(startIndex: entry.rawCursor, limit: pageSize);
      } catch (error, stackTrace) {
        if (!_isCurrent(entry, generation)) return null;
        if (error is EmbyApiException && error.isAuthenticationFailure) {
          _pauseWithError(entry, LibraryScanErrorKind.unauthorized);
          _logFailure(error, stackTrace, LibraryScanErrorKind.unauthorized);
          _notify();
          return null;
        }
        if (attempt >= retryDelays.length) {
          _pauseWithError(entry, LibraryScanErrorKind.requestFailed);
          _logFailure(error, stackTrace, LibraryScanErrorKind.requestFailed);
          _notify();
          return null;
        }
        final continueAfterDelay = await Future.any<bool>([
          _delay(retryDelays[attempt]).then((_) => true),
          _cancelled.future.then((_) => false),
        ]);
        if (!continueAfterDelay || !_isCurrent(entry, generation)) return null;
      }
    }
  }

  bool _applyPage(LibraryLocalMediaScanCacheEntry entry, EmbyItemPage page) {
    final additionIds = page.items
        .where(isLibraryLocalMediaCandidate)
        .map((item) => item.id)
        .where((id) => !entry.itemsById.containsKey(id))
        .toSet();
    if (entry.candidateCount + additionIds.length > maxCandidateItems) {
      _pauseWithError(entry, LibraryScanErrorKind.capacityReached);
      return false;
    }

    entry.updateTotal(page.totalRecordCount);
    if (page.rawItemCount == 0) {
      final total = entry.sourceTotalCount;
      if (total != null && entry.rawCursor < total) {
        _pauseWithError(entry, LibraryScanErrorKind.paginationStalled);
      } else {
        entry.status = LibraryScanStatus.complete;
      }
      return true;
    }

    entry
      ..rawCursor += page.rawItemCount
      ..scannedRawCount += page.rawItemCount;
    for (final item in page.items.where(isLibraryLocalMediaCandidate)) {
      entry.addOrUpdate(item, classifyLibraryLocalMedia(item));
    }

    final total = entry.sourceTotalCount;
    final complete = total != null
        ? entry.rawCursor >= total
        : page.rawItemCount < pageSize;
    if (complete) entry.status = LibraryScanStatus.complete;
    return true;
  }

  void _pauseWithError(
    LibraryLocalMediaScanCacheEntry entry,
    LibraryScanErrorKind error,
  ) {
    entry
      ..status = LibraryScanStatus.paused
      ..safeError = error;
  }

  bool _isCurrent(LibraryLocalMediaScanCacheEntry entry, int generation) =>
      _acceptingScans &&
      !_disposed &&
      identical(_cache[entry.key], entry) &&
      entry.generation == generation;

  void _logFailure(
    Object error,
    StackTrace stackTrace,
    LibraryScanErrorKind kind,
  ) {
    DiagnosticLog.instance.error(
      'library-scan',
      'Local media scan paused reason=${kind.name}',
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    assert(!_acceptingScans && _activeOperation == null);
    _disposed = true;
    _loaders.clear();
    _cache.clear();
    super.dispose();
  }
}

class _GlobalLibraryScanLimiter {
  static const _maximum = 2;
  static final Queue<Completer<void>> _waiters = Queue();
  static int _active = 0;

  static Future<void> acquire() {
    if (_active < _maximum) {
      _active++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  static void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    assert(_active > 0);
    _active--;
  }
}
