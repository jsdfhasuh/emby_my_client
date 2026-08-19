import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/home_shell_navigation.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewports = [
    Size(390, 844),
    Size(844, 390),
    Size(768, 1024),
    Size(1024, 768),
    Size(1366, 1024),
  ];
  const textScales = [1.0, 1.3, 2.0];

  for (final viewport in viewports) {
    for (final textScale in textScales) {
      testWidgets(
        'real genre ActionChips fit ${viewport.width}x${viewport.height} at ${textScale}x',
        (tester) async {
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final api = _GenreLayoutApi(_layoutItem);
          addTearDown(api.dispose);
          final pending = Completer<void>();
          var callCount = 0;

          Future<void> openGenre(
            BuildContext context,
            EmbyItem item,
            String genre,
            _,
            _,
          ) async {
            callCount++;
            await pending.future;
          }

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: ItemDetailScreen(
                api: api,
                initialItem: _layoutItem,
                navigationActions: HomeShellNavigationActions(
                  showHome: () {},
                  showSearch: () {},
                  openSettings: () async {},
                  openAccount: () async {},
                  openGenre: openGenre,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final chipKeys = [
            const ValueKey<String>('item-detail-genre-0'),
            const ValueKey<String>('item-detail-genre-1'),
            const ValueKey<String>('item-detail-genre-2'),
          ];
          final labels = [
            '查看“${_layoutItem.genres[0]}”分类',
            '查看“${_layoutItem.genres[1]}”分类',
            '查看“${_layoutItem.genres[2]}”分类',
          ];

          expect(find.byType(ActionChip), findsNWidgets(3));
          for (final label in labels) {
            expect(find.bySemanticsLabel(label), findsOneWidget);
          }
          for (final key in chipKeys) {
            await _scrollToChip(tester, find.byKey(key));
          }
          expect(tester.takeException(), isNull);

          final firstChip = find.byKey(chipKeys.first);
          await _scrollToChip(tester, firstChip);
          await tester.tap(firstChip);
          await tester.pump();

          expect(callCount, 1);
          expect(
            find.descendant(
              of: firstChip,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          for (final key in chipKeys.skip(1)) {
            await _scrollToChip(tester, find.byKey(key));
          }
          expect(tester.takeException(), isNull);

          pending.complete();
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: firstChip,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsNothing,
          );
          expect(tester.widget<ActionChip>(firstChip).onPressed, isNotNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

Future<void> _scrollToChip(WidgetTester tester, Finder chip) async {
  await tester.scrollUntilVisible(
    chip,
    420,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

class _GenreLayoutApi extends EmbyApi {
  _GenreLayoutApi(this.item) : super(_session, dio: Dio());

  final EmbyItem item;

  @override
  Future<EmbyItem> getItem(String itemId) async => item;
}

const _layoutItem = EmbyItem(
  id: 'layout-media',
  name: '用于布局矩阵的媒体详情',
  type: 'Movie',
  imageTags: {},
  backdropImageTags: [],
  genres: [
    'Sci-Fi & Fantasy',
    'Action & Adventure',
    '非常长的中文分类名称用于验证自动换行与大字体布局',
  ],
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
