import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../core/diagnostic_log.dart';
import '../core/server_scope.dart';
import '../data/emby_api.dart';
import '../data/local_database.dart';
import '../data/session_store.dart';
import 'download_assets.dart';
import 'download_executor.dart';
import 'download_models.dart';
import 'download_preflight.dart';
import 'download_repository.dart';
import 'download_service.dart';
import 'download_settings.dart';

const _notificationServiceId = 8101;
const _pauseButtonId = 'pause_current';
const _deleteButtonId = 'delete_current';

@visibleForTesting
ForegroundTaskOptions downloadForegroundTaskOptions() => ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.repeat(1000),
  autoRunOnBoot: false,
  autoRunOnMyPackageReplaced: false,
  allowWakeLock: true,
  allowWifiLock: true,
  allowAutoRestart: false,
  stopWithTask: false,
);

@pragma('vm:entry-point')
void startDownloadForegroundService() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

class ForegroundDownloadExecutor implements DownloadExecutor {
  ForegroundDownloadExecutor() {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  static void initializePlatform() {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'emby_offline_downloads',
        channelName: '离线下载',
        channelDescription: '显示 Emby 离线下载状态和控制操作',
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PRIVATE,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: downloadForegroundTaskOptions(),
    );
  }

  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> get isRunning async =>
      Platform.isAndroid && await FlutterForegroundTask.isRunningService;

  @override
  Future<void> start() async {
    if (_disposed || !Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await send(DownloadExecutorCommand.wake);
      return;
    }
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission == NotificationPermission.denied) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: _notificationServiceId,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Emby 离线下载',
      notificationText: '正在准备下载',
      notificationButtons: const [
        NotificationButton(id: _pauseButtonId, text: '暂停'),
        NotificationButton(id: _deleteButtonId, text: '取消'),
      ],
      callback: startDownloadForegroundService,
    );
    if (result case ServiceRequestFailure(:final error)) {
      throw StateError('无法启动 Android 下载服务：$error');
    }
  }

  @override
  Future<void> send(DownloadExecutorCommand command, {String? taskId}) async {
    if (_disposed || !Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    final data = <String, Object>{'command': command.name};
    if (taskId != null) data['taskId'] = taskId;
    FlutterForegroundTask.sendDataToTask(data);
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid || !await FlutterForegroundTask.isRunningService) {
      return;
    }
    final result = await FlutterForegroundTask.stopService();
    if (result case ServiceRequestFailure(:final error)) {
      DiagnosticLog.instance.warning(
        'download',
        'Failed to stop Android download service: $error',
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    await _changes.close();
  }

  void _onTaskData(Object data) {
    if (_disposed || data is! Map) return;
    if (data['type'] == 'downloadChanged') _changes.add(null);
  }
}

class _DownloadTaskHandler extends TaskHandler {
  LocalDatabase? _database;
  EmbyApi? _api;
  DownloadService? _service;
  bool _ready = false;
  bool _publishing = false;
  bool _stopRequested = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await DiagnosticLog.instance.initialize();
      final session = await SessionStore().loadSession();
      if (session == null) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Emby 离线下载',
          notificationText: '登录已失效，下载已暂停',
          notificationButtons: const [],
        );
        _requestStop();
        return;
      }
      final scope = ServerScope.fromSession(session);
      final database = LocalDatabase();
      await database.open();
      final api = EmbyApi(session);
      final service = DownloadService(
        api: api,
        scope: scope,
        repository: DownloadRepository(database),
        assetService: EmbyDownloadAssetService(api),
        preflight: PlatformDownloadPreflight(),
        settingsStore: SharedPreferencesDownloadSettingsStore(),
      );
      _database = database;
      _api = api;
      _service = service;
      service.addListener(_onServiceChanged);
      await service.initialize();
      for (final task in service.tasks.where(
        (task) =>
            task.status == DownloadStatus.paused &&
            task.lastErrorCode == 'processInterrupted',
      )) {
        await service.resume(task.id);
      }
      _ready = true;
      await _publish();
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'download',
        'Android download service failed to initialize',
        error: error,
        stackTrace: stackTrace,
      );
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Emby 离线下载',
        notificationText: '下载服务启动失败',
        notificationButtons: const [],
      );
      _requestStop();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_publish());
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final command = DownloadExecutorCommand.values
        .where((value) => value.name == data['command'])
        .firstOrNull;
    final taskId = data['taskId']?.toString();
    if (command != null) {
      unawaited(_handleCommand(command, taskId));
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    final taskId = _currentTask()?.id;
    if (taskId == null) return;
    if (id == _pauseButtonId) {
      unawaited(_handleCommand(DownloadExecutorCommand.pause, taskId));
    } else if (id == _deleteButtonId) {
      unawaited(_handleCommand(DownloadExecutorCommand.delete, taskId));
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    final service = _service;
    _service = null;
    if (service != null) {
      service.removeListener(_onServiceChanged);
      await service.shutdown();
      service.dispose();
    }
    await _api?.dispose();
    _api = null;
    await _database?.close();
    _database = null;
  }

  Future<void> _handleCommand(
    DownloadExecutorCommand command,
    String? taskId,
  ) async {
    final service = _service;
    if (service == null) return;
    switch (command) {
      case DownloadExecutorCommand.pause:
        if (taskId != null) await service.pause(taskId);
      case DownloadExecutorCommand.resume:
        await service.refresh();
        if (taskId != null) await service.resume(taskId);
      case DownloadExecutorCommand.delete:
        if (taskId != null) await service.delete(taskId);
      case DownloadExecutorCommand.wake:
        await service.refresh();
    }
    await _publish();
  }

  void _onServiceChanged() {
    unawaited(_publish());
  }

  DownloadTaskRecord? _currentTask() {
    final tasks = _service?.tasks ?? const <DownloadTaskRecord>[];
    return tasks
            .where((task) => task.status == DownloadStatus.running)
            .firstOrNull ??
        tasks
            .where((task) => task.status == DownloadStatus.queued)
            .firstOrNull ??
        tasks
            .where((task) => task.status == DownloadStatus.cancelling)
            .firstOrNull;
  }

  Future<void> _publish() async {
    if (!_ready || _publishing) return;
    _publishing = true;
    try {
      final service = _service;
      if (service == null) return;
      FlutterForegroundTask.sendDataToMain({'type': 'downloadChanged'});
      final current = _currentTask();
      if (current == null && !service.hasActiveWork) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Emby 离线下载',
          notificationText: '下载任务已结束',
          notificationButtons: const [],
        );
        _requestStop();
        return;
      }
      if (current == null) return;
      final activeCount = service.tasks
          .where(
            (task) =>
                task.status == DownloadStatus.running ||
                task.status == DownloadStatus.queued,
          )
          .length;
      final percent = current.progress == null
          ? null
          : (current.progress! * 100).round();
      final text = [
        current.status == DownloadStatus.queued ? '等待下载' : '正在下载',
        if (percent != null) '$percent%',
        '$activeCount 个任务',
      ].join(' · ');
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Emby 离线下载',
        notificationText: text,
        notificationButtons: const [
          NotificationButton(id: _pauseButtonId, text: '暂停'),
          NotificationButton(id: _deleteButtonId, text: '取消'),
        ],
      );
    } finally {
      _publishing = false;
    }
  }

  void _requestStop() {
    if (_stopRequested) return;
    _stopRequested = true;
    unawaited(FlutterForegroundTask.stopService());
  }
}
