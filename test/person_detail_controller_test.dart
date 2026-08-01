import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/people/person_detail_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads person details and first works page in parallel', () async {
    final personResult = Completer<EmbyItem>();
    final itemsResult = Completer<EmbyItemPage>();
    var personCalls = 0;
    var itemCalls = 0;
    final controller = PersonDetailController(
      personId: 'person-1',
      loadPerson: (personId) {
        personCalls++;
        return personResult.future;
      },
      loadUserData: _emptyUserData,
      loadItems:
          ({
            required personId,
            startIndex = 0,
            limit = 60,
            filter = PersonMediaFilter.all,
          }) {
            itemCalls++;
            return itemsResult.future;
          },
    );
    addTearDown(controller.dispose);

    final loading = controller.load();

    expect(personCalls, 1);
    expect(itemCalls, 1);
    expect(controller.state.loadingPerson, isTrue);
    expect(controller.state.loadingFirstPage, isTrue);

    itemsResult.complete(
      EmbyItemPage(items: [_item('movie-1')], totalRecordCount: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.items.single.id, 'movie-1');
    expect(controller.state.loadingPerson, isTrue);

    personResult.complete(_person);
    await loading;
    expect(controller.state.person?.id, 'person-1');
    expect(controller.state.loadingPerson, isFalse);
  });

  test('pages beyond 60 raw results and deduplicates item IDs', () async {
    final starts = <int>[];
    final controller = PersonDetailController(
      personId: 'person-1',
      loadPerson: (_) async => _person,
      loadUserData: _emptyUserData,
      loadItems:
          ({
            required personId,
            startIndex = 0,
            limit = 60,
            filter = PersonMediaFilter.all,
          }) async {
            starts.add(startIndex);
            if (startIndex == 0) {
              return EmbyItemPage(
                items: [
                  for (var index = 0; index < 60; index++) _item('item-$index'),
                ],
                totalRecordCount: 61,
              );
            }
            return EmbyItemPage(
              items: [_item('item-59'), _item('item-60')],
              totalRecordCount: 61,
            );
          },
    );
    addTearDown(controller.dispose);

    await controller.load();
    await controller.loadMore();

    expect(starts, [0, 60]);
    expect(controller.state.items, hasLength(61));
    expect(controller.state.items.last.id, 'item-60');
    expect(controller.state.hasMore, isFalse);
  });

  test(
    'late result from an old filter cannot replace the active filter',
    () async {
      final movieResult = Completer<EmbyItemPage>();
      final seriesResult = Completer<EmbyItemPage>();
      final controller = PersonDetailController(
        personId: 'person-1',
        loadPerson: (_) async => _person,
        loadUserData: _emptyUserData,
        loadItems:
            ({
              required personId,
              startIndex = 0,
              limit = 60,
              filter = PersonMediaFilter.all,
            }) {
              return switch (filter) {
                PersonMediaFilter.all => Future.value(
                  EmbyItemPage(items: [_item('all-1')], totalRecordCount: 1),
                ),
                PersonMediaFilter.movie => movieResult.future,
                PersonMediaFilter.series => seriesResult.future,
              };
            },
      );
      addTearDown(controller.dispose);
      await controller.load();

      final movieLoad = controller.selectFilter(PersonMediaFilter.movie);
      final seriesLoad = controller.selectFilter(PersonMediaFilter.series);
      seriesResult.complete(
        EmbyItemPage(
          items: [_item('series-1', type: 'Series')],
          totalRecordCount: 1,
        ),
      );
      await seriesLoad;

      expect(controller.state.filter, PersonMediaFilter.series);
      expect(controller.state.items.single.id, 'series-1');

      movieResult.complete(
        EmbyItemPage(items: [_item('movie-1')], totalRecordCount: 1),
      );
      await movieLoad;
      expect(controller.state.filter, PersonMediaFilter.series);
      expect(controller.state.items.single.id, 'series-1');
    },
  );

  test(
    'next-page failure keeps items and retry resumes the same page',
    () async {
      final starts = <int>[];
      var nextPageAttempts = 0;
      final controller = PersonDetailController(
        personId: 'person-1',
        loadPerson: (_) async => _person,
        loadUserData: _emptyUserData,
        loadItems:
            ({
              required personId,
              startIndex = 0,
              limit = 60,
              filter = PersonMediaFilter.all,
            }) async {
              starts.add(startIndex);
              if (startIndex == 0) {
                return EmbyItemPage(
                  items: [
                    for (var index = 0; index < 60; index++)
                      _item('item-$index'),
                  ],
                  totalRecordCount: 61,
                );
              }
              nextPageAttempts++;
              if (nextPageAttempts == 1) throw StateError('page failed');
              return EmbyItemPage(
                items: [_item('item-60')],
                totalRecordCount: 61,
              );
            },
      );
      addTearDown(controller.dispose);

      await controller.load();
      await controller.loadMore();

      expect(controller.state.items, hasLength(60));
      expect(controller.state.itemsError, isA<StateError>());

      await controller.retryItems();
      expect(starts, [0, 60, 60]);
      expect(controller.state.items, hasLength(61));
      expect(controller.state.itemsError, isNull);
    },
  );

  test('first-page failure can retry without reloading the person', () async {
    var itemAttempts = 0;
    var personCalls = 0;
    final controller = PersonDetailController(
      personId: 'person-1',
      loadPerson: (_) async {
        personCalls++;
        return _person;
      },
      loadItems:
          ({
            required personId,
            startIndex = 0,
            limit = 60,
            filter = PersonMediaFilter.all,
          }) async {
            itemAttempts++;
            if (itemAttempts == 1) throw StateError('first page failed');
            return EmbyItemPage(items: [_item('movie-1')], totalRecordCount: 1);
          },
      loadUserData: _emptyUserData,
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.state.person, _person);
    expect(controller.state.items, isEmpty);
    expect(controller.state.itemsError, isA<StateError>());

    await controller.retryItems();
    expect(personCalls, 1);
    expect(itemAttempts, 2);
    expect(controller.state.items.single.id, 'movie-1');
    expect(controller.state.itemsError, isNull);
  });

  test(
    'refreshes one item user data without resetting person works state',
    () async {
      final starts = <int>[];
      final controller = PersonDetailController(
        personId: 'person-1',
        loadPerson: (_) async => _person,
        loadItems:
            ({
              required personId,
              startIndex = 0,
              limit = 60,
              filter = PersonMediaFilter.all,
            }) async {
              starts.add(startIndex);
              return EmbyItemPage(
                items: startIndex == 0
                    ? [
                        for (var index = 0; index < 60; index++)
                          _item('movie-$index'),
                      ]
                    : [_item('movie-60')],
                totalRecordCount: 61,
              );
            },
        loadUserData: (ids) async => {
          'movie-1': const EmbyUserData(
            playbackPositionTicks: 7200000000,
            playedPercentage: 75,
            isPlayed: true,
            isFavorite: true,
            unplayedItemCount: 4,
          ),
        },
      );
      addTearDown(controller.dispose);
      await controller.load();

      await controller.refreshItemUserData('movie-1');
      await controller.loadMore();

      expect(controller.state.filter, PersonMediaFilter.all);
      expect(controller.state.totalRecordCount, 61);
      expect(controller.state.items, hasLength(61));
      expect(starts, [0, 60]);
      expect(
        controller.state.items[1].userData.playbackPositionTicks,
        7200000000,
      );
      expect(controller.state.items[1].userData.playedPercentage, 75);
      expect(controller.state.items[1].userData.isPlayed, isTrue);
      expect(controller.state.items[1].userData.isFavorite, isTrue);
      expect(controller.state.items[1].userData.unplayedItemCount, 4);
      expect(controller.state.items.first.userData.isPlayed, isFalse);
      expect(controller.state.items.last.id, 'movie-60');
    },
  );

  test('old user data refresh cannot write into a new filter result', () async {
    final refreshResult = Completer<Map<String, EmbyUserData>>();
    final controller = PersonDetailController(
      personId: 'person-1',
      loadPerson: (_) async => _person,
      loadItems:
          ({
            required personId,
            startIndex = 0,
            limit = 60,
            filter = PersonMediaFilter.all,
          }) async => EmbyItemPage(
            items: [
              _item(
                'shared-item',
                type: filter == PersonMediaFilter.movie ? 'Movie' : 'Series',
                userData: EmbyUserData(
                  isFavorite: filter == PersonMediaFilter.movie,
                ),
              ),
            ],
            totalRecordCount: 1,
          ),
      loadUserData: (_) => refreshResult.future,
    );
    addTearDown(controller.dispose);
    await controller.load();

    final refresh = controller.refreshItemUserData('shared-item');
    await controller.selectFilter(PersonMediaFilter.movie);
    refreshResult.complete({'shared-item': const EmbyUserData(isPlayed: true)});
    await refresh;

    expect(controller.state.filter, PersonMediaFilter.movie);
    expect(controller.state.items.single.userData.isFavorite, isTrue);
    expect(controller.state.items.single.userData.isPlayed, isFalse);
  });

  test('late requests do not notify listeners after disposal', () async {
    final personResult = Completer<EmbyItem>();
    final itemsResult = Completer<EmbyItemPage>();
    final controller = PersonDetailController(
      personId: 'person-1',
      loadPerson: (_) => personResult.future,
      loadUserData: _emptyUserData,
      loadItems:
          ({
            required personId,
            startIndex = 0,
            limit = 60,
            filter = PersonMediaFilter.all,
          }) => itemsResult.future,
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final loading = controller.load();
    expect(notifications, 1);
    controller.dispose();
    personResult.complete(_person);
    itemsResult.complete(const EmbyItemPage(items: [], totalRecordCount: 0));
    await loading;

    expect(notifications, 1);
  });
}

const _person = EmbyItem(
  id: 'person-1',
  name: '演员一',
  type: 'Person',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

EmbyItem _item(
  String id, {
  String type = 'Movie',
  EmbyUserData userData = const EmbyUserData(),
}) => EmbyItem(
  id: id,
  name: id,
  type: type,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: userData,
);

Future<Map<String, EmbyUserData>> _emptyUserData(Iterable<String> _) async =>
    const {};
