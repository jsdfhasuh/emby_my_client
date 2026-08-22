import '../../models/emby_models.dart';

typedef TrickplayDetailFetcher = Future<EmbyItem> Function(String itemId);

class TrickplayDetailHydrator {
  TrickplayDetailHydrator({required this.fetch});

  final TrickplayDetailFetcher fetch;
  final Set<String> _requestedItemIds = {};

  Future<void> hydrate({
    required EmbyItem item,
    required bool Function() isCurrent,
    required void Function(EmbyItem detail) onResolved,
    void Function(Object error)? onFailure,
  }) async {
    if (item.id.isEmpty ||
        item.trickplay != null ||
        !_requestedItemIds.add(item.id)) {
      return;
    }
    try {
      final detail = await fetch(item.id);
      if (!isCurrent() || detail.trickplay == null) return;
      onResolved(detail);
    } catch (error) {
      onFailure?.call(error);
    }
  }
}
