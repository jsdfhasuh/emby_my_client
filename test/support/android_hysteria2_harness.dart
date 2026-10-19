import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_connection.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/ui/downloads/download_connection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:hysteria2/hysteria2.dart';

const _session = EmbySession(
  serverUrl: 'https://fixture.invalid',
  serverName: 'Smoke',
  serverId: 'hysteria2-smoke',
  userId: 'fixture',
  username: 'fixture',
  accessToken: 'fixture',
  deviceId: 'fixture',
);

@pragma('vm:entry-point')
void smokeDownloadTask() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_SmokeTask());
}

class _SmokeTask extends TaskHandler {
  String? _lease;
  final _platform = const Hysteria2Platform();
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _lease = await _platform.acquire(
        scope: 'fixture-worker',
        kind: 'download',
      );
      final counts = await _platform.status();
      FlutterForegroundTask.sendDataToMain({
        'worker': counts['downloads'] == 1 && counts['playbacks'] == 1,
      });
    } catch (_) {
      FlutterForegroundTask.sendDataToMain({'worker': false});
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    final id = _lease;
    if (id != null) await _platform.release(id);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'hy2_smoke',
      channelName: 'HY2 smoke',
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowAutoRestart: false,
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
    ),
  );
  runApp(MaterialApp(home: DownloadConnectionScreen(session: _session)));
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_smoke()));
}

Future<void> _smoke() async {
  final platform = const Hysteria2Platform();
  final manager = DownloadConnectionManager.instance;
  final scope = ServerScope.fromSession(_session);
  final report = <String, Object?>{};
  String? playback, probe;
  final worker = Completer<bool>();
  void onData(Object data) {
    if (data is Map && data['worker'] is bool && !worker.isCompleted) {
      worker.complete(data['worker'] == true);
    }
  }

  FlutterForegroundTask.addTaskDataCallback(onData);
  try {
    final profile = Hysteria2Profile.parse(
      'hy2://fixture-auth@127.0.0.1:9?sni=localhost',
    );
    await manager.save(scope, DownloadConnectionSettings(profile: profile));
    report['secureStorage'] =
        (await manager.load(scope)).profile?.auth == 'fixture-auth';
    playback = await platform.acquire(scope: 'fixture-ui', kind: 'playback');
    await FlutterForegroundTask.startService(
      serviceId: 8199,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'HY2 smoke',
      notificationText: 'Running',
      callback: smokeDownloadTask,
    );
    report['backgroundEngine'] = await worker.future.timeout(
      const Duration(seconds: 20),
    );
    try {
      await manager.delete(scope);
      report['exclusiveGate'] = false;
    } on DownloadConnectionException catch (error) {
      report['exclusiveGate'] = error.code == 'configBusy';
    }
    await platform.release(playback);
    playback = null;
    await FlutterForegroundTask.stopService();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((await platform.status())['downloads'] != 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    probe = await platform.acquire(scope: 'fixture-ui', kind: 'configuration');
    try {
      await platform.connect(leaseId: probe, config: profile.toNativeConfig());
      report['jniCore'] = false;
    } on PlatformException catch (error) {
      report['jniCore'] = const {
        'timeout',
        'connect_failed',
        'tls_failed',
        'auth_failed',
      }.contains(error.code);
    }
    await platform.release(probe);
    probe = null;
    await manager.delete(scope);
    final status = await platform.status();
    report['released'] =
        status['downloads'] == 0 &&
        status['playbacks'] == 0 &&
        status['editing'] == false &&
        status['cores'] == 0;
    report['success'] = report.values.every((value) => value == true);
  } catch (error) {
    report['success'] = false;
    report['errorType'] = error.runtimeType.toString();
  } finally {
    if (playback != null) await platform.release(playback);
    if (probe != null) await platform.release(probe);
    await FlutterForegroundTask.stopService();
    FlutterForegroundTask.removeTaskDataCallback(onData);
  }
  debugPrint('HY2_SMOKE ${jsonEncode(report)}');
}
