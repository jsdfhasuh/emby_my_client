import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/library_screen.dart';
import 'package:emby_my_client/ui/photos/photo_library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('photo library view uses the profile-aware unified browser', (
    tester,
  ) async {
    final requests = <RequestOptions>[];
    final api = _api(requests: requests);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LibraryScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('照片'), findsOneWidget);
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryBrowseScreen), findsOneWidget);
    expect(find.byType(PhotoLibraryScreen), findsNothing);
    expect(find.byKey(const ValueKey('library-item-photo-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-item-folder-1')), findsNothing);
    final mediaRequest = requests.singleWhere(
      (request) => request.path.endsWith('/Items'),
    );
    expect(mediaRequest.queryParameters['IncludeItemTypes'], 'Photo');
    expect(mediaRequest.queryParameters['Recursive'], true);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });

  testWidgets('folder tiles preserve photo directory hierarchy', (
    tester,
  ) async {
    final api = _api();
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoLibraryScreen(api: api, directory: _photoLibrary),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('photo-tile-folder-1')));
    await tester.pumpAndSettle();

    expect(find.text('旅行'), findsWidgets);
    expect(find.byKey(const ValueKey('photo-tile-photo-3')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await api.dispose();
  });
}

EmbyApi _api({List<RequestOptions>? requests}) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests?.add(options);
          if (options.path.endsWith('/Views')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'Items': [_viewJson],
                },
              ),
            );
            return;
          }
          if (options.path.endsWith('/Items')) {
            final parentId = options.queryParameters['ParentId'];
            final mediaOnly =
                options.queryParameters['IncludeItemTypes'] == 'Photo';
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'Items': parentId == 'folder-1'
                      ? [_itemJson('photo-3', '山景', 'Photo')]
                      : mediaOnly
                      ? [
                          _itemJson('photo-1', '海边', 'Photo'),
                          _itemJson('photo-2', '日落', 'Photo'),
                        ]
                      : [
                          _itemJson('folder-1', '旅行', 'Folder'),
                          _itemJson('photo-1', '海边', 'Photo'),
                          _itemJson('photo-2', '日落', 'Photo'),
                        ],
                },
              ),
            );
            return;
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );
  return EmbyApi(_session, dio: dio);
}

Map<String, dynamic> _itemJson(String id, String name, String type) => {
  'Id': id,
  'Name': name,
  'Type': type,
  'ImageTags': const <String, String>{},
};

const _viewJson = <String, dynamic>{
  'Id': 'photos-root',
  'Name': '照片',
  'Type': 'CollectionFolder',
  'CollectionType': 'photos',
  'ImageTags': <String, String>{},
};

const _photoLibrary = EmbyItem(
  id: 'photos-root',
  name: '照片',
  type: 'CollectionFolder',
  collectionType: 'photos',
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
