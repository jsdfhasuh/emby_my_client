import 'dart:async';

enum DownloadExecutorCommand { pause, resume, delete, settingsChanged, wake }

class DownloadCommandQueue {
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  Future<void> add(Future<void> Function() command) {
    if (_closed) {
      return Future<void>.error(StateError('Download command queue is closed'));
    }
    final operation = _tail.then((_) => command());
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<void> close() async {
    _closed = true;
    await _tail;
  }
}

abstract interface class DownloadExecutor {
  Stream<void> get changes;

  Future<bool> get isRunning;

  Future<void> start();

  Future<void> send(DownloadExecutorCommand command, {String? taskId});

  Future<void> stop();

  Future<void> dispose();
}
