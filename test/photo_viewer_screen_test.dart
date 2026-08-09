import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_sequence_source.dart';
import 'package:emby_my_client/ui/photos/photo_viewer_screen.dart';
import 'package:emby_my_client/ui/photos/zoomable_photo_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('viewer starts at the requested photo and swipes in order', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: DirectoryPhotoSource(
            queryFingerprint: 'screen-test',
            initialItems: const [_folder, _photo1, _photo2, _photo3],
            initialItemId: 'photo-2',
            initialRawCursor: 4,
            initialTotalCount: 4,
            initialHasMore: false,
            loadPage: ({required startIndex, required limit}) async =>
                const EmbyItemPage(items: [], totalRecordCount: 0),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('Photo 2'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('Photo 3'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('double tap toggles the zoom state', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomablePhotoPage(
            request: null,
            thumbnailRequest: null,
            isActive: true,
            onZoomChanged: changes.add,
          ),
        ),
      ),
    );
    final target = find.byType(ZoomablePhotoPage);

    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(target);
    await tester.pump();
    expect(changes.last, isTrue);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(target);
    await tester.pump();
    expect(changes.last, isFalse);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('pinch zoom and pan update one bounded photo transform', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomablePhotoPage(
            request: null,
            thumbnailRequest: null,
            isActive: true,
            onZoomChanged: changes.add,
          ),
        ),
      ),
    );
    final viewerFinder = find.byType(InteractiveViewer);
    final center = tester.getCenter(viewerFinder);
    final first = await tester.startGesture(
      center - const Offset(40, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 2,
    );
    await first.moveTo(center - const Offset(120, 0));
    await second.moveTo(center + const Offset(120, 0));
    await tester.pump();

    final transformationController = tester
        .widget<InteractiveViewer>(viewerFinder)
        .transformationController!;
    expect(transformationController.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(changes, isNotEmpty);
    expect(changes.last, isTrue);

    final beforePan = List<double>.of(transformationController.value.storage);
    await first.moveBy(const Offset(80, 60));
    await second.moveBy(const Offset(80, 60));
    await tester.pump();

    expect(transformationController.value.storage, isNot(equals(beforePan)));
    expect(changes.last, isTrue);
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('viewer returns the final photo and restores system UI', (
    tester,
  ) async {
    final platformCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        platformCalls.add(call);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final api = EmbyApi(_session, dio: Dio());
    addTearDown(api.dispose);
    String? returnedItemId;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              returnedItemId = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => PhotoViewerScreen(
                    api: api,
                    source: DirectoryPhotoSource(
                      queryFingerprint: 'return-test',
                      initialItems: const [_photo1, _photo2, _photo3],
                      initialItemId: 'photo-1',
                      initialRawCursor: 3,
                      initialTotalCount: 3,
                      initialHasMore: false,
                      loadPage: ({required startIndex, required limit}) async =>
                          const EmbyItemPage(items: [], totalRecordCount: 0),
                    ),
                  ),
                ),
              );
            },
            child: const Text('打开图片'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开图片'));
    await tester.pumpAndSettle();
    expect(
      platformCalls.map((call) => call.arguments),
      contains(SystemUiMode.immersiveSticky.toString()),
    );

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(returnedItemId, 'photo-3');
    expect(platformCalls.last.arguments, SystemUiMode.edgeToEdge.toString());
    expect(find.text('打开图片'), findsOneWidget);
  });
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

const _folder = EmbyItem(
  id: 'folder-1',
  name: 'Folder',
  type: 'Folder',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _photo1 = EmbyItem(
  id: 'photo-1',
  name: 'Photo 1',
  type: 'Photo',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _photo2 = EmbyItem(
  id: 'photo-2',
  name: 'Photo 2',
  type: 'Photo',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _photo3 = EmbyItem(
  id: 'photo-3',
  name: 'Photo 3',
  type: 'Photo',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
