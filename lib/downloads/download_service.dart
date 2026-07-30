import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../core/diagnostic_log.dart';
import '../core/server_scope.dart';
import '../data/emby_api.dart';
import '../models/emby_models.dart';
import 'download_assets.dart';
import 'download_cleanup.dart';
import 'download_executor.dart';
import 'download_models.dart';
import 'download_path_policy.dart';
import 'download_preflight.dart';
import 'download_repository.dart';
import 'download_settings.dart';
import 'download_transport.dart';

typedef DownloadDirectoryResolver =
    Future<Directory> Function(ServerScope scope);
typedef DownloadRetryDelay = Future<void> Function(Duration duration);

class DownloadService extends ChangeNotifier {
  DownloadService({
    required this.api,
    required this.scope,
    required DownloadStore repository,
    DownloadTransport? transport,
    DownloadDirectoryResolver? directoryResolver,
    DownloadRetryDelay? retryDelay,
    DownloadAssetService? assetService,
    DownloadCleanup cleanup = const DownloadCleanup(),
    DownloadPreflight? preflight,
    DownloadSettingsStore? settingsStore,
    DownloadExecutor? executor,
    this.maxConcurrentDownloads = 2,
  }) : _repository = repository,
       _transport = transport ?? EmbyDownloadTransport(api),
       _directoryResolver = directoryResolver ?? _defaultDirectory,
       _retryDelay = retryDelay ?? Future<void>.delayed,
       _assetService = assetService ?? const NoopDownloadAssetService(),
       _cleanup = cleanup,
       _preflight = preflight ?? const NoopDownloadPreflight(),
       _settingsStore = settingsStore ?? MemoryDownloadSettingsStore(),
       _executor = executor;

  final EmbyApi api;
  final ServerScope scope;
  final DownloadStore _repository;
  final DownloadTransport _transport;
  final DownloadDirectoryResolver _directoryResolver;
  final DownloadRetryDelay _retryDelay;
  final DownloadAssetService _assetService;
  final DownloadCleanup _cleanup;
  final DownloadPreflight _preflight;
  final DownloadSettingsStore _settingsStore;
  final DownloadExecutor? _executor;
  final int maxConcurrentDownloads;

  final Map<String, DownloadTaskRecord> _tasks = {};
  final Map<String, Future<void>> _operations = {};
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, _RequestedAction> _requestedActions = {};
  StreamSubscription<void>? _executorChanges;
  DownloadSettings _settings = const DownloadSettings();
  bool _initialized = false;
  bool _shuttingDown = false;
  bool _disposed = false;

  List<DownloadTaskRecord> get tasks {
    final result = _tasks.values.toList(growable: false);
    result.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return List.unmodifiable(result);
  }

  DownloadSettings get settings => _settings;
  bool get hasActiveWork => _tasks.values.any(
    (task) =>
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.running ||
        task.status == DownloadStatus.cancelling,
  );

