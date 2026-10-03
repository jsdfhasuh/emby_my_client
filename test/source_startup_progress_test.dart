import 'dart:async';

import 'package:emby_my_client/playback/source_startup_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new tail ranges keep startup alive past the old deadline', (
    tester,
  ) async {
    final progress = SourceStartupProgress();
    final ready = Completer<void>();
    var done = false;
    final wait = progress
        .waitUntilReady(
          ready.future,
          idleTimeout: const Duration(seconds: 15),
          totalTimeout: const Duration(seconds: 120),
        )
        .then((_) => done = true);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 10));
      progress.recordBytes(9000000000 + i * 1048576, 1048576);
      expect(done, false);
    }
    ready.complete();
    await tester.pump();
    await wait;
    expect(done, true);
    await tester.pump(const Duration(seconds: 120));
  });

  testWidgets('duplicate ranges cannot keep stalled startup alive', (
    tester,
  ) async {
    final progress = SourceStartupProgress();
    final ready = Completer<void>();
    Object? failure;
    final wait = progress
        .waitUntilReady(
          ready.future,
          idleTimeout: const Duration(seconds: 15),
          totalTimeout: const Duration(seconds: 120),
        )
        .catchError((Object e) {
          failure = e;
        });
    progress.recordBytes(100, 100);
    await tester.pump(const Duration(seconds: 10));
    progress.recordBytes(100, 100);
    progress.recordBytes(120, 50);
    await tester.pump(const Duration(seconds: 5));
    await wait;
    expect(failure, isA<TimeoutException>());
    // Late errors from the cancelled native open remain observed.
    ready.completeError(StateError('late native failure'));
    await tester.pump();
  });

  testWidgets('overlaps only count new bytes and total timeout stays fixed', (
    tester,
  ) async {
    final progress = SourceStartupProgress();
    final ready = Completer<void>();
    Object? failure;
    final wait = progress
        .waitUntilReady(
          ready.future,
          idleTimeout: const Duration(seconds: 15),
          totalTimeout: const Duration(seconds: 40),
        )
        .catchError((Object e) {
          failure = e;
        });
    for (var i = 0; i < 4; i++) {
      progress.recordBytes(i * 50, 100);
      await tester.pump(const Duration(seconds: 10));
      if (i < 3) expect(failure, isNull);
    }
    await wait;
    expect(failure, isA<TimeoutException>());
    expect((failure as TimeoutException).message, contains('budget'));
  });

  testWidgets(
    'cancellation is immediate and a new attempt has fresh progress',
    (tester) async {
      final progress = SourceStartupProgress();
      final ready = Completer<void>();
      Object? failure;
      final wait = progress
          .waitUntilReady(
            ready.future,
            idleTimeout: const Duration(seconds: 15),
            totalTimeout: const Duration(seconds: 120),
          )
          .catchError((Object e) {
            failure = e;
          });
      final cancellation = StateError('cancelled');
      ready.completeError(cancellation);
      await tester.pump();
      await wait;
      expect(failure, same(cancellation));
      final next = Completer<void>();
      final nextWait = progress.waitUntilReady(
        next.future,
        idleTimeout: const Duration(seconds: 15),
        totalTimeout: const Duration(seconds: 120),
      );
      next.complete();
      await tester.pump();
      await nextWait;
      await tester.pump(const Duration(seconds: 120));
    },
  );
}
