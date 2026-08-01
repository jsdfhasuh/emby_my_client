import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';

typedef PersonLoader = Future<EmbyItem> Function(String personId);
typedef PersonItemsLoader =
    Future<EmbyItemPage> Function({
      required String personId,
      int startIndex,
      int limit,
      PersonMediaFilter filter,
    });

class PersonDetailState {
  const PersonDetailState({
    this.person,
    this.items = const [],
    this.filter = PersonMediaFilter.all,
    this.totalRecordCount,
    this.loadingPerson = false,
    this.loadingFirstPage = false,
    this.loadingMore = false,
    this.personError,
    this.itemsError,
    this.hasMore = true,
  });

  final EmbyItem? person;
  final List<EmbyItem> items;
  final PersonMediaFilter filter;
  final int? totalRecordCount;
  final bool loadingPerson;
  final bool loadingFirstPage;
  final bool loadingMore;
  final Object? personError;
  final Object? itemsError;
  final bool hasMore;
}

class PersonDetailController extends ChangeNotifier {
  PersonDetailController({
    required this.personId,
    required PersonLoader loadPerson,
    required PersonItemsLoader loadItems,
    this.pageSize = 60,
  }) : _loadPerson = loadPerson,
       _loadItems = loadItems;

  final String personId;
  final int pageSize;
  final PersonLoader _loadPerson;
  final PersonItemsLoader _loadItems;

  PersonDetailState _state = const PersonDetailState();
  bool _disposed = false;
  int _personGeneration = 0;
  int _itemsGeneration = 0;
  int _nextStartIndex = 0;

  PersonDetailState get state => _state;

  Future<void> load() async {
    if (_disposed) return;
    final personGeneration = ++_personGeneration;
    final itemsGeneration = ++_itemsGeneration;
    _nextStartIndex = 0;
    _setState(
      PersonDetailState(
        filter: _state.filter,
        loadingPerson: true,
        loadingFirstPage: true,
      ),
    );
    await Future.wait([
      _requestPerson(personGeneration),
      _requestItems(generation: itemsGeneration, firstPage: true),
    ]);
  }

  Future<void> retryPerson() async {
    if (_disposed || _state.loadingPerson) return;
    final generation = ++_personGeneration;
    _setState(_copyState(loadingPerson: true, clearPersonError: true));
    await _requestPerson(generation);
  }

  Future<void> selectFilter(PersonMediaFilter filter) async {
    if (_disposed || filter == _state.filter) return;
    final generation = ++_itemsGeneration;
    _nextStartIndex = 0;
    _setState(
      _copyState(
        items: const [],
        filter: filter,
        clearTotalRecordCount: true,
        loadingFirstPage: true,
        loadingMore: false,
        clearItemsError: true,
        hasMore: true,
      ),
    );
    await _requestItems(generation: generation, firstPage: true);
  }

  Future<void> loadMore() async {
    if (_disposed ||
        _state.loadingFirstPage ||
        _state.loadingMore ||
        !_state.hasMore) {
      return;
    }
    final generation = _itemsGeneration;
    _setState(_copyState(loadingMore: true, clearItemsError: true));
    await _requestItems(generation: generation, firstPage: false);
  }

  Future<void> retryItems() async {
    if (_disposed || _state.loadingFirstPage || _state.loadingMore) return;
    if (_state.items.isNotEmpty) {
      await loadMore();
      return;
    }
    final generation = ++_itemsGeneration;
    _nextStartIndex = 0;
    _setState(
      _copyState(loadingFirstPage: true, clearItemsError: true, hasMore: true),
    );
    await _requestItems(generation: generation, firstPage: true);
  }

  Future<void> _requestPerson(int generation) async {
    try {
      final person = await _loadPerson(personId);
      if (!_acceptPerson(generation)) return;
      _setState(
        _copyState(
          person: person,
          loadingPerson: false,
          clearPersonError: true,
        ),
      );
    } catch (error) {
      if (!_acceptPerson(generation)) return;
      _setState(_copyState(loadingPerson: false, personError: error));
    }
  }

  Future<void> _requestItems({
    required int generation,
    required bool firstPage,
  }) async {
    final startIndex = firstPage ? 0 : _nextStartIndex;
    try {
      final page = await _loadItems(
        personId: personId,
        startIndex: startIndex,
        limit: pageSize,
        filter: _state.filter,
      );
      if (!_acceptItems(generation)) return;
      final existing = firstPage ? <EmbyItem>[] : List.of(_state.items);
      final seen = existing.map((item) => item.id).toSet();
      existing.addAll(page.items.where((item) => seen.add(item.id)));
      _nextStartIndex = startIndex + page.rawItemCount;
      final hasMore =
          page.rawItemCount > 0 &&
          (page.totalRecordCount == null
              ? page.rawItemCount == pageSize
              : _nextStartIndex < page.totalRecordCount!);
      _setState(
        _copyState(
          items: List.unmodifiable(existing),
          totalRecordCount: page.totalRecordCount,
          loadingFirstPage: false,
          loadingMore: false,
          clearItemsError: true,
          hasMore: hasMore,
        ),
      );
    } catch (error) {
      if (!_acceptItems(generation)) return;
      _setState(
        _copyState(
          loadingFirstPage: false,
          loadingMore: false,
          itemsError: error,
        ),
      );
    }
  }

  bool _acceptPerson(int generation) =>
      !_disposed && generation == _personGeneration;

  bool _acceptItems(int generation) =>
      !_disposed && generation == _itemsGeneration;

  PersonDetailState _copyState({
    EmbyItem? person,
    List<EmbyItem>? items,
    PersonMediaFilter? filter,
    int? totalRecordCount,
    bool clearTotalRecordCount = false,
    bool? loadingPerson,
    bool? loadingFirstPage,
    bool? loadingMore,
    Object? personError,
    bool clearPersonError = false,
    Object? itemsError,
    bool clearItemsError = false,
    bool? hasMore,
  }) => PersonDetailState(
    person: person ?? _state.person,
    items: items ?? _state.items,
    filter: filter ?? _state.filter,
    totalRecordCount: clearTotalRecordCount
        ? null
        : totalRecordCount ?? _state.totalRecordCount,
    loadingPerson: loadingPerson ?? _state.loadingPerson,
    loadingFirstPage: loadingFirstPage ?? _state.loadingFirstPage,
    loadingMore: loadingMore ?? _state.loadingMore,
    personError: clearPersonError ? null : personError ?? _state.personError,
    itemsError: clearItemsError ? null : itemsError ?? _state.itemsError,
    hasMore: hasMore ?? _state.hasMore,
  );

  void _setState(PersonDetailState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _personGeneration++;
    _itemsGeneration++;
    super.dispose();
  }
}
