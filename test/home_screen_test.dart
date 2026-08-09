import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/home_screen.dart';
import 'package:emby_my_client/ui/photos/photo_viewer_screen.dart';
import 'package:emby_my_client/ui/widgets/media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'home loads latest items per library and isolates shelf failures',
    () async {
      final requests = <RequestOptions>[];
      final api = _api((options, handler) {
        requests.add(options);
        if (options.path.endsWith('/Views')) {
          handler.resolve(_response(options, data: _views));
          return;
        }
        if (options.path.endsWith('/Items/Resume')) {
          handler.resolve(
            _response(
              options,
              data: {
                'Items': [_resumeItem],
              },
            ),
          );
          return;
        }
        if (options.path.endsWith('/Items/Latest')) {
          if (options.queryParameters['ParentId'] == 'library-2') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 500,
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          handler.resolve(
            _response(
              options,
              data: {
                'Items': [_latestItem],
              },
            ),
          );
          return;
        }
        handler.resolve(_response(options, data: {'Items': const []}));
      });

      final home = await api.getHome();

      expect(home.views, hasLength(2));
      expect(home.resume.single.id, 'resume-1');
      expect(home.latestSections, hasLength(1));
      expect(home.latestSections.single.library.id, 'library-1');
      expect(home.latestSections.single.items.single.id, 'latest-1');

      final latestRequests = requests
          .where((request) => request.path.endsWith('/Items/Latest'))
          .toList();
      expect(latestRequests, hasLength(2));
      expect(
        latestRequests.map((request) => request.queryParameters['ParentId']),
        containsAll(['library-1', 'library-2']),
      );
      expect(latestRequests.first.queryParameters['Limit'], 18);
      expect(latestRequests.first.queryParameters['EnableImages'], true);
      expect(
        latestRequests.first.queryParameters['IncludeItemTypes'],
        'Movie,Series,Episode,Video,Photo',
      );
    },
  );

  testWidgets('home renders responsive media shelves in reference order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final api = _api((options, handler) {
      if (options.path.endsWith('/Views')) {
        handler.resolve(_response(options, data: [_views.first]));
        return;
      }
      if (options.path.endsWith('/Items/Resume')) {
        handler.resolve(
          _response(
            options,
            data: {
              'Items': [_resumeItem],
            },
          ),
        );
        return;
      }
      if (options.path.endsWith('/Items/Latest')) {
        handler.resolve(
          _response(
            options,
            data: {
              'Items': [_latestItem],
            },
          ),
        );
        return;
      }
      handler.resolve(_response(options, data: {'Items': const []}));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: HomeScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的媒体'), findsOneWidget);
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('最新华语剧'), findsOneWidget);
    expect(find.byType(MediaLandscapeCard), findsOneWidget);
    expect(find.byType(MediaPosterCard), findsOneWidget);
    expect(find.text('12'), findsOneWidget);

    final libraryTop = tester.getTopLeft(find.text('我的媒体')).dy;
    final resumeTop = tester.getTopLeft(find.text('继续观看')).dy;
    final latestTop = tester.getTopLeft(find.text('最新华语剧')).dy;
    expect(libraryTop, lessThan(resumeTop));
    expect(resumeTop, lessThan(latestTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('home renders base shelves before latest requests complete', (
    tester,
  ) async {
    RequestOptions? pendingOptions;
    RequestInterceptorHandler? pendingHandler;
    final api = _api((options, handler) {
      if (options.path.endsWith('/Views')) {
        handler.resolve(_response(options, data: [_views.first]));
        return;
      }
      if (options.path.endsWith('/Items/Resume')) {
        handler.resolve(
          _response(
            options,
            data: {
              'Items': [_resumeItem],
            },
          ),
        );
        return;
      }
      if (options.path.endsWith('/Items/Latest')) {
        pendingOptions = options;
        pendingHandler = handler;
        return;
      }
      handler.resolve(_response(options, data: {'Items': const []}));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: HomeScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的媒体'), findsOneWidget);
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('最新华语剧'), findsNothing);
    expect(pendingHandler, isNotNull);

    pendingHandler!.resolve(
      _response(
        pendingOptions!,
        data: {
          'Items': [_latestItem],
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最新华语剧'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home latest photo opens the photo viewer', (tester) async {
    final api = _api((options, handler) {
      if (options.path.endsWith('/Views')) {
        handler.resolve(
          _response(
            options,
            data: [
              {
                'Id': 'mixed-1',
                'Name': '家庭内容',
                'Type': 'CollectionFolder',
                'CollectionType': 'homevideos',
                'ImageTags': const <String, String>{},
                'UserData': const <String, dynamic>{},
              },
            ],
          ),
        );
        return;
      }
      if (options.path.endsWith('/Items/Resume')) {
        handler.resolve(_response(options, data: {'Items': const []}));
        return;
      }
      if (options.path.endsWith('/Items/Latest')) {
        handler.resolve(
          _response(
            options,
            data: {
              'Items': [
                {
                  'Id': 'photo-1',
                  'Name': '最新图片',
                  'Type': 'Photo',
                  'ImageTags': const <String, String>{},
                  'UserData': const <String, dynamic>{},
                },
              ],
            },
          ),
        );
        return;
      }
      handler.resolve(_response(options, data: {'Items': const []}));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: HomeScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新图片'));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewerScreen), findsOneWidget);
  });

  testWidgets('returning from a home photo preserves position without reload', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final views = [
      for (var index = 0; index < 6; index++)
        {
          'Id': 'mixed-$index',
          'Name': '家庭内容 $index',
          'Type': 'CollectionFolder',
          'CollectionType': 'homevideos',
          'ImageTags': const <String, String>{},
          'UserData': const <String, dynamic>{},
        },
    ];
    var viewsRequests = 0;
    var resumeRequests = 0;
    var latestRequests = 0;
    final api = _api((options, handler) {
      if (options.path.endsWith('/Views')) {
        viewsRequests++;
        handler.resolve(_response(options, data: views));
        return;
      }
      if (options.path.endsWith('/Items/Resume')) {
        resumeRequests++;
        handler.resolve(_response(options, data: {'Items': const []}));
        return;
      }
      if (options.path.endsWith('/Items/Latest')) {
        latestRequests++;
        final libraryId = options.queryParameters['ParentId'] as String;
        final index = int.parse(libraryId.split('-').last);
        handler.resolve(
          _response(
            options,
            data: {
              'Items': [
                {
                  'Id': 'photo-$index',
                  'Name': '图片 $index',
                  'Type': 'Photo',
                  'ImageTags': const <String, String>{},
                  'UserData': const <String, dynamic>{},
                },
              ],
            },
          ),
        );
        return;
      }
      handler.resolve(_response(options, data: {'Items': const []}));
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: HomeScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();

    final verticalScrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    await tester.scrollUntilVisible(
      find.text('图片 5'),
      500,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    final before = tester
        .state<ScrollableState>(verticalScrollable)
        .position
        .pixels;
    final requestCounts = (viewsRequests, resumeRequests, latestRequests);

    await tester.tap(find.text('图片 5'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    final after = tester
        .state<ScrollableState>(verticalScrollable)
        .position
        .pixels;
    expect(after, before);
    expect((viewsRequests, resumeRequests, latestRequests), requestCounts);
    expect(tester.takeException(), isNull);
  });
}

EmbyApi _api(
  void Function(RequestOptions options, RequestInterceptorHandler handler)
  onRequest,
) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return EmbyApi(_session, dio: dio);
}

Response<dynamic> _response(RequestOptions options, {required dynamic data}) =>
    Response<dynamic>(requestOptions: options, statusCode: 200, data: data);

const _views = [
  {
    'Id': 'library-1',
    'Name': '华语剧',
    'Type': 'CollectionFolder',
    'CollectionType': 'tvshows',
    'ImageTags': <String, String>{},
    'UserData': <String, dynamic>{},
  },
  {
    'Id': 'library-2',
    'Name': '韩剧',
    'Type': 'CollectionFolder',
    'CollectionType': 'tvshows',
    'ImageTags': <String, String>{},
    'UserData': <String, dynamic>{},
  },
];

const _resumeItem = {
  'Id': 'resume-1',
  'Name': '继续观看示例',
  'Type': 'Episode',
  'MediaType': 'Video',
  'SeriesName': '示例剧集',
  'ParentIndexNumber': 1,
  'IndexNumber': 2,
  'PrimaryImageAspectRatio': 1.777,
  'ImageTags': <String, String>{},
  'UserData': <String, dynamic>{'PlayedPercentage': 42},
};

const _latestItem = {
  'Id': 'latest-1',
  'Name': '这是一个用于验证两行布局不会在放大字体下溢出的很长媒体标题',
  'Type': 'Series',
  'ProductionYear': 2026,
  'PrimaryImageAspectRatio': 0.666,
  'ImageTags': <String, String>{},
  'UserData': <String, dynamic>{'UnplayedItemCount': 12},
};

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);
