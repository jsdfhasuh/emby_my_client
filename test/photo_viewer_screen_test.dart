import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/inline_playback_session.dart';
import 'package:emby_my_client/photos/photo_sequence_source.dart';
import 'package:emby_my_client/ui/photos/inline_video_page.dart';
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
    MediaViewerResult? returnedResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              returnedResult = await Navigator.of(context)
                  .push<MediaViewerResult>(
                    MaterialPageRoute<MediaViewerResult>(
                      builder: (_) => PhotoViewerScreen(
                        api: api,
                        source: DirectoryPhotoSource(
                          queryFingerprint: 'return-test',
                          initialItems: const [_photo1, _photo2, _photo3],
                          initialItemId: 'photo-1',
                          initialRawCursor: 3,
                          initialTotalCount: 3,
                          initialHasMore: false,
                          loadPage:
                              ({required startIndex, required limit}) async =>
                                  const EmbyItemPage(
                                    items: [],
                                    totalRecordCount: 0,
                                  ),
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

    expect(returnedResult?.currentItemId, 'photo-3');
    expect(returnedResult?.queryFingerprint, 'return-test');
    expect(returnedResult?.rawItems.map((item) => item.id), [
      'photo-1',
      'photo-2',
      'photo-3',
    ]);
    expect(platformCalls.last.arguments, SystemUiMode.edgeToEdge.toString());
    expect(find.text('打开图片'), findsOneWidget);
  });

  testWidgets('home media swipes photo to video to photo with one session', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_photo1, _video1, _photo2],
            initialItemId: _photo1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    expect(harness.sessions, isEmpty);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.byType(InlineVideoPage), findsWidgets);
    expect(find.text('Video 1'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(harness.sessions, hasLength(1));
    expect(harness.sessions.single.playCalls, 1);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('Photo 2'), findsOneWidget);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(harness.sessions.single.quiesceCalls, 1);
    expect(harness.sessions.single.shutdownCalls, 1);
    expect(harness.maxActiveSessions, 1);
  });

  testWidgets('photos-only viewer never creates an inline session', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            items: const [_photo1, _video1, _photo2],
            initialItemId: _photo1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pump(const Duration(milliseconds: 260));

    expect(harness.sessions, isEmpty);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Photo 2'), findsOneWidget);
  });

  testWidgets(
    'system back waits for video shutdown before returning media ID',
    (tester) async {
      final platformCalls = <MethodCall>[];
      final restoreSystemUiGate = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          platformCalls.add(call);
          if (call.arguments == SystemUiMode.edgeToEdge.toString()) {
            await restoreSystemUiGate.future;
          }
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final api = EmbyApi(_session, dio: Dio());
      final harness = _ViewerSessionHarness();
      final shutdownGate = Completer<void>();
      harness.nextShutdownGate = shutdownGate;
      addTearDown(api.dispose);
      MediaViewerResult? returnedResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                returnedResult = await Navigator.of(context)
                    .push<MediaViewerResult>(
                      MaterialPageRoute<MediaViewerResult>(
                        builder: (_) => PhotoViewerScreen(
                          api: api,
                          source: _viewerSource(
                            mode: MediaViewerMode.homeMedia,
                            items: const [_video1, _photo1],
                            initialItemId: _video1.id,
                          ),
                          inlineSessionFactory: harness.create,
                        ),
                      ),
                    );
              },
              child: const Text('打开媒体'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开媒体'));
      await tester.pumpAndSettle();
      expect(harness.sessions.single.playCalls, 1);

      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
      expect(returnedResult, isNull);
      expect(
        platformCalls.last.arguments,
        isNot(SystemUiMode.edgeToEdge.toString()),
      );

      shutdownGate.complete();
      await tester.pump();

      expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
      expect(returnedResult, isNull);
      expect(platformCalls.last.arguments, SystemUiMode.edgeToEdge.toString());

      restoreSystemUiGate.complete();
      await tester.pumpAndSettle();

      expect(returnedResult?.currentItemId, _video1.id);
      expect(find.text('打开媒体'), findsOneWidget);
      expect(platformCalls.last.arguments, SystemUiMode.edgeToEdge.toString());
    },
  );

  testWidgets('video slider seeks without changing the PageView page', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_video1, _photo1],
            initialItemId: _video1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final slider = find.byKey(const Key('inline-video-slider-video-1'));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(120, 0));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.text('Video 1'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(harness.sessions.single.seekPositions, hasLength(1));
  });

  testWidgets('blocked slider seek quiesces before swiping to a photo', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_video1, _photo1],
            initialItemId: _video1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final session = harness.sessions.single;
    final coordinator =
        (tester.state(find.byType(PhotoViewerScreen)) as PhotoViewerDebugState)
            .debugInlineCoordinator!;
    final seekGate = Completer<void>();
    session.seekGate = seekGate;

    final slider = find.byKey(const Key('inline-video-slider-video-1'));
    final seekGesture = await tester.startGesture(tester.getCenter(slider));
    await seekGesture.moveBy(const Offset(120, 0));
    await seekGesture.up();
    await tester.pump();
    expect(session.seekCalls, 1);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await _pumpPageTransition(tester);

    expect(find.text('Photo 1'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(session.quiesceCalls, 1);
    expect(session.seekPositions, isEmpty);
    expect(session.shutdownCalls, 0);

    seekGate.complete();
    await tester.pumpAndSettle();
    expect(session.shutdownCalls, 1);
    expect(session.state.isPlaying, isFalse);
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);

    await tester.drag(find.byType(PageView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Video 1'), findsOneWidget);
    expect(harness.sessions, hasLength(2));
    expect(harness.maxActiveSessions, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(harness.activeSessions, 0);
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);
  });

  testWidgets('blocked slider seek quiesces on lifecycle pause', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_video1],
            initialItemId: _video1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final session = harness.sessions.single;
    final coordinator =
        (tester.state(find.byType(PhotoViewerScreen)) as PhotoViewerDebugState)
            .debugInlineCoordinator!;
    final seekGate = Completer<void>();
    session.seekGate = seekGate;

    final slider = find.byKey(const Key('inline-video-slider-video-1'));
    final seekGesture = await tester.startGesture(tester.getCenter(slider));
    await seekGesture.moveBy(const Offset(120, 0));
    await seekGesture.up();
    await tester.pump();
    expect(session.seekCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(session.lifecycleQuiesceCalls, 1);
    expect(session.seekPositions, isEmpty);
    expect(session.playCalls, 1);

    seekGate.complete();
    await tester.pumpAndSettle();
    expect(session.state.isPlaying, isFalse);
    expect(coordinator.inFlightQuiescenceCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(session.lifecycleResumeCalls, 1);
    expect(session.playCalls, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(session.shutdownCalls, 1);
    expect(harness.activeSessions, 0);
    expect(coordinator.inFlightRetirementCount, 0);
    expect(coordinator.inFlightQuiescenceCount, 0);
  });

  testWidgets('consecutive video pages keep one active session', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_video1, _video2],
            initialItemId: _video1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(harness.sessions, hasLength(2));
    expect(harness.sessions.first.shutdownCalls, 1);
    expect(harness.sessions.last.playCalls, 1);
    expect(harness.maxActiveSessions, 1);
    expect(find.text('Video 2'), findsOneWidget);
  });

  testWidgets('rapid loading video to photo to video drops stale autoplay', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    final startGate = Completer<void>();
    harness.nextStartGate = startGate;
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_photo1, _video1, _photo2, _video2],
            initialItemId: _photo1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await _pumpPageTransition(tester);
    expect(find.text('2 / 4'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await _pumpPageTransition(tester);
    expect(find.text('3 / 4'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await _pumpPageTransition(tester);
    expect(harness.sessions, hasLength(1));
    expect(harness.sessions.single.playCalls, 0);
    expect(find.text('Video 2'), findsOneWidget);
    expect(find.text('4 / 4'), findsOneWidget);

    startGate.complete();
    for (
      var attempt = 0;
      attempt < 20 && harness.sessions.length < 2;
      attempt++
    ) {
      await tester.pump();
    }

    expect(harness.sessions, hasLength(2));
    expect(harness.sessions.first.playCalls, 0);
    expect(harness.sessions.first.shutdownCalls, 1);
    expect(harness.sessions.last.playCalls, 1);
    expect(harness.maxActiveSessions, 1);
    expect(find.text('Video 2'), findsOneWidget);
    expect(find.text('4 / 4'), findsOneWidget);
  });

  testWidgets('viewer lifecycle pauses and resumes the active video', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_video1],
            initialItemId: _video1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final session = harness.sessions.single;
    expect(session.playCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(session.lifecycleQuiesceCalls, 1);
    expect(session.lifecycleResumeCalls, 1);
    expect(session.playCalls, 2);
  });

  testWidgets('lifecycle state before coordinator creation is inherited', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_photo1, _video1],
            initialItemId: _photo1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    await tester.pump();
    expect(harness.sessions, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await _pumpPageTransition(tester);

    final session = harness.sessions.single;
    expect(session.playCalls, 0);
    expect(session.lifecycleQuiesceCalls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.lifecycleResumeCalls, 1);
    expect(session.playCalls, 0);
  });

  testWidgets('loading video moved to background never autoplays', (
    tester,
  ) async {
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    final startGate = Completer<void>();
    harness.nextStartGate = startGate;
    addTearDown(api.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(
          api: api,
          source: _viewerSource(
            mode: MediaViewerMode.homeMedia,
            items: const [_video1],
            initialItemId: _video1.id,
          ),
          inlineSessionFactory: harness.create,
        ),
      ),
    );
    for (var attempt = 0; attempt < 20 && harness.sessions.isEmpty; attempt++) {
      await tester.pump();
    }
    final session = harness.sessions.single;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    startGate.complete();
    for (
      var attempt = 0;
      attempt < 20 && session.lifecycleQuiesceCalls == 0;
      attempt++
    ) {
      await tester.pump();
    }

    expect(session.playCalls, 0);
    expect(session.lifecycleQuiesceCalls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.playCalls, 0);
  });

  testWidgets('route exit ignores a late lifecycle resume completion', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final api = EmbyApi(_session, dio: Dio());
    final harness = _ViewerSessionHarness();
    addTearDown(api.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Object? returnedResult;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              returnedResult = await Navigator.of(context).push<Object?>(
                MaterialPageRoute<Object?>(
                  builder: (_) => PhotoViewerScreen(
                    api: api,
                    source: _viewerSource(
                      mode: MediaViewerMode.homeMedia,
                      items: const [_video1],
                      initialItemId: _video1.id,
                    ),
                    inlineSessionFactory: harness.create,
                  ),
                ),
              );
            },
            child: const Text('打开生命周期查看器'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开生命周期查看器'));
    await tester.pumpAndSettle();
    final session = harness.sessions.single;
    final debugState =
        tester.state(find.byType(PhotoViewerScreen)) as PhotoViewerDebugState;
    final coordinator = debugState.debugInlineCoordinator!;
    var coordinatorNotifications = 0;
    coordinator.addListener(() => coordinatorNotifications++);
    expect(session.playCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final resumeGate = Completer<void>();
    session.lifecycleResumeGate = resumeGate;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.lifecycleResumeCalls, 1);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(coordinator.state.phase, InlinePlaybackPhase.inactive);
    final notificationsAfterCloseStarted = coordinatorNotifications;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    resumeGate.complete();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(session.shutdownCalls, 1);
    expect(find.byType(PhotoViewerScreen), findsNothing);
    expect(returnedResult, isNotNull);
    expect(session.playCalls, 1);
    expect(coordinator.state.phase, InlinePlaybackPhase.inactive);
    expect(coordinatorNotifications, notificationsAfterCloseStarted);
  });
}

