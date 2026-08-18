import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'library_content_profile.dart';
import 'library_navigation_context.dart';

enum LibraryRootResolutionFailure {
  rootUnavailable,
  ancestorLoop,
  ancestorDepthExceeded,
  requestFailed,
}

class LibraryRootResolutionException implements Exception {
  const LibraryRootResolutionException(this.failure);

  final LibraryRootResolutionFailure failure;

  @override
  String toString() => 'LibraryRootResolutionException(${failure.name})';
}

class LibraryRootResolver {
  LibraryRootResolver({required this.api});

  static const maxAncestorDepth = 32;

  final EmbyApi api;
  Future<List<EmbyItem>>? _viewsFuture;
  final Map<String, LibraryBrowseOrigin> _originByItemId = {};
  final Map<String, Future<LibraryBrowseOrigin>> _inFlight = {};

  Future<LibraryBrowseOrigin> resolve({
    required EmbyItem item,
    LibraryBrowseOrigin? knownOrigin,
  }) async {
    if (knownOrigin != null) {
      if (!knownOrigin.isValid) {
        throw const LibraryRootResolutionException(
          LibraryRootResolutionFailure.rootUnavailable,
        );
      }
      return knownOrigin;
    }

    final itemId = item.id.trim();
    if (itemId.isEmpty) {
      throw const LibraryRootResolutionException(
        LibraryRootResolutionFailure.rootUnavailable,
      );
    }
    final cached = _originByItemId[itemId];
    if (cached != null) return cached;
    final active = _inFlight[itemId];
    if (active != null) return active;

    final future = _resolveUncached(item);
    _inFlight[itemId] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[itemId], future)) _inFlight.remove(itemId);
    }
  }

  Future<LibraryBrowseOrigin> _resolveUncached(EmbyItem item) async {
    final roots = await _loadRoots();
    final rootsById = <String, EmbyItem>{
      for (final root in roots)
        if (root.id.trim().isNotEmpty) root.id.trim(): root,
    };

    var current = item;
    var parentId = _nonEmptyId(current.parentId);
    if (parentId == null) {
      try {
        current = await api.getItem(item.id);
      } catch (error, stackTrace) {
        _logRequestFailure(
          'Failed to refresh item parent for library root',
          error,
          stackTrace,
        );
        throw const LibraryRootResolutionException(
          LibraryRootResolutionFailure.requestFailed,
        );
      }
      parentId = _nonEmptyId(current.parentId);
    }

    if (parentId == null) {
      throw const LibraryRootResolutionException(
        LibraryRootResolutionFailure.rootUnavailable,
      );
    }

    final visitedIds = <String>{};
    final chainIds = <String>[item.id.trim()];
    String? cursor = parentId;
    for (var depth = 0; depth < maxAncestorDepth; depth++) {
      if (cursor == null || cursor.isEmpty) {
        throw const LibraryRootResolutionException(
          LibraryRootResolutionFailure.rootUnavailable,
        );
      }
      if (!visitedIds.add(cursor)) {
        throw const LibraryRootResolutionException(
          LibraryRootResolutionFailure.ancestorLoop,
        );
      }
      chainIds.add(cursor);

      final root = rootsById[cursor];
      if (root != null) {
        final origin = LibraryBrowseOrigin(
          rootView: root,
          profile: LibraryContentProfile.fromCollectionType(
            root.collectionType,
          ),
        );
        for (final id in chainIds) {
          if (id.isNotEmpty) _originByItemId[id] = origin;
        }
        return origin;
      }

      try {
        current = await api.getItem(cursor);
      } catch (error, stackTrace) {
        _logRequestFailure(
          'Failed to load library ancestor',
          error,
          stackTrace,
        );
        throw const LibraryRootResolutionException(
          LibraryRootResolutionFailure.requestFailed,
        );
      }
      cursor = _nonEmptyId(current.parentId);
    }

    throw const LibraryRootResolutionException(
      LibraryRootResolutionFailure.ancestorDepthExceeded,
    );
  }

  Future<List<EmbyItem>> _loadRoots() async {
    final active = _viewsFuture;
    if (active != null) return active;
    final future = api.getViews();
    _viewsFuture = future;
    try {
      return await future;
    } catch (error, stackTrace) {
      if (identical(_viewsFuture, future)) _viewsFuture = null;
      _logRequestFailure(
        'Failed to load media library roots',
        error,
        stackTrace,
      );
      throw const LibraryRootResolutionException(
        LibraryRootResolutionFailure.requestFailed,
      );
    }
  }

  void _logRequestFailure(String message, Object error, StackTrace stackTrace) {
    DiagnosticLog.instance.error(
      'library',
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

String? _nonEmptyId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
