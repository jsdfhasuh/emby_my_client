import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('known-total empty page retries from its unchanged raw cursor', (
    tester,
  ) async {
    final lines = <String>[];
    DiagnosticLog.instance.setTestSink(lines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    var stalledAttempts = 0;
    final api = _ScriptedLibraryApi((startIndex) async {
      if (startIndex == 0) {
        return const EmbyItemPage(
          items: [],
          rawItemCount: 60,
          totalRecordCount: 61,
        );
      }
      stalledAttempts++;
      return stalledAttempts == 1
          ? const EmbyItemPage(items: [], rawItemCount: 0, totalRecordCount: 61)
          : EmbyItemPage(
              items: [_video('recovered-item')],
              rawItemCount: 1,
              totalRecordCount: 61,
            );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.starts, [0, 60]);
    expect(find.byKey(const ValueKey('library-load-error')), findsOneWidget);
    expect(
      lines.any(
        (line) => line.contains('Library pagination stalled scope=media'),
      ),
      isTrue,
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('library-load-error')),
        matching: find.text('重试'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.starts, [0, 60, 60]);
    expect(
      find.byKey(const ValueKey('library-item-recovered-item')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library-load-error')), findsNothing);
    await _dispose(tester, api);
  });

  testWidgets('changed totals become dirty and disable complete playback', (
    tester,
  ) async {
    final api = _ScriptedLibraryApi((startIndex) async {
      if (startIndex == 0) {
        return EmbyItemPage(
          items: [
            for (var index = 0; index < 60; index++) _video('item-$index'),
          ],
          rawItemCount: 60,
          totalRecordCount: 120,
        );
      }
      return EmbyItemPage(
        items: [_video('item-60')],
        rawItemCount: 1,
        totalRecordCount: 121,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-item-item-55')),
      700,
      scrollable: _verticalScrollable(),
    );
    await tester.pumpAndSettle();

    expect(api.starts, containsAllInOrder([0, 60]));
    tester.state<ScrollableState>(_verticalScrollable()).position.jumpTo(0);
    await tester.pumpAndSettle();
    final summary = tester.widget<Text>(
      find.byKey(const ValueKey('library-result-summary')),
    );
    expect(summary.data, contains('结果已变化，请刷新统计'));
    final playButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('library-play-all-button')),
    );
    expect(playButton.onPressed, isNull);
    await _dispose(tester, api);
  });

  testWidgets('total below loaded emits only safe aggregate diagnostics', (
    tester,
  ) async {
    final lines = <String>[];
    DiagnosticLog.instance.setTestSink(lines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final api = _ScriptedLibraryApi(
      (_) async => EmbyItemPage(
        items: [_video('private-title-a'), _video('private-title-b')],
        rawItemCount: 2,
        totalRecordCount: 1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowseScreen.root(api: api, view: _library),
      ),
    );
    await tester.pumpAndSettle();

    final warning = lines.singleWhere(
      (line) => line.contains('Library total below loaded count'),
    );
    expect(warning, contains('scope=media total=1 loaded=2'));
    expect(warning, isNot(contains('private-title')));
    expect(find.text('共 2 项'), findsOneWidget);
    await _dispose(tester, api);
  });
}

typedef _PageScript = Future<EmbyItemPage> Function(int startIndex);

class _ScriptedLibraryApi extends EmbyApi {
  _ScriptedLibraryApi(this.script) : super(_session, dio: Dio());

  final _PageScript script;
  final List<int> starts = [];

  @override
  Future<EmbyItemPage> getLibraryMediaItems({
    required String parentId,
    LibraryContentProfile profile = LibraryContentProfile.unknown,
    int startIndex = 0,
    int limit = 60,
    LibraryMediaType mediaType = LibraryMediaType.all,
    LibraryPlayedFilter playedFilter = LibraryPlayedFilter.all,
    bool favorites = false,
    LibrarySortBy sortBy = LibrarySortBy.name,
    LibrarySortOrder sortOrder = LibrarySortOrder.ascending,
    LibraryAlphabetFilter alphabetFilter = const AllItems(),
    String? genreId,
    String? tagId,
  }) {
    starts.add(startIndex);
    return script(startIndex);
  }
}

EmbyItem _video(String id) => EmbyItem(
  id: id,
  name: id,
  type: 'Movie',
  mediaType: 'Video',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: const EmbyUserData(),
);

Future<void> _dispose(WidgetTester tester, EmbyApi api) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await api.dispose();
}

Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

const _library = EmbyItem(
  id: 'library-1',
  name: 'Test library',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
