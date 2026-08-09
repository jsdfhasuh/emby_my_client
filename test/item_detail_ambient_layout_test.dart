import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/ui/home_shell_navigation.dart';
import 'package:emby_my_client/ui/item_detail_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const landscapeViewports = [Size(1024, 768), Size(1366, 1024)];
  const textScales = [1.0, 1.3, 2.0];

  for (final viewport in landscapeViewports) {
    for (final textScale in textScales) {
      for (final artwork in _ArtworkCase.values) {
        testWidgets('iPad ambient ${artwork.label} fits '
            '${viewport.width}x${viewport.height} at ${textScale}x text', (
          tester,
        ) async {
          final api = await _pumpDetail(
            tester,
            viewport: viewport,
            textScale: textScale,
            artwork: artwork,
            capabilities: PlatformCapabilities.ipad,
          );

          expect(
            find.byKey(const ValueKey('item-detail-ambient-layout')),
            findsOneWidget,
          );
          expect(find.byType(DetailHeroArtwork), findsNothing);
          expect(find.byType(SliverAppBar), findsNothing);
          expect(find.byType(LargeScreenPageChrome), findsOneWidget);
          expect(find.byType(AppBar), findsOneWidget);
          expect(
            find.byKey(const ValueKey('item-detail-title')).hitTestable(),
            findsOneWidget,
          );
          expect(find.text('继续播放').hitTestable(), findsOneWidget);
          _expectAmbientArtwork(tester, artwork);
          expect(tester.takeException(), isNull);

          final cast = find.byKey(const ValueKey('cast-link-person-1'));
          await _dragUntilHitTestable(tester, cast, viewport);
          expect(cast.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);

          final overview = find.text('简介');
          await _dragUntilHitTestable(tester, overview, viewport);
          expect(overview.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await api.dispose();
        });
      }
    }
  }

  testWidgets('ambient detail shows deterministic finish and media facts', (
    tester,
  ) async {
    final api = await _pumpDetail(
      tester,
      viewport: const Size(1024, 768),
      textScale: 1,
      artwork: _ArtworkCase.backdrop,
      capabilities: PlatformCapabilities.ipad,
    );

    expect(
      find.byKey(const ValueKey('item-detail-estimated-finish')),
      findsOneWidget,
    );
    expect(find.text('预计 11:30 结束'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('item-detail-technical-info')),
      findsOneWidget,
    );
    for (final fact in const [
      '主版本',
      'MKV',
      'H264 · 1920×1080',
      'EAC3 · 5.1 · zho',
      '8.5 Mbps',
    ]) {
      expect(find.text(fact), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('ambient detail omits cast section when cast is absent', (
    tester,
  ) async {
    final api = await _pumpDetail(
      tester,
      viewport: const Size(1024, 768),
      textScale: 1,
      artwork: _ArtworkCase.none,
      capabilities: PlatformCapabilities.ipad,
      includeCast: false,
    );

    expect(find.text('演员'), findsNothing);
    expect(find.byKey(const Key('cast-list')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('iPad portrait keeps the compact detail layout', (tester) async {
    final api = await _pumpDetail(
      tester,
      viewport: const Size(768, 1024),
      textScale: 1,
      artwork: _ArtworkCase.backdrop,
      capabilities: PlatformCapabilities.ipad,
    );

    expect(
      find.byKey(const ValueKey('item-detail-ambient-layout')),
      findsNothing,
    );
    expect(find.byType(DetailHeroArtwork), findsOneWidget);
    expect(find.byType(SliverAppBar), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('Android landscape keeps the compact detail layout', (
    tester,
  ) async {
    final api = await _pumpDetail(
      tester,
      viewport: const Size(1024, 768),
      textScale: 1,
      artwork: _ArtworkCase.primary,
      capabilities: PlatformCapabilities.android,
    );

    expect(
      find.byKey(const ValueKey('item-detail-ambient-layout')),
      findsNothing,
    );
    expect(find.byType(DetailHeroArtwork), findsOneWidget);
    expect(find.byType(SliverAppBar), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });
}

Future<EmbyApi> _pumpDetail(
  WidgetTester tester, {
  required Size viewport,
  required double textScale,
  required _ArtworkCase artwork,
  required PlatformCapabilities capabilities,
  bool includeCast = true,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final json = _detailItemJson(artwork, includeCast: includeCast);
  final item = EmbyItem.fromJson(json);
  final api = _detailApi(json);
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
        initialItem: item,
        navigationActions: _navigationActions,
        platformCapabilities: capabilities,
        now: () => DateTime.utc(2026, 8, 9, 10),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> _dragUntilHitTestable(
  WidgetTester tester,
  Finder target,
  Size viewport,
) async {
  final scrollView = find.byKey(const ValueKey('item-detail-ambient-scroll'));
  for (var attempt = 0; attempt < 20; attempt++) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    await tester.drag(scrollView, Offset(0, -viewport.height * 0.4));
    await tester.pumpAndSettle();
  }
}

void _expectAmbientArtwork(WidgetTester tester, _ArtworkCase artwork) {
  final background = find.byKey(
    const ValueKey('item-detail-ambient-background-image'),
  );
  final fallback = find.byKey(
    const ValueKey('item-detail-ambient-background-fallback'),
  );
  final poster = find.byKey(const ValueKey('item-detail-ambient-poster'));

  expect(tester.widget<EmbyImage>(poster).fit, BoxFit.contain);
  switch (artwork) {
    case _ArtworkCase.backdrop:
      expect(background, findsOneWidget);
      expect(fallback, findsNothing);
      final image = tester.widget<EmbyImage>(background);
      expect(image.fit, BoxFit.cover);
      expect(image.request?.uri.path, endsWith('/Images/Backdrop'));
    case _ArtworkCase.primary:
      expect(background, findsOneWidget);
      expect(fallback, findsNothing);
      final image = tester.widget<EmbyImage>(background);
      expect(image.fit, BoxFit.cover);
      expect(image.request?.uri.path, contains('/Images/Primary'));
    case _ArtworkCase.none:
      expect(background, findsNothing);
      expect(fallback, findsOneWidget);
      expect(tester.widget<EmbyImage>(poster).request, isNull);
  }
}

EmbyApi _detailApi(Map<String, dynamic> itemJson) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: itemJson,
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

Map<String, dynamic> _detailItemJson(
  _ArtworkCase artwork, {
  required bool includeCast,
}) => {
  'Id': 'media-1',
  'Name': 'iPad 横屏环境式详情页中的较长媒体标题用于验证换行行为',
  'Type': 'Movie',
  'MediaType': 'Video',
  'ProductionYear': 2026,
  'RunTimeTicks': 72000000000,
  'OfficialRating': 'PG-13',
  'CommunityRating': 8.4,
  'Overview': List.filled(10, '这是一段用于验证环境式详情页真实滚动、长文本排版和大文字模式的简介内容。').join(),
  'People': includeCast
      ? const [
          {'Id': 'person-1', 'Name': '测试演员一', 'Type': 'Actor', 'Role': '主要角色'},
          {'Id': 'person-2', 'Name': '测试演员二', 'Type': 'Actor', 'Role': '联合主演'},
        ]
      : const <Map<String, dynamic>>[],
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
  'UserData': const {'PlaybackPositionTicks': 18000000000},
  'MediaSources': const [
    {
      'Id': 'unplayable',
      'Name': '不可播放版本',
      'Container': 'avi',
      'SupportsDirectPlay': false,
      'SupportsDirectStream': false,
      'SupportsTranscoding': false,
    },
    {
      'Id': 'main',
      'Name': '主版本',
      'Container': 'mkv',
      'Bitrate': 8500000,
      'SupportsDirectPlay': true,
      'DefaultAudioStreamIndex': 3,
      'MediaStreams': [
        {
          'Index': 0,
          'Type': 'Video',
          'Codec': 'h264',
          'Width': 1920,
          'Height': 1080,
        },
        {
          'Index': 2,
          'Type': 'Audio',
          'Codec': 'aac',
          'Channels': 2,
          'Language': 'eng',
          'IsDefault': true,
        },
        {
          'Index': 3,
          'Type': 'Audio',
          'Codec': 'eac3',
          'ChannelLayout': '5.1',
          'Language': 'zho',
        },
      ],
    },
  ],
};

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

final _navigationActions = HomeShellNavigationActions(
  showHome: () {},
  showSearch: () {},
  openSettings: () async {},
  openAccount: () async {},
);
