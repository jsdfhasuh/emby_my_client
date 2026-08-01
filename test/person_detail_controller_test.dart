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

  test('late requests do not notify listeners after disposal', () async {
    final personResult = Completer<EmbyItem>();
    final itemsResult = Completer<EmbyItemPage>();
    final controller = PersonDetailController(
      personId: 'person-1',
      loadPerson: (_) => personResult.future,
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

EmbyItem _item(String id, {String type = 'Movie'}) => EmbyItem(
  id: id,
  name: id,
  type: type,
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);
