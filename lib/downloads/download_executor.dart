import 'dart:async';

enum DownloadExecutorCommand { pause, resume, delete, wake }

abstract interface class DownloadExecutor {
  Stream<void> get changes;

  Future<bool> get isRunning;

  Future<void> start();

  Future<void> send(DownloadExecutorCommand command, {String? taskId});

  Future<void> stop();

  Future<void> dispose();
}
