import 'dart:async';

import 'package:emby_my_client/downloads/download_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes download commands in submission order', () async {
    final queue = DownloadCommandQueue();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = queue.add(() async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
    });
    final second = queue.add(() async {
      events.add('second');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);
    releaseFirst.complete();
    await Future.wait([first, second]);

    expect(events, ['first-start', 'first-end', 'second']);
    await queue.close();
  });

  test('a failed command does not block the next command', () async {
    final queue = DownloadCommandQueue();
    var secondRan = false;

    final first = queue.add(() async => throw StateError('failed command'));
    final second = queue.add(() async {
      secondRan = true;
    });

    await expectLater(first, throwsStateError);
    await second;
    expect(secondRan, isTrue);
    await queue.close();
  });

  test('close waits for active work and rejects later commands', () async {
    final queue = DownloadCommandQueue();
    final release = Completer<void>();
    final active = queue.add(() => release.future);
    var closed = false;

    final closing = queue.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    release.complete();
    await active;
    await closing;

    expect(queue.add(() async {}), throwsStateError);
  });
}
