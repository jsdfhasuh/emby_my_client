// Explicit generated-media Android UI test target. Never publish this APK.
// Exercises the production PlayerScreen and its real default native backend.
import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage_scope.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_settings_scope.dart';
import 'package:emby_my_client/playback/subtitle_preferences_repository.dart';
import 'package:emby_my_client/playback/subtitle_preferences_scope.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:emby_my_client/ui/widgets/configured_playback_video.dart';
import 'package:emby_my_client/ui/downloads/downloads_screen.dart';
import 'package:emby_my_client/ui/widgets/playback_timeline.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'synthetic_playback_origin.dart';
import 'synthetic_download_fixture.dart';
import 'harness_touch.dart';
import 'harness_playback.dart';
import 'harness_lifecycle_trace.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/playback_state.dart';

const _controlOrigin = 'http://127.0.0.1:38766';
final _client = HttpClient();
var _reported = 0;
var _pointer = 10000;
final _eventClock = Stopwatch()..start();
final _interactions = <Map<String, Object?>>[];
final _routeEvents = <Map<String, Object?>>[];
final _gestureTrace = <Map<String, Object?>>[];
final _menuTrace = <Map<String, Object?>>[];
final _lifecycleTrace = <Map<String, Object?>>[];
final _callbackErrors = <Map<String, Object?>>[];
final _routeObserver = _RouteObserver();
const _traceGestures = bool.fromEnvironment('SUBTITLE_ROUTE_TRACE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Preserve framework/platform error handling. The artifact stores only type
  // and allowlisted source frames, never an exception message or external URL.
  final originalFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    _recordCallbackError('flutter', details.exception, details.stack);
    originalFlutterError?.call(details);
  };
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final originalPlatformError = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    _recordCallbackError('platform', error, stack);
    return originalPlatformError?.call(error, stack) ?? false;
  };
  DiagnosticLog.instance.setTestSink((line) {
    final event = safeHarnessLifecycleEvent(line);
    if (event != null) {
      // No private State access: an epoch is available only while an existing
      // menu exposes its controller through the production ListenableBuilder.
      final controllers =
          _elements(
                (w) =>
                    w is ListenableBuilder &&
                    w.listenable is PlaybackController,
              )
              .map(
                (e) =>
                    (e.widget as ListenableBuilder).listenable
                        as PlaybackController,
              )
              .toSet();
      final controller = controllers.length == 1 ? controllers.single : null;
      _lifecycleTrace.add({
        'atUs': _eventClock.elapsedMicroseconds,
        ...event,
        'observedMenuEpoch': controller?.subtitleInputEpoch,
        'observedMenuPhase': controller?.state.phase.name,
        ..._dartPlaybackSnapshot(),
      });
      if (_lifecycleTrace.length > 512) _lifecycleTrace.removeAt(0);
    }
    // This full match admits only the fixed production menu-state record.
    final match = RegExp(
      r'event=playback_options phase=[a-z_]+ reason=[a-z_]+ '
      r'mounted=(?:true|false) open=(?:true|false) released=(?:true|false) '
      r'controller=(?:true|false) plan=(?:true|false) current=(?:true|false) '
      r'playback=[A-Za-z]+ epoch=-?\d+(?:\r?\n)?$',
    ).firstMatch(line);
    if (match == null) return;
    _menuTrace.add({
      'atUs': _eventClock.elapsedMicroseconds,
      'state': match.group(0)!.trim(),
    });
    if (_menuTrace.length > 512) _menuTrace.removeAt(0);
  });
  // This generated-media debug target keeps callback evidence even when the
  // console trace is off. Never filter unrelated application/native messages.
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    final gesture =
        message != null &&
        (message.contains('Gesture arena') ||
            (message.contains('GestureRecognizer') &&
                message.contains('callback.')));
    if (gesture) {
      _gestureTrace.add({
        'atUs': _eventClock.elapsedMicroseconds,
        'message': message,
      });
      if (_gestureTrace.length > 512) _gestureTrace.removeAt(0);
      if (!_traceGestures) return;
    }
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };
  debugPrintGestureArenaDiagnostics = true;
  debugPrintRecognizerCallbacksTrace = true;
  MediaKit.ensureInitialized();
  final response = await (await _client.getUrl(
    Uri.parse('$_controlOrigin/synthetic-pgs.mkv'),
  )).close();
  if (response.statusCode != 200) {
    throw StateError('Generated fixture unavailable');
  }
  final bytes = await response.fold<List<int>>(
    [],
    (all, part) => all..addAll(part),
  );
  final directory = await Directory.systemTemp.createTemp('player-ui-fixture-');
  final media = File('${directory.path}/synthetic-pgs.mkv');
  await media.writeAsBytes(bytes);
  final origin = await SyntheticPlaybackOrigin.start(await media.readAsBytes());
  final api = origin.createApi();
  final download = await SyntheticDownloadFixture.create(
    media: origin.media,
    source: origin.source,
  );
  final cacheStorage = PlatformPlaybackCacheStorage(
    rootResolver: () async => directory,
    freeBytesResolver: (_) async => 1000000000,
  );
  final settings = PlaybackSettingsRepository(storage: _MemoryStorage());
  final preferences = SubtitlePreferencesRepository(storage: _MemoryStorage());
  final cleanup = {
    'routesClosed': false,
    'downloadsClosed': false,
    'apiDisposed': false,
    'serverClosed': false,
    'settingsDisposed': false,
    'subtitlePreferencesDisposed': false,
    'temporaryFilesRemoved': false,
  };
  Object? failure;
  StackTrace? failureStack;
  runApp(
    PlaybackCacheStorageScope(
      storage: cacheStorage,
      child: SubtitlePreferencesRepositoryScope(
        repository: preferences,
        child: PlaybackSettingsRepositoryScope(
          repository: settings,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            navigatorObservers: [_routeObserver],
            theme: ThemeData.dark(useMaterial3: true),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        key: const ValueKey('open-generated-player'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PlayerScreen(
                              api: api,
                              item: origin.item,
                              cacheStorage: cacheStorage,
                            ),
                          ),
                        ),
                        child: const Text('Open generated player'),
                      ),
                      FilledButton(
                        key: const ValueKey('open-generated-downloads'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => DownloadsScreen(
                              api: download.api,
                              downloads: download.downloads,
                            ),
                          ),
                        ),
                        child: const Text('Open generated downloads'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  try {
    for (var cycle = 0; cycle < 2; cycle++) {
      await _tapKey('open-generated-player');
      await _until(
        () => _timeline()?.duration.inMilliseconds == 12000,
        'native ready',
      );
      await _pause();
      await _stage('$cycle-opened');
      await _exerciseSubtitles('$cycle');
      await _tapKey('player-back');
      await _until(
        () => _elements((w) => w is PlayerScreen).isEmpty,
        'route exit',
      );
      await _stage('$cycle-closed', routeShown: false);
    }
    await _tapKey('open-generated-downloads');
    await _until(
      () =>
          _downloadListShown() &&
          _key('download-play-${download.taskId}') != null,
      'completed download list',
    );
    await _stage('download-list', routeShown: false, download: download);
    for (var cycle = 0; cycle < 2; cycle++) {
      await _tapKey('download-play-${download.taskId}');
      await _until(
        () => _timeline()?.duration.inMilliseconds == 12000,
        'offline native ready',
      );
      await _pause();
      await _stage('offline-$cycle-opened', download: download);
      await _exerciseSubtitles('offline-$cycle', download: download);
      await _tapKey('player-back');
      await _until(
        () =>
            _elements((w) => w is PlayerScreen).isEmpty && _downloadListShown(),
        'return to download list',
      );
      await _stage(
        'offline-$cycle-closed',
        routeShown: false,
        download: download,
      );
    }
    await _tapElement(() => _elements((w) => w is BackButton).singleOrNull);
    await _until(
      () => _elements((w) => w is DownloadsScreen).isEmpty,
      'downloads exit',
    );
    await _stage('download-closed', routeShown: false, download: download);
    cleanup['routesClosed'] = true;
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
    // Preserve the actual failed UI before closing any modal or player route.
    // Diagnostics have a separate endpoint and never count as acceptance stages.
    try {
      await _diagnostic(error, stack).timeout(const Duration(seconds: 8));
    } catch (_) {
      // The terminal still reports the original failure, even if diagnostics fail.
    }
  } finally {
    // On failure also retire the production route before destroying its API.
    if (_elements((w) => w is PlayerScreen).isNotEmpty) {
      try {
        if (_elements((w) => w is BottomSheet).isNotEmpty) {
          final element = _elements((w) => w is BottomSheet).first;
          Navigator.of(element).pop();
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        await _tapKey('player-back');
        await _until(
          () => _elements((w) => w is PlayerScreen).isEmpty,
          'failure cleanup',
        );
        cleanup['routesClosed'] = true;
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (_elements((w) => w is DownloadsScreen).isNotEmpty) {
      try {
        Navigator.of(_elements((w) => w is DownloadsScreen).first).pop();
        await _until(
          () => _elements((w) => w is DownloadsScreen).isEmpty,
          'downloads cleanup',
        );
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    cleanup['routesClosed'] = _elements(
      (w) => w is PlayerScreen || w is DownloadsScreen,
    ).isEmpty;
    // Attempt every owned cleanup even if an earlier resource fails to close.
    for (final action in <(String, Future<void> Function())>[
      ('downloadsClosed', download.close),
      ('apiDisposed', api.dispose),
      ('serverClosed', origin.close),
      ('settingsDisposed', settings.dispose),
      ('subtitlePreferencesDisposed', preferences.dispose),
      (
        'temporaryFilesRemoved',
        () async {
          await directory.delete(recursive: true);
          if (await directory.exists()) {
            throw StateError('Fixture files remain');
          }
        },
      ),
    ]) {
      try {
        await action.$2();
        cleanup[action.$1] = true;
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
  }
  try {
    await _report({
      'stage': failure == null ? 'complete' : 'failed',
      'schema': 'emby-android-player-route/v1',
      'platform': 'android',
      'scope': 'production-player-route',
      'productionPlayerScreen': true,
      'nativeBackend': true,
      'physicalPhone': 'NOT_RUN',
      'nativePixelGate': 'SEPARATE_REQUIRED',
      'verifiedStages': _reported,
      'cleanup': cleanup,
      'menuTrace': _menuTrace,
      'lifecycleTrace': _lifecycleTrace,
      'callbackErrors': _callbackErrors,
      if (failure != null) 'error': '$failure',
      if (failureStack != null) 'stack': '$failureStack',
    });
  } finally {
    _client.close(force: true);
    DiagnosticLog.instance.setTestSink(null);
    FlutterError.onError = originalFlutterError;
    dispatcher.onError = originalPlatformError;
  }
}

Future<void> _exerciseSubtitles(
  String prefix, {
  SyntheticDownloadFixture? download,
}) async {
  for (final choice in [('1', 'pgs-a'), ('2', 'pgs-b'), ('1', 'pgs-a2')]) {
    await _selectNative(choice.$1);
    await _stage('$prefix-${choice.$2}', download: download);
  }
  await _selectNative('3');
  await _playUntilCue('TEXT_CUE');
  await _stage('$prefix-ass-visible', download: download);
  await _options();
  await _tapKey('server-subtitle-5-3');
  await _until(
    () => _elements((w) => w is BottomSheet).isEmpty,
    'SRT sheet close',
  );
  await _playUntilCue('EXTERNAL_CUE');
  await _stage('$prefix-srt-visible', download: download);
  await _options();
  await _tapText('关闭字幕');
  await _until(
    () => _elements((w) => w is BottomSheet).isEmpty,
    'off sheet close',
  );
  await _until(
    () => !_hasCue('TEXT_CUE') && !_hasCue('EXTERNAL_CUE'),
    'subtitle off',
  );
  await _stage('$prefix-off', download: download);
}

bool _downloadListShown() => _elements(
  (w) => w is DownloadsScreen,
).any((element) => ModalRoute.of(element)?.isCurrent == true);

List<Element> _elements(bool Function(Widget) match) {
  final result = <Element>[];
  void visit(Element element) {
    if (match(element.widget)) result.add(element);
    element.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Element? _key(String key) =>
    _elements((w) => w.key == ValueKey(key)).firstOrNull;
PlaybackTimeline? _timeline() =>
    _elements((w) => w is PlaybackTimeline).firstOrNull?.widget
        as PlaybackTimeline?;
bool _hasCue(String cue) => _elements(
  (w) =>
      w is Text && w.data?.trim() == cue ||
      w is RichText && w.text.toPlainText().trim() == cue,
).isNotEmpty;

Future<void> _until(bool Function() predicate, String stage) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('UI timeout: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<void> _tapAt(Offset point) async {
  final pointer = _pointer++;
  final downAt = _eventClock.elapsedMicroseconds;
  dispatchHarnessTap(
    position: point,
    pointer: pointer,
    viewId: WidgetsBinding.instance.platformDispatcher.views.first.viewId,
    timestamp: () => _eventClock.elapsed,
  );
  final upAt = _eventClock.elapsedMicroseconds;
  _interactions.add({
    'action': 'pointer-sequence',
    'pointer': pointer,
    'point': [point.dx, point.dy],
    'downAtUs': downAt,
    'upAtUs': upAt,
    'heldMilliseconds': (upAt - downAt) / 1000,
  });
  if (_traceGestures) {
    debugPrint('ROUTE_POINTER ${jsonEncode(_interactions.last)}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 350));
}

Future<void> _tapElement(Element? Function() locate) async {
  Map<String, Object?> beforeEnsure = {};
  late Future<void> pointerReleased;
  await actOnCurrentHarnessTarget(
    locate: locate,
    ready: (element) {
      if (!element.mounted) return false;
      final route = ModalRoute.of(element);
      if (route != null &&
          (!route.isCurrent ||
              (route.animation != null &&
                  route.animation!.status != AnimationStatus.completed))) {
        return false;
      }
      var blocked = false;
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget is IgnorePointer &&
            (ancestor.widget as IgnorePointer).ignoring) {
          blocked = true;
        }
        if (ancestor.widget is Offstage &&
            (ancestor.widget as Offstage).offstage) {
          blocked = true;
        }
        return true;
      });
      return !blocked;
    },
    ensureVisible: (element) {
      beforeEnsure = _tapContext(element);
      return Scrollable.ensureVisible(
        element,
        duration: const Duration(milliseconds: 200),
      );
    },
    endOfFrame: () {
      WidgetsBinding.instance.scheduleFrame();
      return WidgetsBinding.instance.endOfFrame;
    },
    act: (element) {
      final box = element.findRenderObject()! as RenderBox;
      final point = box.localToGlobal(box.size.center(Offset.zero));
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        hit,
        point,
        WidgetsBinding.instance.platformDispatcher.views.first.viewId,
      );
      final targetHit = hit.path.any((entry) => identical(entry.target, box));
      _interactions.add({
        'action': 'tap',
        'target': element.widget.runtimeType.toString(),
        'key': element.widget.key?.toString(),
        if (element.widget is Text) 'text': (element.widget as Text).data,
        'point': [point.dx, point.dy],
        'targetHit': targetHit,
        'atUs': _eventClock.elapsedMicroseconds,
        'beforeEnsure': beforeEnsure,
        'atTap': _tapContext(element),
        if (element.widget is ListTile)
          'enabled': (element.widget as ListTile).onTap != null,
        if (element.widget is IconButton)
          'enabled': (element.widget as IconButton).onPressed != null,
        if (element.widget is IconButton)
          'tooltip': (element.widget as IconButton).tooltip,
        'hitTargets': hit.path
            .map((entry) => entry.target.runtimeType.toString())
            .toList(),
      });
      if (_traceGestures) {
        final compact = {..._interactions.last}
          ..remove('hitTargets')
          ..remove('beforeEnsure');
        debugPrint('ROUTE_INTERACTION ${jsonEncode(compact)}');
      }
      if (!targetHit) throw StateError('Tap target failed hit test');
      pointerReleased = _tapAt(point);
    },
  );
  await pointerReleased;
}

Map<String, Object?> _tapContext(Element element) {
  final scrolls = <Map<String, Object?>>[];
  PlaybackSubtitleOptions? options;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is PlaybackSubtitleOptions) {
      options = ancestor.widget as PlaybackSubtitleOptions;
    }
    if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
      final position = (ancestor.state as ScrollableState).position;
      scrolls.add({
        'axis': position.axis.name,
        'pixels': position.hasPixels ? position.pixels : null,
        'isScrolling': position.isScrollingNotifier.value,
      });
    }
    return true;
  });
  final tab = DefaultTabController.maybeOf(element);
  final state = options?.playbackState;
  return {
    'scrolls': scrolls,
    'playback': _dartPlaybackSnapshot(),
    if (tab != null)
      'tab': {
        'index': tab.index,
        'indexIsChanging': tab.indexIsChanging,
        'animation': tab.animation?.value,
      },
    if (state != null)
      'subtitle': {
        'phase': state.phase.name,
        'status': state.subtitleSelectionStatus.name,
        'appliedNativeId': state.appliedNativeSubtitleId,
        'desiredInputEpoch': state.desiredSubtitleSelection.inputEpoch,
        'desiredRevision': state.desiredSubtitleSelection.requestRevision,
        'sourceId': state.plan?.mediaSourceId,
        'onSelectNativeAvailable': options?.onSelectNative != null,
      },
  };
}

Future<void> _showControls() async {
  final button = _key('player-options');
  if (button == null) return;
  var ignored = false;
  button.visitAncestorElements((ancestor) {
    if (ancestor.widget is IgnorePointer &&
        (ancestor.widget as IgnorePointer).ignoring) {
      ignored = true;
    }
    return true;
  });
  if (ignored) await _tapElement(() => _key('player-video'));
}

Future<void> _tapKey(String key) async {
  if (key.startsWith('player-')) await _showControls();
  for (var scroll = 0; scroll < 10 && _key(key) == null; scroll++) {
    if (_elements((w) => w is BottomSheet).isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } else {
      final sheet =
          _elements((w) => w is BottomSheet).first.findRenderObject()!
              as RenderBox;
      final start = sheet.localToGlobal(
        Offset(sheet.size.width * .5, sheet.size.height * .8),
      );
      final pointer = _pointer++;
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(pointer: pointer, position: start),
      );
      for (var i = 1; i <= 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            pointer: pointer,
            position: start - Offset(0, i * 20.0),
            delta: const Offset(0, -20),
          ),
        );
      }
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: pointer,
          position: start - const Offset(0, 160),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  await _tapElement(() => _key(key));
}

Future<void> _tapText(String text) async {
  await _tapElement(
    () => _elements((w) => w is Text && w.data == text).firstOrNull,
  );
}

Future<void> _options() async {
  await _tapKey('player-options');
  await _until(
    () => _elements((w) => w is BottomSheet).isNotEmpty,
    'options sheet open',
  );
  await _tapText('字幕');
  await _until(() {
    final text = _elements((w) => w is Text && w.data == '字幕').firstOrNull;
    return text != null && DefaultTabController.maybeOf(text)?.index == 2;
  }, 'subtitle tab selected');
}

Future<void> _selectNative(String id) async {
  await _options();
  await _tapKey('native-subtitle-$id');
  await _until(
    () => _elements((w) => w is BottomSheet).isEmpty,
    'native sheet close',
  );
  await _options();
  await _until(() {
    final row = _key('native-subtitle-$id')?.widget;
    return row is ListTile &&
        row.trailing is Icon &&
        (row.trailing! as Icon).icon == Icons.check;
  }, 'native applied check');
  Navigator.of(_elements((w) => w is BottomSheet).first).pop();
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

Player? _routePlayer() =>
    (_elements((w) => w is ConfiguredPlaybackVideo).firstOrNull?.widget
            as ConfiguredPlaybackVideo?)
        ?.controller
        .player;

Map<String, Object?> _dartPlaybackSnapshot() {
  final player = _routePlayer();
  final tooltip = (_key('player-play-pause')?.widget as IconButton?)?.tooltip;
  return {
    'playerFound': player != null,
    'uiPlaying': tooltip == '暂停'
        ? true
        : tooltip == '播放'
        ? false
        : null,
    'dartPlaying': player?.state.playing,
    'dartCompleted': player?.state.completed,
    'dartPositionMs': player?.state.position.inMilliseconds,
    'dartDurationMs': player?.state.duration.inMilliseconds,
  };
}

Future<Map<String, Object?>> _playbackSnapshot() async {
  final result = _dartPlaybackSnapshot();
  final native = _routePlayer()?.platform;
  if (native is NativePlayer) {
    try {
      for (final property in [
        'pause',
        'time-pos',
        'duration',
        'eof-reached',
        'seeking',
      ]) {
        result[property] = await native
            .getProperty(property)
            .timeout(const Duration(seconds: 2));
      }
    } catch (error) {
      result['nativeReadError'] = '$error';
    }
  }
  return result;
}

Future<void> _waitForPlaying(bool playing) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  Map<String, Object?> snapshot;
  do {
    snapshot = await _playbackSnapshot();
    if (harnessPlayingAcknowledged(snapshot, playing)) {
      _interactions.add({
        'action': 'playback-ack',
        'atUs': _eventClock.elapsedMicroseconds,
        'playing': playing,
        'playback': snapshot,
      });
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  } while (DateTime.now().isBefore(deadline));
  throw StateError(
    'Playback acknowledgement timeout: playing=$playing, $snapshot',
  );
}

Future<void> _pause() async {
  await _showControls();
  // Use the real menu's public listenable to observe the current controller;
  // duration alone may arrive before native open/subtitle setup has completed.
  await _tapKey('player-options');
  await _until(
    () => _elements((w) => w is BottomSheet).isNotEmpty,
    'startup readiness sheet',
  );
  final controllers =
      _elements(
            (w) => w is ListenableBuilder && w.listenable is PlaybackController,
          )
          .map(
            (e) =>
                (e.widget as ListenableBuilder).listenable
                    as PlaybackController,
          )
          .toSet();
  if (controllers.length != 1) {
    throw StateError('Startup controller unavailable');
  }
  final controller = controllers.single;
  final player = _routePlayer();
  if (player == null) throw StateError('Startup player unavailable');
  Future<bool> waitReady({bool? playing}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    Map<String, Object?> snapshot;
    do {
      final epoch = controller.subtitleInputEpoch;
      final readyBefore =
          controller.state.phase == PlaybackPhase.ready &&
          controller.state.plan != null;
      final sameBefore = identical(player, _routePlayer());
      snapshot = await _playbackSnapshot();
      snapshot.addAll({
        'controllerReadyBefore': readyBefore,
        'controllerReadyAfter':
            controller.state.phase == PlaybackPhase.ready &&
            controller.state.plan != null,
        'epochBefore': epoch,
        'epochAfter': controller.subtitleInputEpoch,
        'samePlayer': sameBefore && identical(player, _routePlayer()),
      });
      if (harnessStartupAcknowledged(snapshot) &&
          (playing == null || snapshot['dartPlaying'] == playing)) {
        _interactions.add({
          'action': 'playback-ack',
          'atUs': _eventClock.elapsedMicroseconds,
          'playing': snapshot['dartPlaying'],
          'startup': true,
          'playback': snapshot,
        });
        return snapshot['dartPlaying']! as bool;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    } while (DateTime.now().isBefore(deadline));
    throw StateError('Startup acknowledgement timeout: $snapshot');
  }

  await waitReady();
  Navigator.of(_elements((w) => w is BottomSheet).single).pop();
  await _until(
    () => _elements((w) => w is BottomSheet).isEmpty,
    'startup readiness sheet close',
  );
  await pauseHarnessStartup(
    waitForReadyPlaying: () => waitReady(),
    tapPlayPause: () => _tapKey('player-play-pause'),
    waitForPlaying: (playing) async {
      await waitReady(playing: playing);
    },
  );
}

Future<void> _playUntilCue(String cue) async {
  await _showControls();
  final slider =
      _elements((w) => w is Slider).first.findRenderObject()! as RenderBox;
  await _tapAt(
    slider.localToGlobal(
      Offset(slider.size.width * .28, slider.size.height / 2),
    ),
  );
  await playHarnessCueAndPause(
    tapPlayPause: () => _tapKey('player-play-pause'),
    waitForPlaying: _waitForPlaying,
    waitForCue: () => _until(() => _hasCue(cue), 'visible $cue'),
  );
}

Future<void> _stage(
  String stage, {
  bool routeShown = true,
  SyntheticDownloadFixture? download,
}) async {
  if ((_elements((w) => w is PlayerScreen).isNotEmpty) != routeShown) {
    throw StateError('Unexpected route presence: $stage');
  }
  final player =
      _elements((w) => w is PlayerScreen).firstOrNull?.widget as PlayerScreen?;
  final localPathMatches =
      download != null &&
      player?.offlineItem?.localMediaPath == download.mediaFile.path;
  if (download != null &&
      (download.networkAttempts != 0 || (routeShown && !localPathMatches))) {
    throw StateError(
      'Downloaded playback must use the verified local file without network',
    );
  }
  final playback = routeShown ? await _playbackSnapshot() : null;
  if (routeShown && !harnessPlayingAcknowledged(playback!, false)) {
    throw StateError('UI stage must be paused: $stage, $playback');
  }
  await _report({
    'stage': stage,
    'playback': playback,
    'routeShown': routeShown,
    'downloadListShown': _downloadListShown(),
    'entryPoint': download == null ? 'direct-http' : 'downloads',
    'offlineItem': player?.offlineItem != null,
    'networkAttempts': download?.networkAttempts,
    'offlineFileExists': download != null && await download.mediaFile.exists(),
    'sidecarFileExists':
        download != null && await download.subtitleFile.exists(),
    'localPlaybackPathMatches': localPathMatches,
    'productionPlayerScreen': true,
    'nativeBackend': true,
    'timelineMilliseconds': _timeline()?.value,
    'cue': stage.endsWith('ass-visible')
        ? 'TEXT_CUE'
        : stage.endsWith('srt-visible')
        ? 'EXTERNAL_CUE'
        : null,
  });
  _reported++;
}

void _recordCallbackError(String source, Object error, StackTrace? stack) {
  final safeFrames = RegExp(
    r'^#\d+\s+[^\r\n(]+\('
    r'(?:package:(?:emby_my_client|flutter)/[A-Za-z0-9_/]+\.dart|dart:[a-z_]+)'
    r':\d+:\d+\)',
    multiLine: true,
  ).allMatches('$stack').take(12).map((match) => match.group(0)).toList();
  _callbackErrors.add({
    'atUs': _eventClock.elapsedMicroseconds,
    'source': source,
    'errorType': error.runtimeType.toString(),
    'frames': safeFrames,
  });
  if (_callbackErrors.length > 64) _callbackErrors.removeAt(0);
}

Future<void> _diagnostic(Object error, StackTrace stack) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  final nodes = <Map<String, Object?>>[];
  for (final element in _elements(
    (widget) =>
        widget.key != null ||
        widget is Text ||
        widget is Tab ||
        widget is PlaybackSubtitleOptions,
  )) {
    final widget = element.widget;
    Rect? rect;
    final render = element.findRenderObject();
    if (render is RenderBox && render.attached && render.hasSize) {
      rect = render.localToGlobal(Offset.zero) & render.size;
    }
    var offstage = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is Offstage &&
          (ancestor.widget as Offstage).offstage) {
        offstage = true;
      }
      return true;
    });
    nodes.add({
      'type': widget.runtimeType.toString(),
      if (widget.key != null) 'key': widget.key.toString(),
      if (widget is Text) 'text': widget.data ?? widget.textSpan?.toPlainText(),
      'onScreen': rect != null && screen.overlaps(rect) && !offstage,
      if (rect != null) 'rect': [rect.left, rect.top, rect.width, rect.height],
      if (widget is ListTile) 'enabled': widget.onTap != null,
      if (widget is Tab)
        'tabIndex': DefaultTabController.maybeOf(element)?.index,
      if (widget is PlaybackSubtitleOptions) ...{
        'nativeIds': widget.nativeTracks
            .map((target) => target.track.id)
            .toList(),
        'engineTracks': widget.playbackState.subtitleTracks
            .map(
              (track) => {
                'id': track.id,
                'title': track.title,
                'codec': track.codec,
              },
            )
            .toList(),
        'phase': widget.playbackState.phase.name,
        'subtitleStatus': widget.playbackState.subtitleSelectionStatus.name,
        'subtitleError': widget.playbackState.subtitleSelectionError,
      },
    });
  }
  final request = await _client.postUrl(
    Uri.parse('$_controlOrigin/diagnostic'),
  );
  request.headers.contentType = ContentType.json;
  request.write(
    jsonEncode({
      'scope': 'diagnostic-not-acceptance',
      'error': '$error',
      'stack': '$stack',
      'verifiedStages': _reported,
      'playback': await _playbackSnapshot(),
      'screen': [screen.width, screen.height],
      'physicalSize': [view.physicalSize.width, view.physicalSize.height],
      'devicePixelRatio': view.devicePixelRatio,
      'routeEvents': _routeEvents,
      'gestureTrace': _gestureTrace,
      'menuTrace': _menuTrace,
      'lifecycleTrace': _lifecycleTrace,
      'callbackErrors': _callbackErrors,
      'interactions': _interactions,
      'nodes': nodes,
    }),
  );
  final response = await request.close();
  await response.drain<void>();
  if (response.statusCode != 200) {
    throw StateError('UI diagnostic capture failed');
  }
}

Future<void> _report(Map<String, Object?> value) async {
  final request = await _client.postUrl(Uri.parse('$_controlOrigin/stage'));
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(value));
  final response = await request.close();
  await response.drain<void>();
  if (response.statusCode != 200) throw StateError('UI evidence rejected');
}

class _MemoryStorage implements PlaybackSettingsStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _RouteObserver extends NavigatorObserver {
  void _record(String event, Route<dynamic> route) {
    final value = <String, Object?>{
      'event': event,
      'route': route.runtimeType.toString(),
      'atUs': _eventClock.elapsedMicroseconds,
      'isCurrent': route.isCurrent,
    };
    _routeEvents.add(value);
    if (_traceGestures) debugPrint('ROUTE_NAV ${jsonEncode(value)}');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('push', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('pop', route);
  }
}
