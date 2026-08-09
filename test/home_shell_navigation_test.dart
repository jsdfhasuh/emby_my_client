import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_content_profile.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/home_shell.dart';
import 'package:emby_my_client/ui/settings_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shared_preferences_async_test_backend.dart';

void main() {
  testWidgets('large-screen routes return through the owning HomeShell', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = SharedPreferencesAsyncTestBackend.install();
      addTearDown(preferences.restore);
      final api = _ShellApi();
      final controller = _ShellController(api);
      addTearDown(controller.dispose);
      addTearDown(api.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: HomeShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(_selectedShellTab(tester), 0);

      await _openLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('large-screen-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(
        tester.widget<SettingsScreen>(find.byType(SettingsScreen)).accountName,
        'tester',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_selectedShellTab(tester), 1);

      await _openCurrentLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('large-screen-account')));
      await tester.pumpAndSettle();
      expect(find.text('Test Server'), findsOneWidget);
      expect(find.text('诊断日志'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(_selectedShellTab(tester), 1);

      await _openCurrentLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('large-screen-home')));
      await tester.pumpAndSettle();
      expect(_selectedShellTab(tester), 0);

      await _openLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('large-screen-search')));
      await tester.pumpAndSettle();
      expect(_selectedShellTab(tester), 2);
      expect(find.widgetWithText(AppBar, '搜索'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

int _selectedShellTab(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

Future<void> _openLibrary(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(Icons.video_library_outlined),
    ),
  );
  await tester.pumpAndSettle();
  expect(_selectedShellTab(tester), 1);
  await _openCurrentLibrary(tester);
}

Future<void> _openCurrentLibrary(WidgetTester tester) async {
  await tester.tap(find.text('Test Library').hitTestable());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('large-screen-home')), findsOneWidget);
}

class _ShellController extends AppController {
  _ShellController(this._shellApi)
    : super(
        capabilities: PlatformCapabilities.ipad,
        libraryCategorySettingsStore: MemoryLibraryCategorySettingsStore(),
      );

  final EmbyApi _shellApi;

  @override
  EmbyApi get api => _shellApi;

  @override
  EmbySession? get session => _session;
}

class _ShellApi extends EmbyApi {
  _ShellApi() : super(_session, dio: Dio());

  @override
  Future<HomeData> getHomeBase() async =>
      const HomeData(views: [_library], resume: [], latestSections: []);

  @override
  Future<HomeLatestSection?> getHomeLatestSection(EmbyItem library) async =>
      null;

  @override
  Future<List<EmbyItem>> getViews() async => const [_library];

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
  }) async =>
      const EmbyItemPage(items: [_movie], rawItemCount: 1, totalRecordCount: 1);
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Server',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _library = EmbyItem(
  id: 'library-1',
  name: 'Test Library',
  type: 'CollectionFolder',
  collectionType: 'movies',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _movie = EmbyItem(
  id: 'movie-1',
  name: 'Test Movie',
  type: 'Movie',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
