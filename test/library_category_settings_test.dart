import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/settings/library_category_settings.dart';
import 'package:emby_my_client/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('library category settings are isolated by server scope', () async {
    final store = MemoryLibraryCategorySettingsStore();

    expect(await store.load(_firstScope), const LibraryCategorySettings());
    await store.save(
      _firstScope,
      const LibraryCategorySettings(showMovies: true, showFolders: false),
    );

    expect((await store.load(_firstScope)).showMovies, isTrue);
    expect((await store.load(_firstScope)).showFolders, isFalse);
    expect(await store.load(_secondScope), const LibraryCategorySettings());
  });

  testWidgets('settings screen updates a media library category', (
    tester,
  ) async {
    final changes = <LibraryCategorySettings>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsScreen(
          settings: const LibraryCategorySettings(),
          accountName: 'tester',
          onLibraryCategorySettingsChanged: (settings) async {
            changes.add(settings);
          },
          onDeleteAccountData: () async {},
        ),
      ),
    );

    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '电影'))
          .value,
      isFalse,
    );

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();

    expect(changes.single.showMovies, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '电影'))
          .value,
      isTrue,
    );
  });

  testWidgets('account data deletion requires explicit confirmation', (
    tester,
  ) async {
    var deleteCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsScreen(
          settings: const LibraryCategorySettings(),
          accountName: 'tester',
          onLibraryCategorySettingsChanged: (_) async {},
          onDeleteAccountData: () async {
            deleteCalls++;
          },
        ),
      ),
    );

    await tester.tap(find.text('删除此账户数据'));
    await tester.pumpAndSettle();
    expect(find.text('删除此账户数据？'), findsOneWidget);
    expect(find.textContaining('tester'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 0);

    await tester.tap(find.text('删除此账户数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除并退出'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
  });
}

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');
