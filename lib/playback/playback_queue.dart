import '../data/emby_api.dart';
import '../models/emby_models.dart';

class PlaybackQueue {
  PlaybackQueue({
    required this.api,
    required List<EmbyItem> initialItems,
    this.seriesId,
    List<EmbyItem> seasons = const [],
    String? currentSeasonId,
  }) : _items = List<EmbyItem>.of(initialItems),
       _seasons = List<EmbyItem>.of(seasons),
       _loadedSeasonId = currentSeasonId;

  factory PlaybackQueue.single(EmbyApi api, EmbyItem item) =>
      PlaybackQueue(api: api, initialItems: [item]);

  final EmbyApi api;
  final String? seriesId;
  final List<EmbyItem> _items;
  final List<EmbyItem> _seasons;
  String? _loadedSeasonId;

  List<EmbyItem> get items => List.unmodifiable(_items);

  bool get hasDeferredItems => false;

  int indexOf(EmbyItem item) =>
      _items.indexWhere((candidate) => candidate.id == item.id);

  EmbyItem? previous(EmbyItem item) {
    final index = indexOf(item);
    return index > 0 ? _items[index - 1] : null;
  }

  bool canPotentiallyAdvance(EmbyItem item) {
    final index = indexOf(item);
    if (index >= 0 && index + 1 < _items.length) return true;
    final currentSeasonIndex = _seasons.indexWhere(
      (season) => season.id == _loadedSeasonId,
    );
    return seriesId != null &&
        currentSeasonIndex >= 0 &&
        currentSeasonIndex + 1 < _seasons.length;
  }

  void appendUnique(Iterable<EmbyItem> items) {
    final ids = _items.map((item) => item.id).toSet();
    for (final item in items) {
      if (item.id.isNotEmpty && ids.add(item.id)) _items.add(item);
    }
  }

  Future<EmbyItem?> next(EmbyItem item) async {
    final index = indexOf(item);
    if (index >= 0 && index + 1 < _items.length) return _items[index + 1];
    final series = seriesId;
    if (series == null || _seasons.isEmpty) return null;

    final currentSeasonIndex = _seasons.indexWhere(
      (season) => season.id == _loadedSeasonId,
    );
    if (currentSeasonIndex < 0 || currentSeasonIndex + 1 >= _seasons.length) {
      return null;
    }
    final nextSeason = _seasons[currentSeasonIndex + 1];
    final episodes = await api.getEpisodes(series, seasonId: nextSeason.id);
    _loadedSeasonId = nextSeason.id;
    appendUnique(episodes);
    final refreshedIndex = indexOf(item);
    return refreshedIndex >= 0 && refreshedIndex + 1 < _items.length
        ? _items[refreshedIndex + 1]
        : null;
  }
}
