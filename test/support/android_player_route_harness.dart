// Explicit generated-media Android UI test target. Never publish this APK.
// Exercises the production PlayerScreen and its real default native backend.
import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage_scope.dart';
import 'package:emby_my_client/playback/playback_settings_repository.dart';
import 'package:emby_my_client/playback/playback_settings_scope.dart';
import 'package:emby_my_client/playback/subtitle_preferences_repository.dart';
import 'package:emby_my_client/playback/subtitle_preferences_scope.dart';
import 'package:emby_my_client/ui/player_screen.dart';
import 'package:emby_my_client/ui/downloads/downloads_screen.dart';
import 'package:emby_my_client/ui/widgets/playback_timeline.dart';
import 'package:emby_my_client/ui/widgets/playback_subtitle_options.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'synthetic_playback_origin.dart';
import 'synthetic_download_fixture.dart';

const _controlOrigin = 'http://127.0.0.1:38766';
final _client = HttpClient();
var _reported = 0;
var _pointer = 10000;
final _eventClock = Stopwatch()..start();
final _interactions = <Map<String, Object?>>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    await _tapElement(_elements((w) => w is BackButton).single);
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
      if (failure != null) 'error': '$failure',
      if (failureStack != null) 'stack': '$failureStack',
    });
  } finally {
    _client.close(force: true);
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
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      position: point,
      timeStamp: _eventClock.elapsed,
      viewId: WidgetsBinding.instance.platformDispatcher.views.first.viewId,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      position: point,
      timeStamp: _eventClock.elapsed,
      viewId: WidgetsBinding.instance.platformDispatcher.views.first.viewId,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 350));
}

Future<void> _tapElement(Element element) async {
  // A wall-clock delay does not guarantee a software-rendered route has finished
  // its transition. Wait for the route's real animation and pointer eligibility.
  await _until(() {
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
  }, 'tap target route settled');
  await Scrollable.ensureVisible(
    element,
    duration: const Duration(milliseconds: 200),
  );
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
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
    'hitTargets': hit.path
        .map((entry) => entry.target.runtimeType.toString())
        .toList(),
  });
  if (!targetHit) throw StateError('Tap target failed hit test');
  await _tapAt(point);
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
  if (ignored) await _tapElement(_key('player-video')!);
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
  await _until(() => _key(key) != null, key);
  await _tapElement(_key(key)!);
}

Future<void> _tapText(String text) async {
  await _until(
    () => _elements((w) => w is Text && w.data == text).isNotEmpty,
    text,
  );
  await _tapElement(_elements((w) => w is Text && w.data == text).first);
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

Future<void> _pause() async {
  await _showControls();
  final button = _key('player-play-pause')?.widget as IconButton?;
  if (button?.tooltip == '暂停') await _tapKey('player-play-pause');
  await _until(
    () => (_key('player-play-pause')?.widget as IconButton?)?.tooltip == '播放',
    'paused',
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
  await _tapKey('player-play-pause');
  await _until(() => _hasCue(cue), 'visible $cue');
  await _pause();
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
  await _report({
    'stage': stage,
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
      'screen': [screen.width, screen.height],
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