  DownloadTaskRecord? taskForItem(String itemId) =>
      _tasks.values.where((task) => task.itemId == itemId).firstOrNull;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    _settings = await _settingsStore.load(scope);
    final executorRunning = await _executor?.isRunning ?? false;
    final restored = await _repository.listTasks(scope);
    final downloadDirectory = await _directoryResolver(scope);
    final pathPolicy = DownloadPathPolicy(downloadDirectory);
    for (var task in restored) {
      final resolvedTempPath = pathPolicy.resolveStoredPath(task.tempPath);
      final resolvedFinalPath = pathPolicy.resolveStoredPath(task.finalPath);
      if (!pathPolicy.contains(resolvedTempPath) ||
          !pathPolicy.contains(resolvedFinalPath)) {
        DiagnosticLog.instance.warning(
          'download',
          'Rejected unsafe restored download path task=${task.id}',
        );
        task = task.copyWith(
          status: DownloadStatus.failed,
          lastErrorCode: 'invalidLocalPath',
          updatedAt: DateTime.now().toUtc(),
        );
        await _repository.removeOfflineItem(task);
        await _repository.saveTask(task);
        _tasks[task.id] = task;
        continue;
      }
      if (task.tempPath != resolvedTempPath ||
          task.finalPath != resolvedFinalPath) {
        task = task.copyWith(
          tempPath: resolvedTempPath,
          finalPath: resolvedFinalPath,
        );
        if (task.status == DownloadStatus.completed) {
          await _repository.complete(
            task,
            OfflineMediaItem(
              scope: task.scope,
              itemId: task.itemId,
              mediaSourceId: task.mediaSourceId,
              metadata: task.metadata,
              localMediaPath: task.finalPath,
              completedAt: task.updatedAt,
            ),
          );
        } else {
          await _repository.saveTask(task);
        }
      }
      final tempFile = File(task.tempPath);
      final finalFile = File(task.finalPath);
      if (!executorRunning && task.status == DownloadStatus.cancelling) {
        await _removeTaskAndFiles(task);
        continue;
      }
      final interrupted =
          task.status == DownloadStatus.running ||
          (task.status == DownloadStatus.paused &&
              task.lastErrorCode == 'processInterrupted');
      if (!executorRunning && interrupted) {
        final resumeWhenAppReopens = _executor != null;
        task = task.copyWith(
          status: resumeWhenAppReopens
              ? DownloadStatus.queued
              : DownloadStatus.paused,
          downloadedBytes: await _lengthIfPresent(tempFile),
          lastErrorCode: resumeWhenAppReopens ? null : 'processInterrupted',
          clearLastErrorCode: resumeWhenAppReopens,
          updatedAt: DateTime.now().toUtc(),
        );
        await _repository.saveTask(task);
      } else if (task.status == DownloadStatus.completed &&
          !await finalFile.exists()) {
        task = task.copyWith(
          status: DownloadStatus.failed,
          lastErrorCode: 'missingFile',
          updatedAt: DateTime.now().toUtc(),
        );
        await _repository.removeOfflineItem(task);
        await _repository.saveTask(task);
      } else if (task.status != DownloadStatus.completed &&
          await finalFile.exists()) {
        task = await _commitExistingFile(task, finalFile);
      } else if (await tempFile.exists()) {
        final length = await tempFile.length();
        if (length != task.downloadedBytes) {
          task = task.copyWith(
            downloadedBytes: length,
            updatedAt: DateTime.now().toUtc(),
          );
          await _repository.saveTask(task);
        }
      }
      _tasks[task.id] = task;
    }
    await cleanupOrphans();
    final executor = _executor;
    if (executor != null) {
      _executorChanges = executor.changes.listen((_) {
        unawaited(refresh());
      });
    }
    _notify();
    if (executor != null && hasActiveWork) {
      await executor.start();
    } else {
      _pumpQueue();
    }
  }

  Future<void> refresh() async {
    if (_disposed || !_initialized) return;
    final restored = await _repository.listTasks(scope);
    if (_disposed) return;
    _tasks
      ..clear()
      ..addEntries(restored.map((task) => MapEntry(task.id, task)));
    _notify();
    _pumpQueue();
  }

  Future<DownloadCleanupReport> cleanupOrphans() async {
    try {
      final directory = await _directoryResolver(scope);
      final report = await _cleanup.run(directory: directory, tasks: tasks);
      if (report.deletedFiles > 0) {
        DiagnosticLog.instance.info(
          'download',
          'Removed ${report.deletedFiles} orphan download file(s) '
              'bytes=${report.reclaimedBytes}',
        );
      }
      return report;
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'download',
        'Offline download cleanup failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const DownloadCleanupReport(deletedFiles: 0, reclaimedBytes: 0);
    }
  }

  Future<void> setWifiOnly(bool value) async {
    _ensureActive();
    if (_settings.wifiOnly == value) return;
    _settings = _settings.copyWith(wifiOnly: value);
    await _settingsStore.save(scope, _settings);
    _notify();
    if (!value) {
      final blocked = _tasks.values
          .where(
            (task) =>
                task.status == DownloadStatus.failed &&
                task.lastErrorCode == 'wifiRequired',
          )
          .toList(growable: false);
      for (final task in blocked) {
        await resume(task.id);
      }
    }
  }

  Future<DownloadTaskRecord> enqueue(
    EmbyItem item, {
    String? mediaSourceId,
  }) async {
    _ensureActive();
    final current = taskForItem(item.id);
    if (current != null) {
      if (current.canResume) await resume(current.id);
      return _tasks[current.id] ?? current;
    }

    final fullItem = item.mediaSources.isEmpty
        ? await api.getItem(item.id)
        : item;
    final sources = fullItem.mediaSources;
    if (sources.isEmpty) {
      throw const EmbyApiException('服务器没有返回可下载的原始媒体源');
    }
    final source =
        sources
            .where((candidate) => candidate.id == mediaSourceId)
            .firstOrNull ??
        sources.first;
    final uris = _transport.sourceUris(
      itemId: fullItem.id,
      mediaSourceId: source.id,
    );
    if (uris.isEmpty) {
      throw const EmbyApiException('服务器没有提供可下载地址');
    }

    final directory = await _directoryResolver(scope);
    await directory.create(recursive: true);
    await _preflight.verifyStorage(
      directory: directory,
      expectedBytes: source.size,
      downloadedBytes: 0,
    );
    final extension = _fileExtension(source);
    final identity = sha256
        .convert(
          utf8.encode('${scope.databaseKey}\u0000${item.id}\u0000${source.id}'),
        )
        .toString();
    final finalPath = path.join(
      directory.path,
      '${identity.substring(0, 32)}.$extension',
    );
    final timestamp = DateTime.now().toUtc();
    final task = DownloadTaskRecord(
      id: identity,
      scope: scope,
      itemId: fullItem.id,
      mediaSourceId: source.id,
      sourceKind: DownloadSourceKind.original,
      sourceFingerprint: sha256
          .convert(utf8.encode(uris.join('\n')))
          .toString(),
      status: DownloadStatus.queued,
      downloadedBytes: 0,
      retryCount: 0,
      expectedBytes: source.size,
      tempPath: '$finalPath.part',
      finalPath: finalPath,
      metadata: OfflineMediaMetadata.fromItem(fullItem, source),
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    await _repository.saveTask(task);
    _tasks[task.id] = task;
    _notify();
    final executor = _executor;
    if (executor == null) {
      _pumpQueue();
    } else {
      await executor.start();
    }
    return task;
  }

  Future<void> pause(String taskId) async {
    final task = _tasks[taskId];
    if (task == null ||
        task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.completed ||
        task.status == DownloadStatus.failed) {
      return;
    }
    final executor = _executor;
    if (executor != null) {
      await _save(
        task.copyWith(
          status: DownloadStatus.paused,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await executor.send(DownloadExecutorCommand.pause, taskId: taskId);
      return;
    }
    if (task.status == DownloadStatus.queued) {
      await _save(
        task.copyWith(
          status: DownloadStatus.paused,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return;
    }
    _requestedActions[taskId] = _RequestedAction.pause;
    await _save(
      task.copyWith(
        status: DownloadStatus.paused,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    _cancelTokens[taskId]?.cancel('pause');
  }

  Future<void> resume(String taskId) async {
    _ensureActive();
    final active = _operations[taskId];
    if (active != null) await active;
    final task = _tasks[taskId];
    if (task == null ||
        task.status == DownloadStatus.running ||
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.completed) {
      return;
    }
    _requestedActions.remove(taskId);
    await _save(
      task.copyWith(
        status: DownloadStatus.queued,
        clearLastErrorCode: true,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    final executor = _executor;
    if (executor == null) {
      _pumpQueue();
    } else {
      await executor.start();
      await executor.send(DownloadExecutorCommand.resume, taskId: taskId);
    }
  }

  Future<void> delete(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return;
    final executor = _executor;
    if (executor != null && !task.isComplete && await executor.isRunning) {
      await _save(
        task.copyWith(
          status: DownloadStatus.cancelling,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await executor.send(DownloadExecutorCommand.delete, taskId: taskId);
      return;
    }
    if (_operations.containsKey(taskId)) {
      _requestedActions[taskId] = _RequestedAction.delete;
      await _save(
        task.copyWith(
          status: DownloadStatus.cancelling,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      _cancelTokens[taskId]?.cancel('delete');
      await _operations[taskId];
      return;
    }
    await _removeTaskAndFiles(task);
  }

  Future<OfflineMediaItem?> offlineItem(String itemId) =>
      _repository.offlineItem(scope, itemId);

  Future<List<OfflineMediaItem>> offlineItems() =>
      _repository.listOfflineItems(scope);

  Future<void> recordOfflineProgress(
    OfflineMediaItem item,
    Duration position, {
    required bool played,
  }) {
    if (item.scope != scope) {
      throw ArgumentError('Offline progress belongs to another server scope');
    }
    return _repository.saveProgress(
      OfflineProgressRecord(
        scope: scope,
        itemId: item.itemId,
        positionTicks: position.inMicroseconds * 10,
        played: played,
        updatedAt: DateTime.now().toUtc(),
        syncStatus: 'pending',
      ),
    );
  }

  Future<void> shutdown() async {
    if (_shuttingDown) {
      await Future.wait(_operations.values.toList(growable: false));
      return;
    }
    _shuttingDown = true;
    for (final entry in _cancelTokens.entries) {
      _requestedActions[entry.key] = _RequestedAction.pause;
      entry.value.cancel('shutdown');
    }
    await Future.wait(_operations.values.toList(growable: false));
    await _executorChanges?.cancel();
    _executorChanges = null;
    await _executor?.dispose();
  }

  Future<void> stopExecutor() async {
    await _executor?.stop();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_shuttingDown) unawaited(shutdown());
    super.dispose();
  }

  void _pumpQueue() {
    if (_disposed || _shuttingDown || _executor != null) return;
    final available = max(0, maxConcurrentDownloads - _operations.length);
    if (available == 0) return;
    final queued = _tasks.values
        .where((task) => task.status == DownloadStatus.queued)
        .take(available)
        .toList(growable: false);
    for (final task in queued) {
      final operation = _run(task.id);
      _operations[task.id] = operation;
      unawaited(
        operation.whenComplete(() {
          _operations.remove(task.id);
          _cancelTokens.remove(task.id);
          _requestedActions.remove(task.id);
          _pumpQueue();
        }),
      );
    }
  }

  Future<void> _run(String taskId) async {
    var task = _tasks[taskId];
    if (task == null) return;
    final token = CancelToken();
    _cancelTokens[taskId] = token;
    task = task.copyWith(
      status: DownloadStatus.running,
      clearLastErrorCode: true,
      updatedAt: DateTime.now().toUtc(),
    );
    await _save(task);

    Object? lastError;
    StackTrace? lastStackTrace;
    final uris = _transport.sourceUris(
      itemId: task.itemId,
      mediaSourceId: task.mediaSourceId,
    );
    try {
      await _preflight.verifyNetwork(wifiOnly: _settings.wifiOnly);
      await _preflight.verifyStorage(
        directory: File(task.finalPath).parent,
        expectedBytes: task.expectedBytes,
        downloadedBytes: task.downloadedBytes,
      );
      for (final uri in uris) {
        for (var retry = 0; retry < 3; retry++) {
          try {
            await _transfer(taskId, uri, token);
            return;
          } catch (error, stackTrace) {
            if (_requestedActions.containsKey(taskId) ||
                token.isCancelled ||
                error is _DownloadInterrupted) {
              rethrow;
            }
            if (error is EmbyApiException && error.isAuthenticationFailure) {
              rethrow;
            }
            lastError = error;
            lastStackTrace = stackTrace;
            final status = error is EmbyApiException ? error.statusCode : null;
            final transient =
                status == 429 || (status != null && status >= 500);
            if (!transient || retry == 2) break;
            task = _tasks[taskId]!;
            await _save(
              task.copyWith(
                retryCount: task.retryCount + 1,
                updatedAt: DateTime.now().toUtc(),
              ),
            );
            await _retryDelay(Duration(seconds: 1 << retry));
          }
        }
      }
      Error.throwWithStackTrace(
        lastError ?? StateError('No download endpoint succeeded'),
        lastStackTrace ?? StackTrace.current,
      );
    } catch (error, stackTrace) {
      final action = _requestedActions[taskId];
      if (action == _RequestedAction.delete) {
        final current = _tasks[taskId];
        if (current != null) await _removeTaskAndFiles(current);
        return;
      }
      if (action == _RequestedAction.pause || _shuttingDown) {
        final current = _tasks[taskId];
        if (current != null) {
          await _save(
            current.copyWith(
              status: DownloadStatus.paused,
              downloadedBytes: await _lengthIfPresent(File(current.tempPath)),
              lastErrorCode: _shuttingDown
                  ? 'processInterrupted'
                  : current.lastErrorCode,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
        }
        return;
      }
      final current = _tasks[taskId];
      if (current == null) return;
      DiagnosticLog.instance.error(
        'download',
        'Download failed item=${current.itemId} task=${current.id}',
        error: error,
        stackTrace: stackTrace,
      );
      await _save(
        current.copyWith(
          status: DownloadStatus.failed,
          downloadedBytes: await _lengthIfPresent(File(current.tempPath)),
          lastErrorCode: _errorCode(error),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  Future<void> _transfer(String taskId, Uri uri, CancelToken token) async {
    for (var restart = 0; restart < 2; restart++) {
      var task = _tasks[taskId]!;
      final tempFile = File(task.tempPath);
      final finalFile = File(task.finalPath);
      if (await finalFile.exists()) {
        await _commitExistingFile(task, finalFile);
        return;
      }
      await tempFile.parent.create(recursive: true);
      var offset = await _lengthIfPresent(tempFile);
      final response = await _transport.open(
        uri,
        cancelToken: token,
        offset: offset,
        etag: task.etag,
      );
      _throwIfInterrupted(taskId, token);

      if (response.statusCode == 416) {
        final total = _contentRangeTotal(response.header('content-range'));
        if (offset > 0 && total == offset) {
          await _finalize(taskId, tempFile);
          return;
        }
        await _truncate(tempFile);
        task = task.copyWith(
          downloadedBytes: 0,
          clearEtag: true,
          clearExpectedBytes: true,
          updatedAt: DateTime.now().toUtc(),
        );
        await _save(task);
        continue;
      }

      final contentType = response.header('content-type')?.toLowerCase();
      if (contentType != null &&
          (contentType.startsWith('text/') ||
              contentType.contains('json') ||
              contentType.contains('html'))) {
        throw const FormatException('nonMediaContentType');
      }

      final responseEtag = response.header('etag');
      final contentRange = response.header('content-range');
      final rangeStart = _contentRangeStart(contentRange);
      final mustRestart =
          (offset > 0 && response.statusCode == 200) ||
          (response.statusCode == 206 && rangeStart != offset) ||
          (offset > 0 &&
              task.etag != null &&
              responseEtag != null &&
              task.etag != responseEtag);
      if (mustRestart) {
        await _truncate(tempFile);
        task = task.copyWith(
          downloadedBytes: 0,
          clearEtag: true,
          clearExpectedBytes: true,
          updatedAt: DateTime.now().toUtc(),
        );
        await _save(task);
        continue;
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw EmbyApiException(
          '服务器返回了无法处理的下载响应',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode == 200) offset = 0;
      final contentLength = int.tryParse(
        response.header('content-length') ?? '',
      );
      final expected =
          _contentRangeTotal(contentRange) ??
          (contentLength == null ? task.expectedBytes : offset + contentLength);
      task = task.copyWith(
        status: DownloadStatus.running,
        downloadedBytes: offset,
        etag: responseEtag,
        expectedBytes: expected,
        updatedAt: DateTime.now().toUtc(),
      );
      await _save(task);

      final sink = await tempFile.open(
        mode: offset > 0 ? FileMode.append : FileMode.writeOnly,
      );
      var downloaded = offset;
      var persistedAt = DateTime.now();
      var persistedBytes = downloaded;
      try {
        await for (final chunk in response.stream) {
          _throwIfInterrupted(taskId, token);
          await sink.writeFrom(chunk);
          downloaded += chunk.length;
          final current = _tasks[taskId]!;
          _tasks[taskId] = current.copyWith(
            downloadedBytes: downloaded,
            updatedAt: DateTime.now().toUtc(),
          );
          final now = DateTime.now();
          if (now.difference(persistedAt) >=
                  const Duration(milliseconds: 750) ||
              downloaded - persistedBytes >= 4 * 1024 * 1024) {
            persistedAt = now;
            persistedBytes = downloaded;
            await _repository.saveTask(_tasks[taskId]!);
            _notify();
          }
        }
      } finally {
        await sink.close();
      }
      _throwIfInterrupted(taskId, token);
      task = _tasks[taskId]!.copyWith(
        downloadedBytes: downloaded,
        updatedAt: DateTime.now().toUtc(),
      );
      await _save(task);
      if (expected != null && expected > 0 && downloaded != expected) {
        throw const FormatException('contentLengthMismatch');
      }
      await _finalize(taskId, tempFile);
      return;
    }
    throw const FormatException('rangeResumeRejected');
  }

  Future<void> _finalize(String taskId, File tempFile) async {
    final task = _tasks[taskId]!;
    await _validateMediaFile(tempFile, task.expectedBytes);
    final finalFile = File(task.finalPath);
    await finalFile.parent.create(recursive: true);
    if (await finalFile.exists()) await finalFile.delete();
    final renamed = await tempFile.rename(finalFile.path);
    await _commitExistingFile(task, renamed);
  }

  Future<DownloadTaskRecord> _commitExistingFile(
    DownloadTaskRecord task,
    File finalFile,
  ) async {
    final length = await finalFile.length();
    await _validateMediaFile(finalFile, task.expectedBytes);
    final completedAt = DateTime.now().toUtc();
    var metadata = task.metadata;
    try {
      metadata = await _assetService.downloadAssets(task, finalFile.parent);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'download',
        'Offline assets failed item=${task.itemId}; media remains available',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final completed = task.copyWith(
      status: DownloadStatus.completed,
      downloadedBytes: length,
      expectedBytes: length,
      metadata: metadata,
      clearLastErrorCode: true,
      updatedAt: completedAt,
    );
    final item = OfflineMediaItem(
      scope: completed.scope,
      itemId: completed.itemId,
      mediaSourceId: completed.mediaSourceId,
      metadata: completed.metadata,
      localMediaPath: finalFile.path,
      completedAt: completedAt,
    );
    await _repository.complete(completed, item);
    _tasks[completed.id] = completed;
    DiagnosticLog.instance.info(
      'download',
      'Download completed item=${completed.itemId} bytes=$length',
    );
    _notify();
    return completed;
  }

  Future<void> _removeTaskAndFiles(DownloadTaskRecord task) async {
    final downloadDirectory = await _directoryResolver(scope);
    final pathPolicy = DownloadPathPolicy(downloadDirectory);
    final tempPath = pathPolicy.resolveStoredPath(task.tempPath);
    final finalPath = pathPolicy.resolveStoredPath(task.finalPath);
    final assetRoot = path.normalize(
      path.join(path.dirname(finalPath), 'assets'),
    );
    final files = <(String, bool)>[
      (tempPath, true),
      (finalPath, true),
      for (final assetPath in task.metadata.assetPaths)
        (pathPolicy.resolveStoredPath(assetPath), false),
    ];
    var rejectedPaths = 0;
    for (final (candidate, isTaskFile) in files) {
      final insideRoot = pathPolicy.contains(candidate);
      final insideAssetRoot = path.isWithin(assetRoot, candidate);
      if (!insideRoot || (!isTaskFile && !insideAssetRoot)) {
        rejectedPaths++;
        continue;
      }
      final file = File(candidate);
      if (!await pathPolicy.resolvesWithinRoot(file)) {
        rejectedPaths++;
        continue;
      }
      if (await file.exists()) await file.delete();
    }
    final assetDirectory = Directory(assetRoot);
    if (pathPolicy.contains(assetRoot) &&
        await pathPolicy.resolvesWithinRoot(assetDirectory)) {
      await _deleteEmptyDirectories(assetDirectory);
    }
    if (rejectedPaths > 0) {
      DiagnosticLog.instance.warning(
        'download',
        'Skipped $rejectedPaths unsafe local path(s) task=${task.id}',
      );
    }
    await _repository.removeDownload(task);
    _tasks.remove(task.id);
    _notify();
  }

  Future<void> _save(DownloadTaskRecord task) async {
    _tasks[task.id] = task;
    await _repository.saveTask(task);
    _notify();
  }

  void _throwIfInterrupted(String taskId, CancelToken token) {
    if (token.isCancelled || _requestedActions.containsKey(taskId)) {
      throw const _DownloadInterrupted();
    }
  }

  void _ensureActive() {
    if (_disposed || _shuttingDown) {
      throw StateError('Download service is shutting down');
    }
    if (!_initialized) {
      throw StateError('Download service is not initialized');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

enum _RequestedAction { pause, delete }

class _DownloadInterrupted implements Exception {
  const _DownloadInterrupted();
}

Future<Directory> _defaultDirectory(ServerScope scope) async {
  final root = await getApplicationSupportDirectory();
  return Directory(path.join(root.path, 'offline', scope.databaseKey));
}

Future<int> _lengthIfPresent(File file) async =>
    await file.exists() ? file.length() : 0;

Future<void> _truncate(File file) async {
  if (!await file.exists()) return;
  final handle = await file.open(mode: FileMode.writeOnly);
  await handle.close();
}

Future<void> _deleteEmptyDirectories(Directory directory) async {
  if (!await directory.exists()) return;
  final children = await directory.list(followLinks: false).toList();
  for (final child in children.whereType<Directory>()) {
    await _deleteEmptyDirectories(child);
  }
  if (await directory.list(followLinks: false).isEmpty) {
    await directory.delete();
  }
}

String _fileExtension(PlaybackMediaSource source) {
  final sourceExtension = source.path == null
      ? ''
      : path.extension(source.path!).replaceFirst('.', '').toLowerCase();
  if (RegExp(r'^[a-z0-9]{1,8}$').hasMatch(sourceExtension)) {
    return sourceExtension;
  }
  final container =
      source.container?.split(',').first.trim().toLowerCase() ?? '';
  return switch (container) {
    'matroska' => 'mkv',
    'mpegts' => 'ts',
    'quicktime' => 'mov',
    final value when RegExp(r'^[a-z0-9]{1,8}$').hasMatch(value) => value,
    _ => 'media',
  };
}

int? _contentRangeStart(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes\s+(\d+)-\d+/\d+$').firstMatch(value.trim());
  return int.tryParse(match?.group(1) ?? '');
}

int? _contentRangeTotal(String? value) {
  if (value == null) return null;
  final match = RegExp(r'/(\d+)$').firstMatch(value.trim());
  return int.tryParse(match?.group(1) ?? '');
}

Future<void> _validateMediaFile(File file, int? expectedBytes) async {
  if (!await file.exists()) throw const FileSystemException('missingFile');
  final length = await file.length();
  if (length <= 0) throw const FormatException('emptyFile');
  if (expectedBytes != null && expectedBytes > 0 && length != expectedBytes) {
    throw const FormatException('contentLengthMismatch');
  }
  final handle = await file.open();
  final prefix = await handle.read(min(512, length));
  await handle.close();
  final text = utf8
      .decode(prefix, allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  if (text.startsWith('<!doctype html') ||
      text.startsWith('<html') ||
      text.startsWith('{"message"') ||
      text.startsWith('{"error"')) {
    throw const FormatException('nonMediaPayload');
  }
}

String _errorCode(Object error) {
  if (error is DownloadPreflightException) return error.code;
  if (error is EmbyApiException) {
    final status = error.statusCode;
    if (status == 401 || status == 403) return 'authenticationRequired';
    if (status == 404) return 'sourceNotFound';
    if (status == 429) return 'rateLimited';
    if (status != null && status >= 500) return 'serverError';
  }
  if (error is FileSystemException) return 'storageError';
  if (error is FormatException) return error.message;
  if (error is DioException && error.type == DioExceptionType.cancel) {
    return 'interrupted';
  }
  return 'networkError';
}
