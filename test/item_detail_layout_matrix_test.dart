import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewports = [
    Size(1024, 768),
    Size(768, 1024),
    Size(1366, 1024),
    Size(390, 844),
  ];
  const textScales = [1.0, 1.3, 2.0];

  for (final viewport in viewports) {
    for (final textScale in textScales) {
      for (final artwork in _ArtworkCase.values) {
        testWidgets(
          '${artwork.label} detail fits ${viewport.width}x${viewport.height} at ${textScale}x text',
          (tester) async {
            _setViewport(tester, viewport);
            final item = EmbyItem.fromJson(_detailItemJson(artwork));
            final api = _detailApi(item);

            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData.dark(useMaterial3: true),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: ItemDetailScreen(api: api, initialItem: item),
              ),
            );
            await tester.pumpAndSettle();

            final expectedHeroHeight = detailHeroHeightForViewport(viewport);
            final appBar = tester.widget<SliverAppBar>(
              find.byType(SliverAppBar),
            );
            expect(appBar.expandedHeight, expectedHeroHeight);
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('item-detail-hero')))
                  .height,
              closeTo(expectedHeroHeight, 1),
            );
            _expectArtwork(tester, artwork);
            expect(tester.takeException(), isNull);

            await _dragUntilHitTestable(tester, find.text('简介'), viewport);
            expect(find.text('简介').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);

            final cast = find.byKey(const ValueKey('cast-link-person-1'));
            await _dragUntilHitTestable(tester, cast, viewport);
            expect(cast.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);

            await tester.pumpWidget(const SizedBox.shrink());
            await api.dispose();
          },
        );
      }
    }
  }

  testWidgets('detail load failure shows fixed text and writes redacted log', (
    tester,
  ) async {
    final logLines = <String>[];
    DiagnosticLog.instance.setTestSink(logLines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final api = _FailingDetailApi();

    await tester.pumpWidget(
      MaterialApp(
        home: ItemDetailScreen(api: api, initialItem: _initialItem),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('详情加载失败，请重试'), findsOneWidget);
    expect(find.textContaining('detail-secret'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    final log = logLines.join('\n');
    expect(log, contains('Item detail initial load failed'));
    expect(log, contains('password=<redacted>'));
    expect(log, isNot(contains('detail-secret')));
    expect(log, isNot(contains('private.example.test')));

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('detail action failure uses fixed snackbar and diagnostic log', (
    tester,
  ) async {
    final logLines = <String>[];
    DiagnosticLog.instance.setTestSink(logLines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final item = EmbyItem.fromJson(_detailItemJson(_ArtworkCase.none));
    final api = _favoriteFailureApi(item);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ItemDetailScreen(api: api, initialItem: item),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();

    expect(find.text('状态更新失败，请重试'), findsOneWidget);
    expect(find.textContaining('action-secret'), findsNothing);
    expect(find.textContaining('DioException'), findsNothing);
    final log = logLines.join('\n');
    expect(log, contains('Item detail user data update failed'));
    expect(log, isNot(contains('action-secret')));

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });
}

void _setViewport(WidgetTester tester, Size viewport) {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _dragUntilHitTestable(
  WidgetTester tester,
  Finder target,
  Size viewport,
) async {
  final scrollView = find.byType(CustomScrollView);
  for (var attempt = 0; attempt < 20; attempt++) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    await tester.drag(scrollView, Offset(0, -viewport.height * 0.42));
    await tester.pumpAndSettle();
  }
}

void _expectArtwork(WidgetTester tester, _ArtworkCase artwork) {
  final underlay = find.byKey(const ValueKey('item-detail-backdrop-underlay'));
  expect(underlay, findsOneWidget);
  final underlayImage = find.descendant(
    of: underlay,
    matching: find.byType(EmbyImage),
  );

  switch (artwork) {
    case _ArtworkCase.backdrop:
      expect(underlayImage, findsOneWidget);
      expect(tester.widget<EmbyImage>(underlayImage).fit, BoxFit.cover);
      final foreground = find.byKey(
        const ValueKey('item-detail-backdrop-foreground'),
      );
      expect(foreground, findsOneWidget);
      expect(tester.widget<EmbyImage>(foreground).fit, BoxFit.contain);
      expect(
        find.byKey(const ValueKey('item-detail-primary-fallback')),
        findsNothing,
      );
    case _ArtworkCase.primary:
      expect(underlayImage, findsOneWidget);
      expect(tester.widget<EmbyImage>(underlayImage).fit, BoxFit.cover);
      final foreground = find.byKey(
        const ValueKey('item-detail-primary-fallback'),
      );
      expect(foreground, findsOneWidget);
      expect(tester.widget<EmbyImage>(foreground).fit, BoxFit.contain);
      expect(
        find.byKey(const ValueKey('item-detail-backdrop-foreground')),
        findsNothing,
      );
    case _ArtworkCase.none:
      expect(underlayImage, findsNothing);
      expect(
        find.byKey(const ValueKey('item-detail-backdrop-foreground')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('item-detail-primary-fallback')),
          matching: find.byIcon(Icons.movie_outlined),
        ),
        findsOneWidget,
      );
  }
}

EmbyApi _detailApi(EmbyItem item) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _detailItemJson(_artworkCaseFor(item)),
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

EmbyApi _favoriteFailureApi(EmbyItem item) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('/FavoriteItems/')) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 500,
                  data: const {'password': 'action-secret'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _detailItemJson(_artworkCaseFor(item)),
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

_ArtworkCase _artworkCaseFor(EmbyItem item) {
  if (item.backdropImageTags.isNotEmpty) return _ArtworkCase.backdrop;
  if (item.imageTags['Primary']?.isNotEmpty ?? false) {
    return _ArtworkCase.primary;
  }
  return _ArtworkCase.none;
}

Map<String, dynamic> _detailItemJson(_ArtworkCase artwork) => {
  'Id': 'media-1',
  'Name': '响应式详情页中的较长媒体标题用于验证换行行为',
  'Type': 'Movie',
  'MediaType': 'Video',
  'ProductionYear': 2026,
  'RunTimeTicks': 72000000000,
  'OfficialRating': 'PG-13',
  'CommunityRating': 8.4,
  'Overview': List.filled(8, '这是一段用于验证详情页真实滚动、长文本排版和大文字模式的简介内容。').join(),
  'People': const [
    {'Id': 'person-1', 'Name': '测试演员', 'Type': 'Actor', 'Role': '主要角色'},
  ],
  'ImageTags': switch (artwork) {
    _ArtworkCase.backdrop ||
    _ArtworkCase.primary => const {'Primary': 'primary-tag'},
    _ArtworkCase.none => const <String, String>{},
  },
  'BackdropImageTags': switch (artwork) {
    _ArtworkCase.backdrop => const ['backdrop-tag'],
    _ArtworkCase.primary || _ArtworkCase.none => const <String>[],
  },
  'Genres': const ['剧情', '科幻', '悬疑'],
  'UserData': const <String, dynamic>{},
};

class _FailingDetailApi extends EmbyApi {
  _FailingDetailApi() : super(_session, dio: Dio());

  @override
  Future<EmbyItem> getItem(String itemId) => Future.error(
    StateError(
      'password=detail-secret serverUrl=https://private.example.test/item',
    ),
  );
}

enum _ArtworkCase { backdrop, primary, none }

extension on _ArtworkCase {
  String get label => switch (this) {
    _ArtworkCase.backdrop => 'backdrop',
    _ArtworkCase.primary => 'primary fallback',
    _ArtworkCase.none => 'no-image',
  };
}

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _initialItem = EmbyItem(
  id: 'media-1',
  name: '媒体详情',
  type: 'Movie',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