Future<void> _pumpPageTransition(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

DirectoryPhotoSource _viewerSource({
  MediaViewerMode mode = MediaViewerMode.photosOnly,
  required List<EmbyItem> items,
  required String initialItemId,
}) => DirectoryPhotoSource(
  mode: mode,
  queryFingerprint: 'mixed-viewer-test-$initialItemId',
  initialItems: items,
  initialItemId: initialItemId,
  initialRawCursor: items.length,
  initialTotalCount: items.length,
  initialHasMore: false,
  loadPage: ({required startIndex, required limit}) async =>
      const EmbyItemPage(items: [], totalRecordCount: 0),
);

class _ViewerSessionHarness {
  final sessions = <_ViewerFakeSession>[];
  Completer<void>? nextStartGate;
  Completer<void>? nextShutdownGate;
  int activeSessions = 0;
  int maxActiveSessions = 0;

  Future<InlinePlaybackSession> create(EmbyItem item) async {
    final session = _ViewerFakeSession(
      item.id,
      this,
      startGate: nextStartGate,
      shutdownGate: nextShutdownGate,
    );
    nextStartGate = null;
    nextShutdownGate = null;
    sessions.add(session);
    activeSessions++;
    maxActiveSessions = activeSessions > maxActiveSessions
        ? activeSessions
        : maxActiveSessions;
    return session;
  }
}

class _ViewerFakeSession extends ChangeNotifier
    implements InlinePlaybackSession {
  _ViewerFakeSession(
    this.itemId,
    this.harness, {
    this.startGate,
    this.shutdownGate,
  }) : _state = InlinePlaybackState(itemId: itemId);

  @override
  final String itemId;
  final _ViewerSessionHarness harness;
  final Completer<void>? startGate;
  final Completer<void>? shutdownGate;
  InlinePlaybackState _state;
  int playCalls = 0;
  int pauseCalls = 0;
  int quiesceCalls = 0;
  int lifecyclePauseCalls = 0;
  int lifecycleQuiesceCalls = 0;
  int lifecycleResumeCalls = 0;
  int seekCalls = 0;
  int shutdownCalls = 0;
  final seekPositions = <Duration>[];
  Completer<void>? lifecyclePauseGate;
  Completer<void>? lifecycleQuiesceGate;
  Completer<void>? lifecycleResumeGate;
  Completer<void>? seekGate;
  bool _shutdown = false;
  bool _retiring = false;
  bool _lifecycleQuiesced = false;

  @override
  InlinePlaybackState get state => _state;

  @override
  Future<void> start({Duration? resumePosition}) async {
    _update(
      InlinePlaybackState(
        itemId: itemId,
        phase: InlinePlaybackPhase.loading,
        isBuffering: true,
      ),
    );
    await startGate?.future;
    if (_shutdown) return;
    _update(
      InlinePlaybackState(
        itemId: itemId,
        phase: InlinePlaybackPhase.ready,
        position: resumePosition ?? Duration.zero,
        duration: const Duration(minutes: 4),
      ),
    );
  }

  @override
  Future<void> play() async {
    playCalls++;
    if (_retiring || _lifecycleQuiesced) return;
    _update(_state.copyWith(isPlaying: true, isCompleted: false));
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _update(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> pauseForLifecycle() async {
    lifecyclePauseCalls++;
    _lifecycleQuiesced = true;
    await lifecyclePauseGate?.future;
    if (_shutdown) return;
    _update(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> quiesce() async {
    quiesceCalls++;
    _retiring = true;
    _update(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> quiesceForLifecycle() async {
    lifecycleQuiesceCalls++;
    _lifecycleQuiesced = true;
    await lifecycleQuiesceGate?.future;
    if (_shutdown) return;
    _update(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> resumeForLifecycle() async {
    lifecycleResumeCalls++;
    await lifecycleResumeGate?.future;
    if (!_retiring) _lifecycleQuiesced = false;
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    await seekGate?.future;
    seekPositions.add(position);
    if (_retiring || _lifecycleQuiesced) return;
    _update(_state.copyWith(position: position));
  }

  @override
  Future<void> handleMemoryPressure() async {}

  @override
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    shutdownCalls++;
    await shutdownGate?.future;
    harness.activeSessions--;
  }

  void _update(InlinePlaybackState value) {
    _state = value;
    notifyListeners();
  }
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

const _video1 = EmbyItem(
  id: 'video-1',
  name: 'Video 1',
  type: 'Video',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _video2 = EmbyItem(
  id: 'video-2',
  name: 'Video 2',
  type: 'Video',
  mediaType: 'Video',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);
