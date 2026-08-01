import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/photos/photo_viewer_screen.dart';
import 'package:emby_my_client/ui/photos/zoomable_photo_page.dart';
import 'package:flutter/material.dart';
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
          parentId: 'root',
          initialDirectoryItems: const [_folder, _photo1, _photo2, _photo3],
          initialItemId: 'photo-2',
          initialHasMore: false,
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
