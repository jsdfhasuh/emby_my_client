import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/settings/library_sort_preferences.dart';

import 'shared_preferences_async_test_backend.dart';

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondUserScope = ServerScope(serverId: 'server-1', userId: 'user-2');
const _secondServerScope = ServerScope(serverId: 'server-2', userId: 'user-1');
const _libraryA = 'library-a';
const _libraryB = 'library-b';
const _playCountDescending = LibrarySortPreference(
  sortBy: LibrarySortBy.playCount,
  sortOrder: LibrarySortOrder.descending,
);
const _dateAddedAscending = LibrarySortPreference(
  sortBy: LibrarySortBy.dateAdded,
  sortOrder: LibrarySortOrder.ascending,
);

void main() {
  late SharedPreferencesAsyncTestBackend backend;

  setUp(() {
    backend = SharedPreferencesAsyncTestBackend.install();
  });

  tearDown(() {
    backend.restore();
  });

  test('saves and loads a preference for the same scope and library', () async {
    final store = SharedPreferencesLibrarySortPreferenceStore(
      preferences: backend.preferences,
    );

    await store.save(_firstScope, _libraryA, _playCountDescending);

    expect(await store.load(_firstScope, _libraryA), _playCountDescending);
  });

  test('round trips both sort fields', () async {
    final store = MemoryLibrarySortPreferenceStore();

    await store.save(_firstScope, _libraryA, _dateAddedAscending);

    final value = await store.load(_firstScope, _libraryA);
    expect(value?.sortBy, LibrarySortBy.dateAdded);
    expect(value?.sortOrder, LibrarySortOrder.ascending);
  });

  test('does not persist the default name ascending preference', () async {
    final store = SharedPreferencesLibrarySortPreferenceStore(
      preferences: backend.preferences,
    );

    await store.save(_firstScope, _libraryA, defaultLibrarySortPreference);

    expect(await store.load(_firstScope, _libraryA), isNull);
    expect(await backend.preferences.getString(_key(_firstScope)), isNull);
  });

  test('clearLibrary only removes the selected library', () async {
    final store = MemoryLibrarySortPreferenceStore();
    await store.save(_firstScope, _libraryA, _playCountDescending);
    await store.save(_firstScope, _libraryB, _dateAddedAscending);

    await store.clearLibrary(_firstScope, _libraryA);

    expect(await store.load(_firstScope, _libraryA), isNull);
    expect(await store.load(_firstScope, _libraryB), _dateAddedAscending);
  });

  test('clear removes every library for the selected scope', () async {
    final store = MemoryLibrarySortPreferenceStore();
    await store.save(_firstScope, _libraryA, _playCountDescending);
    await store.save(_firstScope, _libraryB, _dateAddedAscending);

    await store.clear(_firstScope);

    expect(await store.load(_firstScope, _libraryA), isNull);
    expect(await store.load(_firstScope, _libraryB), isNull);
  });

  test('different library IDs remain isolated', () async {
    final store = MemoryLibrarySortPreferenceStore();

    await store.save(_firstScope, _libraryA, _playCountDescending);

    expect(await store.load(_firstScope, _libraryB), isNull);
  });

  test('different servers remain isolated', () async {
    final store = MemoryLibrarySortPreferenceStore();

    await store.save(_firstScope, _libraryA, _playCountDescending);

    expect(await store.load(_secondServerScope, _libraryA), isNull);
  });

  test('different users on one server remain isolated', () async {
    final store = MemoryLibrarySortPreferenceStore();

    await store.save(_firstScope, _libraryA, _playCountDescending);

    expect(await store.load(_secondUserScope, _libraryA), isNull);
  });

  test('corrupt JSON safely falls back to no preference', () async {
    final backend = SharedPreferencesAsyncTestBackend.install(
      initialValues: {_key(_firstScope): '{not-json'},
    );
    addTearDown(backend.restore);
    final store = SharedPreferencesLibrarySortPreferenceStore(
      preferences: backend.preferences,
    );

    expect(await store.load(_firstScope, _libraryA), isNull);
  });

  test('unknown sortBy safely ignores the entry', () async {
    final backend = SharedPreferencesAsyncTestBackend.install(
      initialValues: {
        _key(_firstScope): jsonEncode({
          _libraryA: {'sortBy': 'unknown', 'sortOrder': 'descending'},
        }),
      },
    );
    addTearDown(backend.restore);
    final store = SharedPreferencesLibrarySortPreferenceStore(
      preferences: backend.preferences,
    );

    expect(await store.load(_firstScope, _libraryA), isNull);
  });

  test('unknown sortOrder safely ignores the entry', () async {
    final backend = SharedPreferencesAsyncTestBackend.install(
      initialValues: {
        _key(_firstScope): jsonEncode({
          _libraryA: {'sortBy': 'playCount', 'sortOrder': 'unknown'},
        }),
      },
    );
    addTearDown(backend.restore);
    final store = SharedPreferencesLibrarySortPreferenceStore(
      preferences: backend.preferences,
    );

    expect(await store.load(_firstScope, _libraryA), isNull);
  });

  test('a damaged entry does not hide a valid entry', () async {
    final backend = SharedPreferencesAsyncTestBackend.install(
      initialValues: {
        _key(_firstScope): jsonEncode({
          _libraryA: {'sortBy': 'broken', 'sortOrder': 'descending'},
          _libraryB: _dateAddedAscending.toJson(),
        }),
      },
    );
    addTearDown(backend.restore);
    final store = SharedPreferencesLibrarySortPreferenceStore(
      preferences: backend.preferences,
    );

    expect(await store.load(_firstScope, _libraryA), isNull);
    expect(await store.load(_firstScope, _libraryB), _dateAddedAscending);
  });

  test('rapid saves leave the last value', () async {
    final store = MemoryLibrarySortPreferenceStore();

    await Future.wait([
      store.save(_firstScope, _libraryA, _playCountDescending),
      store.save(_firstScope, _libraryA, _dateAddedAscending),
      store.save(_firstScope, _libraryA, _playCountDescending),
    ]);

    expect(await store.load(_firstScope, _libraryA), _playCountDescending);
  });

  test('load after save observes the new value', () async {
    final store = MemoryLibrarySortPreferenceStore();

    final save = store.save(_firstScope, _libraryA, _playCountDescending);
    final load = store.load(_firstScope, _libraryA);

    await save;
    expect(await load, _playCountDescending);
  });

  test('clear after save prevents the old value from reappearing', () async {
    final store = MemoryLibrarySortPreferenceStore();

    final save = store.save(_firstScope, _libraryA, _playCountDescending);
    final clear = store.clearLibrary(_firstScope, _libraryA);

    await Future.wait([save, clear]);

    expect(await store.load(_firstScope, _libraryA), isNull);
  });

  test('empty library IDs are rejected for save', () async {
    final store = MemoryLibrarySortPreferenceStore();

    await expectLater(
      store.save(_firstScope, '  ', _playCountDescending),
      throwsArgumentError,
    );
  });

  test(
    'memory and SharedPreferences stores have the same lifecycle semantics',
    () async {
      final memory = MemoryLibrarySortPreferenceStore();
      final shared = SharedPreferencesLibrarySortPreferenceStore(
        preferences: backend.preferences,
      );

      for (final store in <LibrarySortPreferenceStore>[memory, shared]) {
        await store.save(_firstScope, _libraryA, _playCountDescending);
        expect(await store.load(_firstScope, _libraryA), _playCountDescending);
        await store.clearLibrary(_firstScope, _libraryA);
        expect(await store.load(_firstScope, _libraryA), isNull);
      }
    },
  );
}

String _key(ServerScope scope) =>
    'library.${scope.databaseKey}.sort_preferences.v1';
