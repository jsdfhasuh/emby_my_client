import '../../models/emby_models.dart';

typedef TrickplayDetailFetcher = Future<EmbyItem> Function(String itemId);

class TrickplayDetailHydrator {
  TrickplayDetailHydrator({required this.fetch});

  final TrickplayDetailFetcher fetch;
  final Map<String, Future<EmbyItem>> _requests = {};
  final Map<String, EmbyItem> _resolvedItems = {};

  Future<void> hydrate({
    required EmbyItem item,
    required bool Function() isCurrent,
    required void Function(EmbyItem detail) onResolved,
    void Function(Object error)? onFailure,
  }) async {
    if (item.id.isEmpty || item.trickplay != null) return;

    final cached = _resolvedItems[item.id];
    if (cached != null) {
      if (isCurrent() && cached.trickplay != null) onResolved(cached);
      return;
    }

    Future<EmbyItem>? request;
    try {
      final activeRequest = _requests.putIfAbsent(
        item.id,
        () => fetch(item.id),
      );
      request = activeRequest;
      final detail = await activeRequest;
      if (identical(_requests[item.id], activeRequest)) {
        _requests.remove(item.id);
      }
      _resolvedItems[item.id] = detail;
      if (!isCurrent() || detail.trickplay == null) return;
      onResolved(detail);
    } catch (error) {
      if (request != null && identical(_requests[item.id], request)) {
        _requests.remove(item.id);
      }
      onFailure?.call(error);
    }
  }
}
